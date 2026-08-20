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
    /// Ends on `.finished` however it arrives — the bot's own ``claimWin()``,
    /// or the human's `.win` landing on the bot's session. Sleeps
    /// ``BotDifficulty/thinkDelay`` after every tick, placement or not, so a
    /// brain with nothing to do waits rather than spins.
    public func run() async {
        while !Task.isCancelled {
            switch await MainActor.run(body: { Self.step(self.session) }) {
            case .finished:
                return
            case .acted:
                break
            case let .search(snapshot):
                await apply(move(on: snapshot))
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
    @MainActor
    private static func step(_ session: MatchSession) -> Tick {
        if case .finished = session.state.status { return .finished }
        if session.hasPendingDraw {
            session.draw()
            return .acted
        }
        if session.canDraw {
            if session.poolIsExhausted {
                session.claimWin()
            } else {
                session.draw()
            }
            return .acted
        }
        return .search(
            Snapshot(
                hand: session.state.hand,
                board: session.state.board,
                options: session.options
            )
        )
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
        for rung in 0...max(0, difficulty.ladderDepth) {
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
    /// ponytail: re-validates the whole board per candidate — O(rack ×
    /// frontier × tiles). Only the two runs through the new cell can change, so
    /// this can be narrowed if a large board ever feels slow. Left whole
    /// because `Board.validate` is the frozen definition of legal and a
    /// narrowed copy would be this lane re-implementing rules.
    private func extend(_ snapshot: Snapshot) -> Move? {
        let dictionary = Self.effectiveDictionary(
            base: baseDictionary,
            options: snapshot.options
        )
        let frontier = Self.frontier(of: snapshot.board)
        for tile in snapshot.hand {
            for coord in frontier {
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
        case acted
        case search(Snapshot)
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
