//
//  BotBrain.swift
//  Willagrams
//
//  The bot's brain: a background actor that drives a `MatchSession` from the
//  outside, exactly as a player's thumbs do.
//
//  It is deliberately not the session's owner and not its friend. It holds no
//  rack, no board and no status — every tick begins by hopping to the session's
//  actor and reading a fresh snapshot, and every move goes back through the
//  session's public API. A brain that cached the rack would drift out of step
//  with a grant landing mid-search, and drift is how tiles get lost.
//
//  It also builds no rules. Legality is `Board.validate` from the frozen
//  engine, run against the word list this match's `MatchOptions` name; the
//  brain's whole contribution is choosing which legal move to try first.
//
//  NO SwiftUI here — this file is pure state and must stay out of the `Bot`
//  target's `exclude:` list so it compiles into the macOS test target.
//
//  This file must never import GameKit.
//

// The app compiles `Willagrams/Match` and `Willagrams/Bot` into one module,
// where there is nothing to import. `Tests/BotTests` compiles them as two, so
// the import is real there and only there.
#if canImport(Match)
import Match
#endif

import Foundation
import WillagramsRules

/// Plays the bot's side of a match.
///
/// ## The tick
///
/// One hop to the session's actor reads everything the tick needs and takes any
/// move that needs no search:
///
/// 1. **Tiles pending → take them.** First, always. `MatchSession.place` throws
///    ``BoardActionError/drawPending`` while a grant waits, so the board is
///    frozen until the tile is in the rack — a brain that searched first would
///    search a board it cannot touch.
/// 2. **`canDraw` → draw, or win if the pool is dry.**
/// 3. Otherwise the snapshot goes back to this actor and the ladder searches it
///    off the main actor.
///
/// ## Staleness
///
/// The snapshot can go stale between reading it and acting on it — a grant can
/// land mid-search. That is why the chosen move is applied by calling
/// ``MatchSession/place(tileID:at:)`` rather than by writing state directly: the
/// session re-checks, and a thrown ``BoardActionError`` ends the tick with the
/// error recorded, so the next tick re-snapshots and tries again. Nothing is
/// swallowed and nothing is forced through on a stale read.
public actor BotBrain {

    /// The session this brain drives. Isolated to the main actor, so every
    /// read and every move below is an explicit hop.
    private let session: MatchSession

    /// The match's base word list — the same one the session was built with.
    /// The list actually validated against is derived from the session's
    /// ``MatchOptions`` on every tick, so the bot obeys the same minimum word
    /// length and dictionary the player does.
    private let baseDictionary: any WordList

    /// The tuning constants. See ``BotDifficulty``.
    public let difficulty: BotDifficulty

    /// The last `BoardActionError` a placement threw, kept so a stale-snapshot
    /// retry is observable rather than invisible. Cleared by the next placement
    /// that lands.
    public private(set) var lastPlacementError: BoardActionError?

    /// One `run()` at a time. Two would interleave at every `await` and issue
    /// two draws and two placements per tick against one session.
    private var isRunning = false

    /// The rack-and-board fingerprint of the last search that found nothing.
    /// Not a copy of the rack or the board and never a source of truth for a
    /// move — only a reason to skip re-running an exhaustive search over state
    /// that has not moved since it last came back empty.
    private var barren: Fingerprint?

    /// The shipping initialiser: the session and the word list both come from
    /// one ``BotMatch``, so they cannot be handed disagreeing dictionaries.
    public init(match: BotMatch, difficulty: BotDifficulty = .medium) {
        self.session = match.session
        self.baseDictionary = match.dictionary
        self.difficulty = difficulty
    }

    /// Splits the session from the word list, which only a test wants: it is
    /// how the search's list is instrumented without instrumenting the
    /// session's. Real callers use ``init(match:difficulty:)`` — a list passed
    /// here that disagrees with the session's is a bot playing by a different
    /// dictionary than its own match.
    public init(
        session: MatchSession,
        dictionary: any WordList,
        difficulty: BotDifficulty = .medium
    ) {
        self.session = session
        self.baseDictionary = dictionary
        self.difficulty = difficulty
    }

    // MARK: - Driving

    /// Plays until the match is over or the task is cancelled.
    ///
    /// Ends on ``MatchSession/isMatchOver`` however it arrives — the bot's own
    /// ``claimWin()``, the human's `.win`, or `leave()` and a peer that went
    /// away, which lock the session with no winner at all. A brain that watched
    /// only for `.finished` would spin the full search every `thinkDelay` for
    /// the life of the process against a session that refuses every move.
    ///
    /// Safe to check from the first tick: `roster` is set once in `init` and
    /// holds both players, and an unheard-from peer reads `.present`, so
    /// `presentPlayers.count` is 2 before the peer ever connects.
    ///
    /// Sleeps ``BotDifficulty/thinkDelay`` after every tick, placement or not,
    /// so a brain with nothing to do waits rather than spins. A second
    /// concurrent call returns immediately rather than doubling every move.
    public func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        var drawMark: WireMark?
        while !Task.isCancelled {
            let mark = drawMark
            switch await MainActor.run(body: { [session] in Self.step(session, mark) }) {
            case .finished:
                return
            case let .acted(mark):
                drawMark = mark
            case let .search(snapshot):
                drawMark = nil
                await apply(searchIfMoved(snapshot))
            }
            try? await Task.sleep(for: difficulty.thinkDelay)
        }
    }

    /// One tick of everything that needs the session's actor.
    ///
    /// The win predicate is evaluated *here*, on the session's own actor, at
    /// the instant the claim is made — not against a snapshot that could have
    /// aged. Nothing on the wire verifies a win claim, so `canDraw &&
    /// poolIsExhausted` is the only thing keeping the bot honest, and it is
    /// checked where it cannot be stale.
    /// `drawMark` is what the wire looked like when this brain last asked for a
    /// round. `canDraw` stays true across the whole request/grant round trip,
    /// so without it every tick inside that window fires another
    /// `drawRequest` — each one draining the pool and handing the human another
    /// pending tile. The credits are `MatchSession`'s to count; this only
    /// declines to ask twice for the same unanswered round.
    @MainActor
    private static func step(_ session: MatchSession, _ drawMark: WireMark?) -> Tick {
        if session.isMatchOver { return .finished }
        if session.hasPendingDraw {
            session.draw()
            return .acted(nil)
        }
        if session.canDraw {
            if session.poolIsExhausted {
                session.claimWin()
                return .acted(nil)
            }
            // Every way the request can be answered — the grant landing, the
            // pool running dry, a refusal — moves one of these. Unmoved means
            // unanswered, and asking again would spend a second round.
            let now = WireMark(session)
            guard now != drawMark else { return .acted(drawMark) }
            session.draw()
            return .acted(now)
        }
        return .search(
            Snapshot(
                hand: session.state.hand,
                board: session.state.board,
                options: session.options
            )
        )
    }

    /// Searches, unless the last search over this same rack and board came back
    /// empty. Rung 0 is ~rack × frontier whole-board validations; a brain with
    /// an unplayable rack would otherwise pay that on every tick forever.
    private func searchIfMoved(_ snapshot: Snapshot) -> Move? {
        let fingerprint = Fingerprint(snapshot)
        guard fingerprint != barren else { return nil }
        guard let move = move(on: snapshot) else {
            barren = fingerprint
            return nil
        }
        barren = nil
        return move
    }

    /// Puts a chosen move through the session, which is the only thing that
    /// decides whether it is still legal.
    private func apply(_ move: Move?) async {
        guard let move else { return }
        do {
            try await MainActor.run { [session] in
                try session.place(tileID: move.tileID, at: move.coord)
            }
            lastPlacementError = nil
        } catch {
            // The snapshot this move came from is now known stale — a grant
            // landed, or the match locked. Recorded, not swallowed: the tick
            // ends here and the next one re-reads the session and retries.
            lastPlacementError =
                error as? BoardActionError ?? .placementFailed(String(describing: error))
        }
    }

    // MARK: - The ladder

    /// Walks the ladder up to ``BotDifficulty/ladderDepth`` and returns the
    /// first move any rung offers.
    ///
    /// Rungs 1–3 (repair, rebuild, swap) are later items; adding one is adding
    /// a `case` here, not changing the tick above it.
    private func move(on snapshot: Snapshot) -> Move? {
        for rung in 0...min(3, max(0, difficulty.ladderDepth)) {
            switch rung {
            case 0:
                if let move = extend(snapshot) { return move }
            default:
                continue
            }
        }
        return nil
    }

    /// Rung 0. The first rack tile that legally lands on the first frontier
    /// cell that accepts it.
    ///
    /// "Legally" is the frozen engine's answer, not this lane's: the tile goes
    /// onto a throwaway copy of the snapshot's board and the whole board is
    /// re-validated. Clustering takes care of itself — every candidate cell
    /// touches a placed tile, so the board never gains a second cluster.
    ///
    /// Two rack tiles with the same letter are the same board at the same cell,
    /// so the second one is skipped: identity is what differs, and legality
    /// cannot see identity. That narrowing costs nothing in fidelity — it is a
    /// fact about `Board`, not a claim about the rules — and on a 21-tile rack
    /// full of repeated letters it is most of the work.
    ///
    /// Tile-major order is deliberate: the skipped candidates are exactly the
    /// ones an earlier tile already failed at, so the move chosen is the same
    /// move the unnarrowed loop chose.
    ///
    /// ponytail: still re-validates the whole board per surviving candidate —
    /// O(distinct letters × frontier × tiles). Only the two runs through the
    /// new cell can change, so this could be narrowed further, but that copy
    /// would be this lane re-implementing rules `Board.validate` already owns.
    private func extend(_ snapshot: Snapshot) -> Move? {
        let dictionary = Self.effectiveDictionary(
            base: baseDictionary,
            options: snapshot.options
        )
        let frontier = Self.frontier(of: snapshot.board)
        var tried: Set<Candidate> = []
        for tile in snapshot.hand {
            for coord in frontier {
                guard tried.insert(Candidate(letter: tile.letter, coord: coord)).inserted
                else { continue }
                var trial = snapshot.board
                guard (try? trial.place(tile, at: coord)) != nil else { continue }
                if trial.validate(against: dictionary).invalidWords.isEmpty {
                    return Move(tileID: tile.id, coord: coord)
                }
            }
        }
        return nil
    }

    /// Every empty cell edge-adjacent to a placed tile, in a fixed order — or
    /// the origin, on an empty board.
    ///
    /// Sorted because `Board.placements` is a dictionary: unsorted, the bot
    /// would build a different board every run from the same rack.
    static func frontier(of board: Board) -> [Coord] {
        guard !board.placements.isEmpty else { return [Coord(row: 0, col: 0)] }
        var seen: Set<Coord> = []
        var cells: [Coord] = []
        for placed in board.placements.keys {
            for neighbor in placed.neighbors
            where board.placements[neighbor] == nil && seen.insert(neighbor).inserted {
                cells.append(neighbor)
            }
        }
        return cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
    }

    /// The list this match plays by, wrapped exactly as `MatchSession` wraps
    /// its own — so "the bot's word is legal" and "the player's word is legal"
    /// cannot disagree.
    static func effectiveDictionary(
        base: any WordList,
        options: MatchOptions
    ) -> any WordList {
        guard options.minimumWordLength > MatchOptions.lengthRange.lowerBound else {
            return base
        }
        return MinimumLengthWordList(base: base, minimum: options.minimumWordLength)
    }

    // MARK: - Tick shapes

    /// What one hop to the session's actor found. Carries the snapshot back to
    /// this actor rather than searching on the main one.
    private enum Tick: Sendable {
        case finished
        /// Carries forward the mark of an unanswered draw request, or `nil`
        /// when nothing is outstanding.
        case acted(WireMark?)
        case search(Snapshot)
    }

    /// Everything about the session that a draw request's answer would move.
    /// Cheap to take and cheap to compare; holds no tiles.
    struct WireMark: Equatable, Sendable {
        let handCount: Int
        let hasPendingDraw: Bool
        let poolIsExhausted: Bool
        let note: String?

        @MainActor
        init(_ session: MatchSession) {
            handCount = session.state.hand.count
            hasPendingDraw = session.hasPendingDraw
            poolIsExhausted = session.poolIsExhausted
            note = session.lastNote
        }
    }

    /// What a search's outcome depends on. Tile ids rather than letters: a
    /// swapped-in tile with the same letters is still a different rack.
    private struct Fingerprint: Equatable {
        let boardCount: Int
        let rack: [UUID]

        init(_ snapshot: Snapshot) {
            boardCount = snapshot.board.placements.count
            rack = snapshot.hand.map(\.id)
        }
    }

    /// A letter at a cell — the whole of what a trial placement's legality
    /// depends on.
    private struct Candidate: Hashable {
        let letter: Character
        let coord: Coord
    }

    /// Everything the search needs, read in one hop so the parts cannot
    /// disagree with each other. Value types throughout: nothing here is a
    /// window onto the session, and none of it outlives the tick.
    private struct Snapshot: Sendable {
        let hand: [Tile]
        let board: Board
        let options: MatchOptions
    }

    private struct Move: Sendable {
        let tileID: UUID
        let coord: Coord
    }
}
