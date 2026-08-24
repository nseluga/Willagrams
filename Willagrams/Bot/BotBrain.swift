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

    /// Consecutive stall-floor grants that changed nothing on the board.
    ///
    /// The floor firing once means the search had a bad tick. It firing over
    /// and over means the rack holds something no rung this bot has will ever
    /// place, which is the only thing the last-resort swap is for. Counting
    /// them is what keeps an easy bot easy: hard reaches rung 3 inside its own
    /// search and pays nothing, while a shallow bot must be demonstrably dead
    /// first.
    private var barrenGrants = 0

    /// Set the first time a swap request is answered with a refusal, and never
    /// cleared. A stored property on this actor, deliberately: derived from a
    /// snapshot it would come back false the moment the session's note moved
    /// on, and recomputed from session state it would come back false after a
    /// reconnect. The host's answer stands for the life of this brain.
    private var swapAnswerStands = false
    /// The wire as it looked when a swap request went out, or `nil` when none
    /// is outstanding. One request at a time: `canDraw` and the rack look
    /// identical from the request until the answer lands, so a brain that only
    /// re-checked those would ask again on every tick of that window.
    private var pendingSwap: WireMark?

    /// How the brain waits between ticks. The same seam ``BotMatch`` and
    /// `MatchSession` already take, for the same reason: a test that had to
    /// sleep real milliseconds could not play a whole match, and a test that
    /// could not see the sleeps could not count the ticks a match costs.
    private let sleepFor: @Sendable (Duration) async -> Void

    /// The shipping initialiser: the session and the word list both come from
    /// one ``BotMatch``, so they cannot be handed disagreeing dictionaries.
    public init(
        match: BotMatch,
        difficulty: BotDifficulty = .medium,
        sleepFor: @escaping @Sendable (Duration) async -> Void = BotBrain.realSleep
    ) {
        self.session = match.session
        self.baseDictionary = match.dictionary
        self.difficulty = difficulty
        self.sleepFor = sleepFor
    }

    /// The only sleep a shipping build ever uses.
    public static let realSleep: @Sendable (Duration) async -> Void = {
        try? await Task.sleep(for: $0)
    }

    /// Splits the session from the word list, which only a test wants: it is
    /// how the search's list is instrumented without instrumenting the
    /// session's. Real callers use ``init(match:difficulty:)`` — a list passed
    /// here that disagrees with the session's is a bot playing by a different
    /// dictionary than its own match.
    public init(
        session: MatchSession,
        dictionary: any WordList,
        difficulty: BotDifficulty = .medium,
        sleepFor: @escaping @Sendable (Duration) async -> Void = BotBrain.realSleep
    ) {
        self.session = session
        self.baseDictionary = dictionary
        self.difficulty = difficulty
        self.sleepFor = sleepFor
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
            await sleepFor(difficulty.thinkDelay)
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
        if pendingSwap != nil { await settleSwap() }
        let fingerprint = Fingerprint(snapshot)
        let granted = stalledTicks >= max(1, difficulty.stallFloorTicks)
        guard granted || fingerprint != barren else {
            stalledTicks += 1
            return
        }
        // Clamped once, here: the grant may lift the *search* depth by one rung
        // and no further. Rung 3 is not a search and is not reached this way —
        // it comes in below, as a last resort, only when the whole search has
        // already come back empty.
        let climb = min(2, max(0, difficulty.ladderDepth) + (granted ? 1 : 0))
        let eager = mayAskToSwap(snapshot)
        let depth = eager ? 3 : climb
        // The floor's last resort. A shallow bot cannot lay a word its search
        // cannot see — a lone Q needs a vowel pulled off the board, and no rung
        // below 3 will ever find one — so a bot held to rungs 0–2 sits on that
        // tile for the rest of the match, which from the player's side of the
        // screen is indistinguishable from a bot that stopped working. Handing
        // the tile back is the only exit it has. Gated on the floor having
        // fired, so it is a way out of being stuck and never a way to play.
        let lastResort = granted
            && barrenGrants >= Self.barrenGrantsBeforeGivingBack
            && !eager
            && swapIsAvailable(snapshot)
        if granted { stalledTicks = 0; barrenGrants += 1 }

        guard let plan = plan(on: snapshot, depth: depth, mayGiveBack: lastResort) else {
            barren = fingerprint
            stalledTicks += 1
            return
        }
        if let tile = plan.swap {
            await ask(toSwap: tile)
            // Nothing on the board moved, so the next tick would find this same
            // rack, this same board and this same plan. The answer is what moves
            // the rack, and moving the rack moves the fingerprint.
            barren = fingerprint
            stalledTicks += 1
            return
        }
        if await apply(plan, from: snapshot) {
            barren = nil
            stalledTicks = 0
            barrenGrants = 0
        } else {
            // A plan that was found and then refused is the expensive case: the
            // full ladder ran, the session said no, and every rolled-back
            // failure path leaves this exact rack and this exact board behind.
            // Without marking it the brain re-runs the same search, finds the
            // same plan and is refused again on every tick until the stall
            // floor fires. A refusal that *did* move the state — a grant
            // landing mid-search — moves the fingerprint too, so the next tick
            // searches anyway.
            barren = fingerprint
            stalledTicks += 1
        }
    }

    /// Whether rung 3 may be reached on this tick.
    ///
    /// Four conditions, and every one of them is a guardrail: the bot was built
    /// at the depth that swaps, no answer has already stood, no request is
    /// outstanding, and this match allows swapping at all. The stall floor
    /// appears nowhere here on purpose.
    private func mayAskToSwap(_ snapshot: Snapshot) -> Bool {
        difficulty.ladderDepth >= 3 && swapIsAvailable(snapshot)
    }

    /// Whether a swap could be asked for at all, leaving aside whether this
    /// bot is deep enough to want one. Split out so the stall floor's last
    /// resort answers the same three guardrails without also claiming rung 3
    /// as part of its search.
    private func swapIsAvailable(_ snapshot: Snapshot) -> Bool {
        !swapAnswerStands && pendingSwap == nil && snapshot.options.swapEnabled
    }

    /// Asks the host for three tiles in exchange for `tile`, and records what
    /// came of asking.
    ///
    /// A `false` from ``MatchSession/swap(_:)`` is two different things. With
    /// swapping off it is the local half of `.swapDisabled` — the host's own
    /// answer, arrived at without a round trip — and it latches. With a lock or
    /// a tile still waiting to be taken it is a *not now*, which is no answer at
    /// all and must not latch, or one pending draw would silence rung 3 for the
    /// rest of the match.
    private func ask(toSwap tile: Tile) async {
        switch await MainActor.run(body: { [session] in Self.offer(tile, to: session) }) {
        case .refused:
            swapAnswerStands = true
        case .declined:
            break
        case let .asked(mark):
            pendingSwap = mark
        }
    }

    @MainActor
    private static func offer(_ tile: Tile, to session: MatchSession) -> Ask {
        // Read here rather than from the snapshot: the snapshot's copy is a tick
        // old, and this is the read the latch is made from.
        guard session.options.swapEnabled else { return .refused }
        guard session.swap(tile) else { return .declined }
        return .asked(WireMark(session))
    }

    /// Looks for the answer to the outstanding swap request.
    ///
    /// The only signal a `MatchSession` shows the outside world for a refusal is
    /// ``MatchSession/lastNote``. A swap is only ever requested with no draw
    /// outstanding and `canDraw` false, so a note that *turns into* a refusal
    /// while a swap is in flight is that swap's refusal — the reason itself is
    /// never spelled out here, only the fact of one.
    ///
    /// An unmoved mark means unanswered, so nothing is cleared and nothing is
    /// asked again. (A refusal whose note is character-for-character the note
    /// already showing therefore reads as still-outstanding, which leaves the
    /// brain silent — the same side the latch errs on.)
    private func settleSwap() async {
        guard let outstanding = pendingSwap else { return }
        let now = await MainActor.run { [session] in WireMark(session) }
        guard now != outstanding else { return }
        pendingSwap = nil
        if now.note != outstanding.note, now.note?.hasPrefix(Self.refusalPrefix) == true {
            swapAnswerStands = true
        }
    }

    /// How `MatchSession` opens the note it writes for any refusal off the wire.
    /// A coupling to that one string, and the only one in this file.
    static let refusalPrefix = "refused:"

    /// What came of offering a tile back.
    private enum Ask: Sendable {
        /// The request is on the wire; the mark is what to watch for its answer.
        case asked(WireMark)
        /// Not now — locked, or a tile is waiting to be taken. Not an answer.
        case declined
        /// The host's answer, and it stands for the match.
        case refused
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
        do {
            for coord in plan.recalls { try session.recall(from: coord) }
            for move in plan.moves { try session.place(tileID: move.tileID, at: move.coord) }
        } catch {
            return restore(session, to: board) ? error : .placementFailed(rollbackFailed)
        }
        // A lone placement onto an untouched board is rung 0, already validated
        // as a whole board by the search that chose it. Anything else — any
        // recall, or more than one tile down — is a rung-1/2 attempt and must
        // clear the bar before it is allowed to stand.
        guard !plan.recalls.isEmpty || plan.moves.count > 1 else { return nil }

        let now = session.state.board
        let check = now.validate(against: dictionary)
        guard now.placements.count > board.placements.count,
              check.invalidWords.isEmpty,
              check.clusterCount <= 1
        else {
            return restore(session, to: board)
                ? .placementFailed("the attempt left the board no better")
                : .placementFailed(rollbackFailed)
        }
        return nil
    }

    /// Puts the board back exactly as `board` had it — the same tiles at the
    /// same coordinates — and says whether it got there.
    ///
    /// Every recall returns its tile to the rack and frees its cell, so by the
    /// time the re-placements run each tile is in hand and each cell is empty:
    /// under ``commit(_:_:from:dictionary:)``'s synchrony nothing here can be
    /// refused. The `try?`s are the belt on that reasoning and the returned
    /// `Bool` is the alarm on it — a `try?` that swallowed a real refusal shows
    /// up as a board that does not match, which the caller turns into a
    /// recorded ``BoardActionError`` rather than a silent half-applied plan.
    ///
    /// Returns early when nothing was mutated. That is not just a saving: every
    /// recall appends to the rack, so a needless round trip would reorder the
    /// hand of a board that never moved.
    @MainActor
    private static func restore(_ session: MatchSession, to board: Board) -> Bool {
        if session.state.board == board { return true }
        // Sorted: `placements` is a dictionary, every recall appends to the
        // rack, and the next tick's tile-major `step` reads that rack in order.
        // Unsorted here, the same rack after a rollback would not build the
        // same board twice.
        for coord in session.state.board.placements.keys.sorted(by: byCoord) {
            try? session.recall(from: coord)
        }
        for placement in board.placementList {
            try? session.place(tileID: placement.tileID, at: placement.coord)
        }
        return session.state.board == board
    }

    /// Recorded when a rollback could not put the board back. Nothing above can
    /// repair it, but a defect that reaches the results screen unannounced is
    /// worse than one that is in `lastPlacementError` when it happens.
    static let rollbackFailed = "the attempt failed and could not be rolled back"

    // MARK: - The ladder

    /// Walks the ladder up to `depth` and returns the first plan any rung
    /// offers.
    ///
    /// Rung 3 is only ever in range when ``mayAskToSwap(_:)`` said so, and it
    /// returns a plan with no recalls and no moves — a swap is not a board
    /// change and never reaches ``commit(_:_:from:dictionary:)``.
    ///
    /// `mayGiveBack` is the stall floor's separate door to rung 3, taken only
    /// after every rung in range has come back empty. It is not a depth: a bot
    /// let through here gains the swap and none of the searching rungs above
    /// its own, so being stuck never makes it a better player.
    func plan(on snapshot: Snapshot, depth: Int, mayGiveBack: Bool = false) -> Plan? {
        for rung in 0...depth {
            switch rung {
            case 0:
                if let move = extend(snapshot) { return Plan(recalls: [], moves: [move]) }
            case 1:
                if let plan = repair(snapshot) { return plan }
            case 2:
                if let plan = rebuild(snapshot) { return plan }
            case 3:
                if let tile = giveBack(snapshot) { return Plan(recalls: [], moves: [], swap: tile) }
            default:
                continue
            }
        }
        if mayGiveBack, let tile = giveBack(snapshot) {
            return Plan(recalls: [], moves: [], swap: tile)
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
        while budget > 0 {
            // On an empty board, ask for a whole word before asking for a tile.
            // Any single opening tile is legal, so `step` will happily open with
            // the Q and then find that nothing in the rack can legally touch
            // it — the tile is stranded by the very move that placed it, and
            // greedy has already spent the letters that would have saved it.
            // Opening with `QAT` is the only way that tile ever goes down, and
            // an empty board is the one moment the whole rack is still in hand.
            if board.placements.isEmpty,
               let opening = stepWord(on: board, from: pool, dictionary: dictionary, budget: &budget) {
                board = opening.board
                moves += opening.moves
                for move in opening.moves { pool.removeAll { $0.id == move.tileID } }
                continue
            }
            if let move = step(on: board, from: pool, dictionary: dictionary, budget: &budget) {
                guard let index = pool.firstIndex(where: { $0.id == move.tileID }),
                      (try? board.place(pool[index], at: move.coord)) != nil
                else { break }
                pool.remove(at: index)
                moves.append(move)
                continue
            }
            // Nothing fits one tile at a time. That is not the same as nothing
            // fitting: a tile whose every two-letter run is unwordable — a Q
            // with no QI in the list — can only ever go down beside its own
            // neighbours, so ask for a whole word before giving up.
            guard let laid = stepWord(on: board, from: pool, dictionary: dictionary, budget: &budget)
            else { break }
            board = laid.board
            moves += laid.moves
            for move in laid.moves { pool.removeAll { $0.id == move.tileID } }
        }
        return (board, moves)
    }

    /// Lays a whole word at once, for when no single tile can be laid at all.
    ///
    /// ``step(on:from:dictionary:budget:)`` keeps a placement only if the board
    /// is legal *after that one tile*, so it can only ever grow words whose
    /// every prefix is itself a word. ENABLE has no two-letter Q word, so a
    /// lone Q is unplaceable one tile at a time however the board is
    /// rearranged — pulling tiles off changes what is around it, never that
    /// `QA` is not a word. The tile has to go down with its neighbours or not
    /// at all, and that is what this does: place the whole run, validate once.
    ///
    /// Only ``fill(_:with:dictionary:budget:)`` reaches this, and only rungs 1
    /// and 2 reach `fill`, so it is exactly the rearranging rungs that gain it
    /// and an easy bot that does not.
    ///
    /// ponytail: rack-only words of at most ``maxWordTiles`` letters laid into
    /// empty cells. It will not read a letter already on the board as part of
    /// its word, so it finds `QAT` in hand but not the `Z` in front of an
    /// existing `OO`. Both widenings want a word list that can be enumerated
    /// rather than only asked, which is the frozen engine's call, not this
    /// lane's.
    private static func stepWord(
        on board: Board,
        from tiles: [Tile],
        dictionary: some WordList,
        budget: inout Int
    ) -> (board: Board, moves: [Move])? {
        // Capped separately from the rung's budget: `fill` asks for a word only
        // when it is already stuck, and a search that ate the whole repair
        // allowance on its first stuck tile would leave nothing for the seeds
        // still untried.
        let cap = min(budget, wordNodeBudget)
        guard cap > 0 else { return nil }
        var spend = cap
        let laid = layWord(on: board, from: tiles, dictionary: dictionary, budget: &spend)
        budget -= cap - spend
        return laid
    }

    /// ``stepWord(on:from:dictionary:budget:)`` inside its own budget.
    private static func layWord(
        on board: Board,
        from tiles: [Tile],
        dictionary: some WordList,
        budget: inout Int
    ) -> (board: Board, moves: [Move])? {
        // Distinct letters, counted: two tiles with the same letter spell the
        // same word, so only the count matters until a tile is actually chosen.
        var byLetter: [Character: [Tile]] = [:]
        for tile in tiles { byLetter[tile.letter, default: []].append(tile) }
        // Sorted, like every other walk over a dictionary in this file, or the
        // bot builds a different board each run from the same rack.
        let letters = byLetter.keys.sorted()
        // Fewer than two tiles spells nothing, and an empty pool has no first
        // letter to ask about.
        guard tiles.count > 1 else { return nil }

        var words: [[Character]] = []
        func grow(_ prefix: [Character], _ left: [Character: Int]) {
            if prefix.count >= 2, dictionary.contains(String(prefix)) { words.append(prefix) }
            guard prefix.count < maxWordTiles else { return }
            for letter in letters where left[letter, default: 0] > 0 {
                var next = left
                next[letter] = next[letter]! - 1
                grow(prefix + [letter], next)
            }
        }
        grow([], byLetter.mapValues(\.count))
        guard !words.isEmpty else { return nil }

        // Longest first, because a rung that rearranges the board should pay
        // for itself in tiles; then rarest letter first, because the tile that
        // got us stuck is the one worth spending the budget on.
        words.sort { lhs, rhs in
            let l = (-lhs.count, lhs.map(frequency).min() ?? 0, String(lhs))
            let r = (-rhs.count, rhs.map(frequency).min() ?? 0, String(rhs))
            return l < r
        }

        let anchors = frontier(of: board)
        for word in words {
            for (rowStep, colStep) in [(0, 1), (1, 0)] {
                // One start cell can be reached from several anchors at several
                // offsets, and every one of those is the same board.
                var tried: Set<Coord> = []
                for anchor in anchors {
                    for offset in 0..<word.count {
                        guard budget > 0 else { return nil }
                        let start = Coord(
                            row: anchor.row - rowStep * offset,
                            col: anchor.col - colStep * offset
                        )
                        guard tried.insert(start).inserted else { continue }
                        var trial = board
                        var moves: [Move] = []
                        var used: Set<UUID> = []
                        var fits = true
                        for (index, letter) in word.enumerated() {
                            let coord = Coord(
                                row: start.row + rowStep * index,
                                col: start.col + colStep * index
                            )
                            guard trial.tile(at: coord) == nil,
                                  let tile = byLetter[letter]?.first(where: { !used.contains($0.id) }),
                                  (try? trial.place(tile, at: coord)) != nil
                            else { fits = false; break }
                            used.insert(tile.id)
                            moves.append(Move(tileID: tile.id, coord: coord))
                        }
                        guard fits else { continue }
                        budget -= 1
                        if trial.validate(against: dictionary).invalidWords.isEmpty {
                            return (trial, moves)
                        }
                    }
                }
            }
        }
        return nil
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

    // MARK: - Rung 3: give a tile back

    /// Rung 3. Nothing extends the board, nothing repairs it and nothing
    /// rebuilds it — so pick the tile the rack is least likely to ever use and
    /// hand it back for three others.
    ///
    /// **Least useful** is: a tile whose letter pairs with nothing the rack
    /// holds comes before one that pairs with something; among equals, the
    /// rarer letter in English comes first; ties then by letter, then by tile
    /// id, so the order is total and two identical racks always give back the
    /// same tile.
    ///
    /// "Pairs with nothing" is the whole of the cheap test: every ordered pair
    /// of the rack's *distinct* letters is asked of the word list once, which is
    /// at most 26 × 26 = 676 `contains` calls and no board validation at all —
    /// next to nothing beside the 20,000-validation rebuild that has already
    /// failed by the time this runs.
    ///
    /// ponytail: two letters is the whole horizon — a tile that spells nothing
    /// as a pair could still be the third letter of a longer word. Widening it
    /// needs a `WordList` that can be enumerated rather than only asked, which
    /// is the frozen engine's call and not this lane's; revisit when it grows
    /// one.
    func giveBack(_ snapshot: Snapshot) -> Tile? {
        guard !snapshot.hand.isEmpty else { return nil }
        let dictionary = Self.effectiveDictionary(
            base: baseDictionary,
            options: snapshot.options
        )
        var counts: [Character: Int] = [:]
        for tile in snapshot.hand { counts[tile.letter, default: 0] += 1 }
        // Sorted: `counts` is a dictionary, and every walk over one in this file
        // is sorted or the bot stops being the same bot twice.
        let letters = counts.keys.sorted()
        var usable: Set<Character> = []
        for first in letters {
            // A letter can pair with itself only if the rack holds two of it.
            for second in letters where second != first || counts[first, default: 0] > 1 {
                guard dictionary.contains(String([first, second])) else { continue }
                usable.insert(first)
                usable.insert(second)
            }
        }
        return snapshot.hand.min { Self.usefulness($0, usable) < Self.usefulness($1, usable) }
    }

    /// The total order rung 3 picks its tile from — smallest is least useful.
    /// Tile id is last and breaks every remaining tie, so no two tiles compare
    /// equal.
    private static func usefulness(
        _ tile: Tile,
        _ usable: Set<Character>
    ) -> (Int, Int, Character, String) {
        (
            usable.contains(tile.letter) ? 1 : 0,
            frequency(tile.letter),
            tile.letter,
            tile.id.uuidString
        )
    }

    /// How often a letter turns up in English text, per mille. Rarer is less
    /// useful; an unknown letter is the least useful thing there is.
    static func frequency(_ letter: Character) -> Int {
        englishFrequency[letter] ?? 0
    }

    static let englishFrequency: [Character: Int] = [
        "E": 111, "A": 85, "R": 76, "I": 75, "O": 72, "T": 70, "N": 67,
        "S": 57, "L": 55, "C": 45, "U": 36, "D": 34, "P": 32, "M": 30,
        "H": 30, "G": 25, "B": 21, "F": 18, "Y": 18, "W": 13, "K": 11,
        "V": 10, "X": 3, "Z": 3, "J": 2, "Q": 2,
    ]

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

    /// Whole-board validations one whole-word search may spend. Small on
    /// purpose: it runs only when the rung is already stuck, and it must not
    /// eat the allowance the seeds still untried are counting on.
    static let wordNodeBudget = 600

    /// The longest word the whole-word search will try to lay from the rack.
    /// Three covers the tiles that strand a bot — `QAT`, `ZAS`, `XIS` — while
    /// keeping candidate generation at distinct-letters-cubed.
    static let maxWordTiles = 3

    /// How many fruitless stall-floor grants a bot below depth 3 must spend
    /// before the floor will hand a tile back for it. Tuned against
    /// `BotPlaysTests.harderPresetsPlayBetter`: too low and the escape makes
    /// every preset play alike, too high and an easy bot sits visibly dead.
    static let barrenGrantsBeforeGivingBack = 8

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
    ///
    /// The whole board, not its tile count: two different boards of the same
    /// size are two different searches, and a count would call the second one
    /// barren on the first one's evidence.
    ///
    /// The rack is *sorted*, because a rollback puts recalled tiles back on the
    /// end of the hand and so returns a rack that is the same multiset in a
    /// different order. Order is what the search walks, but "no move exists" is
    /// a fact about the multiset — if no tile fits anywhere, no permutation of
    /// them does either. Unsorted, every rolled-back attempt would look like
    /// fresh state and be searched again immediately.
    private struct Fingerprint: Equatable {
        let board: Board
        let rack: [UUID]

        init(_ snapshot: Snapshot) {
            board = snapshot.board
            rack = snapshot.hand.map(\.id).sorted()
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
    struct Snapshot: Sendable {
        let hand: [Tile]
        let board: Board
        let options: MatchOptions
    }

    struct Move: Sendable {
        let tileID: UUID
        let coord: Coord
    }

    /// One rung's whole answer: what to take off the board, then what to put
    /// down. Empty `recalls` is rung 0 — a plain extension.
    ///
    /// A plan is inert. It names coordinates and tile ids and nothing else, so
    /// it can be carried from the search actor to the main one and applied, or
    /// dropped, without either side holding the other's state.
    struct Plan: Sendable {
        let recalls: [Coord]
        let moves: [Move]
        /// Rung 3's whole answer: the tile to hand back. Never set alongside
        /// recalls or moves — a swap changes no board, so it is taken before
        /// `apply` and never sees the goodness check or the rollback.
        let swap: Tile?

        init(recalls: [Coord], moves: [Move], swap: Tile? = nil) {
            self.recalls = recalls
            self.moves = moves
            self.swap = swap
        }
    }
}
