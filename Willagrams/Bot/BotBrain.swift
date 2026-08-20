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

    /// Consecutive search ticks that ended with nothing placed. The stall
    /// floor: at ``BotDifficulty/stallFloorTicks`` the brain is allowed one
    /// attempt one rung above its own depth, and the count resets. An easy bot
    /// that could never reach for repair would otherwise sit on an unplayable
    /// rack for the rest of the match, which from the player's side of the
    /// screen is indistinguishable from a broken bot.
    private var stalledTicks = 0

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
                await attempt(snapshot)
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

    /// One search tick: decide how deep to reach, search, apply, and keep the
    /// stall count.
    ///
    /// The search is skipped when the last one over this same rack and board
    /// came back empty — rung 0 alone is ~rack × frontier whole-board
    /// validations, and a brain with an unplayable rack would otherwise pay
    /// that on every tick forever. The stall floor is what stops that skip
    /// becoming permanent: once ``BotDifficulty/stallFloorTicks`` ticks have
    /// passed with nothing placed, the brain searches anyway and reaches one
    /// rung above its own depth for exactly one attempt.
    private func attempt(_ snapshot: Snapshot) async {
        let fingerprint = Fingerprint(snapshot)
        let granted = stalledTicks >= max(1, difficulty.stallFloorTicks)
        guard granted || fingerprint != barren else {
            stalledTicks += 1
            return
        }
        // Clamped once, here: the grant may lift the depth by one rung and no
        // further, and never past the last rung that exists.
        let depth = min(3, max(0, difficulty.ladderDepth) + (granted ? 1 : 0))
        if granted { stalledTicks = 0 }

        guard let plan = plan(on: snapshot, depth: depth) else {
            barren = fingerprint
            stalledTicks += 1
            return
        }
        barren = nil
        if await apply(plan, from: snapshot) {
            stalledTicks = 0
        } else {
            stalledTicks += 1
        }
    }

    /// Puts a chosen plan through the session, which is the only thing that
    /// decides whether it is still legal. Returns whether the board kept it.
    private func apply(_ plan: Plan, from snapshot: Snapshot) async -> Bool {
        let dictionary = Self.effectiveDictionary(
            base: baseDictionary,
            options: snapshot.options
        )
        let board = snapshot.board
        // The snapshot this plan came from may be stale — a grant landed, or
        // the match locked. Recorded, not swallowed: the tick ends here and the
        // next one re-reads the session and tries again.
        let error = await MainActor.run { [session] in
            Self.commit(plan, session, from: board, dictionary: dictionary)
        }
        lastPlacementError = error
        return error == nil
    }

    /// Applies a whole plan on the session's actor, or leaves the board exactly
    /// as it found it.
    ///
    /// This body is synchronous, so nothing interleaves with it: no grant lands
    /// between the recalls and the placements, and `isLocked` and
    /// `hasPendingDraw` cannot change under it. That is what makes the rollback
    /// total rather than best-effort — if the first recall was accepted, every
    /// recall and re-placement in ``restore(_:to:)`` is accepted too.
    ///
    /// The goodness check is the transactional guardrail for rungs 1 and 2: an
    /// attempt that ends with fewer tiles down, an invalid word, or a second
    /// cluster is rolled all the way back. Rung 0 skips it — a single extension
    /// was already validated as a whole board by the search, and re-validating
    /// per placement would double the cost of the common case.
    @MainActor
    private static func commit(
        _ plan: Plan,
        _ session: MatchSession,
        from board: Board,
        dictionary: some WordList
    ) -> BoardActionError? {
        // A plan names coordinates. A board that moved under it has different
        // tiles at those coordinates, so recalling them would pull the wrong
        // ones. Re-snapshot instead.
        guard session.state.board == board else {
            return .placementFailed("the board moved under the plan")
        }
        let before = board.placementList
        do {
            for coord in plan.recalls { try session.recall(from: coord) }
            for move in plan.moves { try session.place(tileID: move.tileID, at: move.coord) }
        } catch {
            restore(session, to: before)
            return error
        }
        guard !plan.recalls.isEmpty else { return nil }

        let now = session.state.board
        let check = now.validate(against: dictionary)
        guard now.placements.count > board.placements.count,
              check.invalidWords.isEmpty,
              check.clusterCount <= 1
        else {
            restore(session, to: before)
            return .placementFailed("the attempt left the board no better")
        }
        return nil
    }

    /// Puts the board back exactly as `placements` had it — the same tiles at
    /// the same coordinates.
    ///
    /// Every recall returns its tile to the rack and frees its cell, so by the
    /// time the re-placements run each tile is in hand and each cell is empty:
    /// nothing here can be refused. The `try?`s are the belt on that reasoning,
    /// not a shrug at it.
    @MainActor
    private static func restore(_ session: MatchSession, to placements: [Placement]) {
        for coord in Array(session.state.board.placements.keys) {
            try? session.recall(from: coord)
        }
        for placement in placements {
            try? session.place(tileID: placement.tileID, at: placement.coord)
        }
    }

    // MARK: - The ladder

    /// Walks the ladder up to `depth` and returns the first plan any rung
    /// offers.
    ///
    /// Rung 3 (swap) is a later item; adding it is adding a `case` here, not
    /// changing the tick above it.
    private func plan(on snapshot: Snapshot, depth: Int) -> Plan? {
        for rung in 0...depth {
            switch rung {
            case 0:
                if let move = extend(snapshot) { return Plan(recalls: [], moves: [move]) }
            case 1:
                if let plan = repair(snapshot) { return plan }
            case 2:
                if let plan = rebuild(snapshot) { return plan }
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
        // Rung 0 needs no budget: it is bounded by construction at distinct
        // letters × frontier, both of which are small and both of which shrink
        // as the rack empties. Rungs 1 and 2 are the ones that need a ceiling.
        var unbounded = Int.max
        return Self.step(
            on: snapshot.board,
            from: snapshot.hand,
            dictionary: Self.effectiveDictionary(base: baseDictionary, options: snapshot.options),
            budget: &unbounded
        )
    }

    /// Rung 0's inner loop, shared with the two rungs above it. One legal
    /// placement of one of `tiles` onto `board`, or nothing. Spends one unit of
    /// `budget` per whole-board validation and stops dead when it runs out.
    private static func step(
        on board: Board,
        from tiles: [Tile],
        dictionary: some WordList,
        budget: inout Int
    ) -> Move? {
        let frontier = frontier(of: board)
        var tried: Set<Candidate> = []
        for tile in tiles {
            for coord in frontier {
                guard budget > 0 else { return nil }
                guard tried.insert(Candidate(letter: tile.letter, coord: coord)).inserted
                else { continue }
                var trial = board
                guard (try? trial.place(tile, at: coord)) != nil else { continue }
                budget -= 1
                if trial.validate(against: dictionary).invalidWords.isEmpty {
                    return Move(tileID: tile.id, coord: coord)
                }
            }
        }
        return nil
    }

    /// Greedily lands as many of `tiles` on `board` as it can, one legal
    /// placement at a time, until nothing more fits or `budget` runs out.
    ///
    /// Every intermediate board is one cluster with no invalid word, because
    /// every candidate cell touches a placed tile and every placement is
    /// whole-board validated — so the board handed back is legal whether the
    /// fill finished or the budget cut it short.
    private static func fill(
        _ board: Board,
        with tiles: [Tile],
        dictionary: some WordList,
        budget: inout Int
    ) -> (board: Board, moves: [Move]) {
        var board = board
        var pool = tiles
        var moves: [Move] = []
        while budget > 0, let move = step(on: board, from: pool, dictionary: dictionary, budget: &budget) {
            guard let index = pool.firstIndex(where: { $0.id == move.tileID }),
                  (try? board.place(pool[index], at: move.coord)) != nil
            else { break }
            pool.remove(at: index)
            moves.append(move)
        }
        return (board, moves)
    }

    // MARK: - Rung 1: local repair

    /// Rung 1. No single tile fits, so free the cheapest patch of board and
    /// re-place what was freed together with the whole rack.
    ///
    /// **Which tiles to pull** is the design here. The seed is one placed word,
    /// tried shortest first and, among equal lengths, the one crossed by the
    /// fewest other words — the least load-bearing thing on the board. Pulling
    /// it shortens every word that crossed it, so ``settle(_:pulling:against:)``
    /// then grows the pull until what remains is legal again: any run the
    /// removal left invalid comes out too, and so does anything it orphaned
    /// off the main cluster. A pull that swallows the whole board is refused —
    /// that is rung 2's job, and rung 2 has a budget for it.
    ///
    /// The result is kept only if it puts strictly more tiles on the board than
    /// were there before; ``commit(_:_:from:dictionary:)`` re-checks that
    /// against the real session and rolls back if it does not hold.
    private func repair(_ snapshot: Snapshot) -> Plan? {
        let board = snapshot.board
        let placed = board.placements.count
        guard placed > 0 else { return nil }
        let dictionary = Self.effectiveDictionary(
            base: baseDictionary,
            options: snapshot.options
        )

        let seeds = board.words().sorted {
            (
                $0.text.count, Self.crossings(of: $0, on: board),
                $0.origin.row, $0.origin.col
            ) < (
                $1.text.count, Self.crossings(of: $1, on: board),
                $1.origin.row, $1.origin.col
            )
        }

        var budget = Self.repairNodeBudget
        for seed in seeds.prefix(Self.repairSeedLimit) {
            guard budget > 0 else { break }
            guard let settled = Self.settle(
                board,
                pulling: Set(Self.coords(of: seed)),
                against: dictionary
            ), settled.pull.count < placed else { continue }

            let pull = settled.pull.sorted(by: Self.byCoord)
            let freed = pull.compactMap { board.tile(at: $0) }
            let built = Self.fill(
                settled.rest,
                with: freed + snapshot.hand,
                dictionary: dictionary,
                budget: &budget
            )
            guard built.board.placements.count > placed else { continue }
            return Plan(recalls: pull, moves: built.moves)
        }
        return nil
    }

    /// Grows `seed` until the board left behind is legal again, or gives up.
    ///
    /// Removing a word's tiles shortens the words that crossed it, and a
    /// shortened run is usually not a word any more; it can also cut the board
    /// into pieces. Both are repaired by pulling more, which can expose more of
    /// the same, so this iterates — bounded by ``settleRounds``, and returning
    /// nothing rather than looping if it has not converged by then.
    private static func settle(
        _ board: Board,
        pulling seed: Set<Coord>,
        against dictionary: some WordList
    ) -> (pull: Set<Coord>, rest: Board)? {
        var pull = seed
        var rest = board
        for coord in seed { rest.remove(at: coord) }

        for _ in 0..<settleRounds {
            var grew = false
            for word in rest.words() where !dictionary.contains(word.text) {
                for coord in coords(of: word) where pull.insert(coord).inserted {
                    rest.remove(at: coord)
                    grew = true
                }
            }
            let clusters = rest.clusters
            if clusters.count > 1, let keep = clusters.max(by: { rank($0) < rank($1) }) {
                for cluster in clusters where cluster != keep {
                    for coord in cluster.sorted(by: byCoord) where pull.insert(coord).inserted {
                        rest.remove(at: coord)
                        grew = true
                    }
                }
            }
            if !grew { return (pull, rest) }
        }
        return nil
    }

    /// Biggest cluster wins, ties broken by the topmost-leftmost cell, so the
    /// same board always keeps the same piece.
    private static func rank(_ cluster: Set<Coord>) -> (Int, Int, Int) {
        let corner = cluster.map { ($0.row, $0.col) }.min { $0 < $1 } ?? (0, 0)
        return (cluster.count, -corner.0, -corner.1)
    }

    /// How many other words cross this one — how load-bearing it is.
    static func crossings(of word: BoardWord, on board: Board) -> Int {
        coords(of: word).filter { coord in
            let (back, forward) = word.direction == .across
                ? (Coord(row: coord.row - 1, col: coord.col), Coord(row: coord.row + 1, col: coord.col))
                : (Coord(row: coord.row, col: coord.col - 1), Coord(row: coord.row, col: coord.col + 1))
            return board.tile(at: back) != nil || board.tile(at: forward) != nil
        }.count
    }

    /// The cells a word occupies, from its origin.
    static func coords(of word: BoardWord) -> [Coord] {
        (0..<word.text.count).map { offset in
            word.direction == .across
                ? Coord(row: word.origin.row, col: word.origin.col + offset)
                : Coord(row: word.origin.row + offset, col: word.origin.col)
        }
    }

    // MARK: - Rung 2: full rebuild

    /// Rung 2. Take everything off the board and lay the whole rack out again
    /// from nothing, keeping the best board found.
    ///
    /// Bounded by ``rebuildNodeBudget`` whole-board validations, spent across
    /// at most ``rebuildRestarts`` greedy passes that differ only in which tile
    /// is tried first — a rotation, because greedy from an empty board is
    /// decided almost entirely by its opening tile. The budget is shared, not
    /// per pass, so the total work is the same whether one pass eats it or
    /// three do: a 21-tile rack cannot make this run longer than a 5-tile one.
    ///
    /// Returns nothing unless a pass beat the board that is already down, which
    /// is what leaves a fruitless rebuild tile-for-tile identical.
    private func rebuild(_ snapshot: Snapshot) -> Plan? {
        let board = snapshot.board
        let placed = board.placements.count
        var order = board.placementList.map(\.tile) + snapshot.hand
        guard !order.isEmpty else { return nil }
        let dictionary = Self.effectiveDictionary(
            base: baseDictionary,
            options: snapshot.options
        )

        var budget = Self.rebuildNodeBudget
        var best: [Move] = []
        for _ in 0..<Self.rebuildRestarts {
            guard budget > 0 else { break }
            let built = Self.fill(Board(), with: order, dictionary: dictionary, budget: &budget)
            if built.moves.count > best.count { best = built.moves }
            if best.count == order.count { break }
            order = Array(order.dropFirst()) + order.prefix(1)
        }
        guard best.count > placed else { return nil }
        return Plan(recalls: board.placements.keys.sorted(by: Self.byCoord), moves: best)
    }

    // MARK: - Budgets

    /// Whole-board validations one rung-1 repair may spend across every seed it
    /// tries. Repair is meant to be the cheap rung; a repair that costs more
    /// than a rebuild has no reason to exist.
    static let repairNodeBudget = 4_000

    /// How many placed words repair will try pulling before giving up. The list
    /// is ordered cheapest-first, so the tail is the expensive end.
    static let repairSeedLimit = 6

    /// How many times a pull may grow before repair abandons that seed.
    static let settleRounds = 4

    /// Whole-board validations one rung-2 rebuild may spend, in total, across
    /// every pass. This is the ceiling that makes "re-solve the whole rack" a
    /// bounded operation rather than a hang.
    static let rebuildNodeBudget = 20_000

    /// Greedy passes a rebuild may make, each starting from a different tile.
    static let rebuildRestarts = 3

    /// One fixed order for coordinates, so two runs over one board pull and
    /// place the same tiles in the same sequence.
    static func byCoord(_ a: Coord, _ b: Coord) -> Bool {
        (a.row, a.col) < (b.row, b.col)
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

    /// One rung's whole answer: what to take off the board, then what to put
    /// down. Empty `recalls` is rung 0 — a plain extension.
    ///
    /// A plan is inert. It names coordinates and tile ids and nothing else, so
    /// it can be carried from the search actor to the main one and applied, or
    /// dropped, without either side holding the other's state.
    private struct Plan: Sendable {
        let recalls: [Coord]
        let moves: [Move]
    }
}
