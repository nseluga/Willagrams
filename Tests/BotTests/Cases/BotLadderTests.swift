import Foundation
import Testing
import WillagramsRules
import Match
@testable import Bot

/// Rungs 1 and 2 of the ladder, the transactional guarantee under them, and the
/// stall floor over them.
///
/// Two engineered scenarios carry every test here. Both are built from a *real*
/// deal, because the letters cannot be chosen — so the word list is chosen from
/// the letters instead. Every accepted word is spelled out of tiles the deal
/// actually produced, and every tile the scenario names has a letter that
/// occurs exactly once in the rack, so no other tile in hand can impersonate
/// it and make a rung fire that the scenario says cannot.
///
/// * **Repair** — board `a b / c`, rack holds `d`; words `ab ac bac dbac`.
///   No single tile extends it, but pulling `ab` and re-laying `d b a c` down
///   column 0 lands four tiles where three stood. Rung 1's case exactly.
/// * **Rebuild** — board `x y`, rack holds `p q r`; words `xy pq pqr`.
///   Nothing extends `xy` and nothing can be pulled from it (the pull would be
///   the whole board, which rung 1 refuses), but laying `p q r` out from an
///   empty board beats it. Rung 2's case exactly.
@MainActor
@Suite("Bot ladder")
struct BotLadderTests {

    // MARK: - Instruments

    /// Counts `contains` calls per thread. The brain searches off the main
    /// thread and commits on it, so main-thread calls are exactly the
    /// whole-board validations `BotBrain.commit` makes — one per attempt that
    /// reached the goodness check.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var main = 0
        func note(main isMain: Bool) {
            guard isMain else { return }
            lock.lock(); main += 1; lock.unlock()
        }
        var mainCalls: Int { lock.lock(); defer { lock.unlock() }; return main }
    }

    /// A word list of exactly the engineered words.
    ///
    /// `refuseOnMain` is the forced-rollback lever: the search (off the main
    /// thread) sees the real list and finds a plan, and `commit`'s goodness
    /// check (on the main thread) sees an empty list and refuses it. Nothing
    /// else about the run changes, so what is left behind is the rollback and
    /// only the rollback.
    struct ListedWordList: WordList {
        let accepted: Set<String>
        let counter: Counter?
        var refuseOnMain = false

        func contains(_ word: String) -> Bool {
            let isMain = Thread.isMainThread
            counter?.note(main: isMain)
            if refuseOnMain, isMain { return false }
            return accepted.contains(word)
        }
    }

    static func tick(_ depth: Int, _ stallFloorTicks: Int, _ delay: Duration) -> BotDifficulty {
        BotDifficulty(ladderDepth: depth, thinkDelay: delay, stallFloorTicks: stallFloorTicks)
    }

    // MARK: - Engineered scenarios

    /// A real deal whose rack carries at least `unique` letters that occur
    /// exactly once in it — the scenarios below are only airtight over tiles
    /// no other tile in hand can impersonate.
    static func dealt(
        unique count: Int,
        headMustBeUnique: Bool = false,
        handSize: Int = 12
    ) async throws -> (match: BotMatch, human: MatchSession, singles: [Tile]) {
        for seed in UInt64(1)...UInt64(60) {
            let (match, human) = BotBrainTests.matched(BotBrainTests.NoWordList())
            human.startMatch(seed: seed, startingHandSize: handSize, countdownSeconds: 0)
            try await BotBrainTests.waitUntil("bot dealt") {
                match.session.state.hand.count == handSize
            }
            let hand = match.session.state.hand
            var counts: [Character: Int] = [:]
            for tile in hand { counts[tile.letter, default: 0] += 1 }
            let singles = hand.filter { counts[$0.letter] == 1 }
            if singles.count >= count, !headMustBeUnique || counts[hand[0].letter] == 1 {
                return (match, human, singles)
            }
            match.leave()
        }
        Issue.record("no seed in 1...60 dealt \(count) rack letters that occur exactly once")
        throw CancellationError()
    }

    struct Scenario {
        let match: BotMatch
        let human: MatchSession
        let accepted: Set<String>
        /// The board as engineered — the exact mapping every rollback must
        /// come back to.
        let before: [Coord: Tile]
        /// The board a successful attempt must reach, tile for tile.
        let after: [Coord: Tile]
    }

    /// `a b / c` with `d` in hand: rung 0 cannot move, rung 1 can.
    static func repairScenario() async throws -> Scenario {
        let deal = try await dealt(unique: 4)
        let (a, b, c, d) = (deal.singles[0], deal.singles[1], deal.singles[2], deal.singles[3])
        let session = deal.match.session
        try session.place(tileID: a.id, at: Coord(row: 0, col: 0))
        try session.place(tileID: b.id, at: Coord(row: 0, col: 1))
        try session.place(tileID: c.id, at: Coord(row: 1, col: 0))
        return Scenario(
            match: deal.match,
            human: deal.human,
            accepted: [
                "\(a.letter)\(b.letter)",
                "\(a.letter)\(c.letter)",
                "\(b.letter)\(a.letter)\(c.letter)",
                "\(d.letter)\(b.letter)\(a.letter)\(c.letter)",
            ],
            before: [
                Coord(row: 0, col: 0): a,
                Coord(row: 0, col: 1): b,
                Coord(row: 1, col: 0): c,
            ],
            after: [
                Coord(row: -2, col: 0): d,
                Coord(row: -1, col: 0): b,
                Coord(row: 0, col: 0): a,
                Coord(row: 1, col: 0): c,
            ]
        )
    }

    /// `x y` with `p q r` in hand: rungs 0 and 1 cannot move, rung 2 can.
    ///
    /// `p` is the head of the rack, because rung 2's third pass is the one that
    /// opens on it — the rotation is what the extra tiles are worth here.
    static func rebuildScenario() async throws -> Scenario {
        let deal = try await dealt(unique: 5, headMustBeUnique: true)
        let session = deal.match.session
        let p = session.state.hand[0]
        let others = deal.singles.filter { $0.id != p.id }
        let (x, y, q, r) = (others[0], others[1], others[2], others[3])
        try session.place(tileID: x.id, at: Coord(row: 0, col: 0))
        try session.place(tileID: y.id, at: Coord(row: 0, col: 1))
        #expect(session.state.hand.first?.id == p.id)
        return Scenario(
            match: deal.match,
            human: deal.human,
            accepted: [
                "\(x.letter)\(y.letter)",
                "\(p.letter)\(q.letter)",
                "\(p.letter)\(q.letter)\(r.letter)",
            ],
            before: [Coord(row: 0, col: 0): x, Coord(row: 0, col: 1): y],
            after: [
                Coord(row: 0, col: 0): p,
                Coord(row: 0, col: 1): q,
                Coord(row: 0, col: 2): r,
            ]
        )
    }

    /// Board and rack are compared as whole mappings and then again coordinate
    /// by coordinate on tile *identity*, because two boards of the same shape
    /// spelled by different tiles are a lost tile, not a restored board.
    static func expectBoard(_ session: MatchSession, is expected: [Coord: Tile]) {
        let board = session.state.board
        #expect(board.placements == expected)
        for (coord, tile) in expected {
            #expect(board.tile(at: coord)?.id == tile.id, "wrong tile identity at \(coord)")
            #expect(board.tile(at: coord)?.letter == tile.letter, "wrong letter at \(coord)")
        }
        #expect(board.placements.count == expected.count)
    }

    // MARK: - Criterion 1 · rung 1 fires exactly where rung 0 cannot

    /// The ladder, in isolation, over a board and rack chosen tile by tile.
    /// Depth 0 has no answer; depth 1 pulls `ab` and lays `d b a c`.
    @Test("No single placement is legal: depth 0 finds nothing, depth 1 repairs")
    func rungOneFiresWhereRungZeroCannot() async throws {
        let a = Tile(letter: "A"), b = Tile(letter: "B")
        let c = Tile(letter: "C"), d = Tile(letter: "D")
        let board = Board(placements: [
            Coord(row: 0, col: 0): a,
            Coord(row: 0, col: 1): b,
            Coord(row: 1, col: 0): c,
        ])
        let list = ListedWordList(accepted: ["AB", "AC", "BAC", "DBAC"], counter: nil)
        let match = BotMatch(dictionary: list, sleepFor: { _ in })
        defer { match.leave() }
        let brain = BotBrain(session: match.session, dictionary: list, difficulty: .easy)
        let snapshot = BotBrain.Snapshot(hand: [d], board: board, options: .standard)

        let nothing = await brain.plan(on: snapshot, depth: 0)
        #expect(nothing == nil)

        let plan = try #require(await brain.plan(on: snapshot, depth: 1))
        #expect(plan.recalls == [Coord(row: 0, col: 0), Coord(row: 0, col: 1)])
        #expect(plan.moves.count == 3)

        // The plan, replayed: four tiles down where three stood, one cluster,
        // every word in the list.
        var built = board
        for coord in plan.recalls { built.remove(at: coord) }
        let byID = [a.id: a, b.id: b, c.id: c, d.id: d]
        for move in plan.moves {
            let tile = try #require(byID[move.tileID])
            try built.place(tile, at: move.coord)
        }
        #expect(built.placements == [
            Coord(row: -2, col: 0): d,
            Coord(row: -1, col: 0): b,
            Coord(row: 0, col: 0): a,
            Coord(row: 1, col: 0): c,
        ])
        let check = built.validate(against: list)
        #expect(check.invalidWords.isEmpty)
        #expect(check.clusterCount == 1)
    }

    // MARK: - Criterion 2 + guardrail 1 · a refused attempt restores exactly

    /// The rollback, forced and observed through a real session.
    ///
    /// The search finds rung 2's three-tile plan; the goodness check refuses
    /// it; what must be left behind is the board that was there before —
    /// `x` at (0,0) and `y` at (0,1), those tiles and no others.
    @Test("A refused rebuild leaves the board tile for tile and coordinate for coordinate")
    func aRefusedRebuildRestoresTheBoardExactly() async throws {
        let scenario = try await Self.rebuildScenario()
        defer { scenario.match.leave() }
        let counter = Counter()
        let list = ListedWordList(
            accepted: scenario.accepted, counter: counter, refuseOnMain: true
        )
        let handBefore = Set(scenario.match.session.state.hand.map { $0.id })

        let brain = BotBrain(
            session: scenario.match.session,
            dictionary: list,
            difficulty: Self.tick(2, 1_000_000, .milliseconds(5))
        )
        let driver = Task { await brain.run() }
        defer { driver.cancel() }

        // Not vacuous: the attempt ran, reached the goodness check and was
        // rolled back. A test that only watched the board would pass on a brain
        // that never tried.
        var refusal: BoardActionError?
        let limit = ContinuousClock.now + .seconds(5)
        while refusal == nil, ContinuousClock.now < limit {
            refusal = await brain.lastPlacementError
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(refusal == .placementFailed("the attempt left the board no better"))
        #expect(counter.mainCalls > 0)

        driver.cancel()
        Self.expectBoard(scenario.match.session, is: scenario.before)
        // And no tile was lost on the way back: rack and board still hold the
        // whole deal.
        let handAfter = Set(scenario.match.session.state.hand.map { $0.id })
        #expect(handAfter == handBefore)
    }

    /// The other half of criterion 2, in isolation: a rebuild with nothing
    /// better to find proposes nothing at all, so there is no attempt to roll
    /// back in the first place.
    @Test("A rebuild that finds nothing better returns no plan")
    func afruitlessRebuildProposesNothing() async throws {
        let x = Tile(letter: "X"), y = Tile(letter: "Y")
        let junk = "EFGHIJKLMNO".map { Tile(letter: $0) }
        let board = Board(placements: [
            Coord(row: 0, col: 0): x, Coord(row: 0, col: 1): y,
        ])
        let list = ListedWordList(accepted: ["XY", "PQ", "PQR"], counter: nil)
        let match = BotMatch(dictionary: list, sleepFor: { _ in })
        defer { match.leave() }
        let brain = BotBrain(session: match.session, dictionary: list, difficulty: .medium)
        let snapshot = BotBrain.Snapshot(hand: junk, board: board, options: .standard)
        #expect(await brain.plan(on: snapshot, depth: 2) == nil)
        #expect(board.placements == [Coord(row: 0, col: 0): x, Coord(row: 0, col: 1): y])
    }

    // MARK: - Criterion 3 · the stall floor

    /// A depth-0 bot on a rack no single placement can use. The floor is what
    /// gets the tile down — and it is not allowed to do it early.
    @Test("A depth-0 bot still places, at the stall floor and not before")
    func theStallFloorGetsADepthZeroBotMoving() async throws {
        let scenario = try await Self.repairScenario()
        defer { scenario.match.leave() }
        let floor = 5
        let delay = Duration.milliseconds(30)
        let brain = BotBrain(
            session: scenario.match.session,
            dictionary: ListedWordList(accepted: scenario.accepted, counter: nil),
            difficulty: Self.tick(0, floor, delay)
        )
        let started = ContinuousClock.now
        let driver = Task { await brain.run() }
        defer { driver.cancel() }

        try await BotBrainTests.waitUntil("the stall floor placed a tile") {
            scenario.match.session.state.board.placements.count == 4
        }
        let elapsed = ContinuousClock.now - started
        driver.cancel()

        // Four ticks' worth at the very least: a bot that reached rung 1 on its
        // own, or granted itself the floor early, arrives far sooner.
        #expect(elapsed >= delay * 4, "placed after \(elapsed), before the floor could have fired")
        Self.expectBoard(scenario.match.session, is: scenario.after)
    }

    /// The counter reset, measured. Every attempt here is refused, so the floor
    /// fires over and over — and it must fire once per window, not once per
    /// tick. Main-thread validations count the attempts.
    @Test("The stall floor grants one attempt per window, not one per tick")
    func theStallFloorCounterResets() async throws {
        // The repair scenario, not the rebuild one: a rolled-back repair leaves
        // a rack the next repair reads identically, so every grant finds the
        // same plan and is refused again. What varies is only how often a grant
        // comes.
        let scenario = try await Self.repairScenario()
        defer { scenario.match.leave() }
        let counter = Counter()
        let floor = 8
        let delay = Duration.milliseconds(20)
        let brain = BotBrain(
            session: scenario.match.session,
            dictionary: ListedWordList(
                accepted: scenario.accepted, counter: counter, refuseOnMain: true
            ),
            difficulty: Self.tick(0, floor, delay)
        )
        let driver = Task { await brain.run() }
        defer { driver.cancel() }
        try await Task.sleep(for: .seconds(1))
        driver.cancel()

        // At most 50 ticks fit in a second at 20 ms each, so a floor of 8 that
        // resets buys at most ~6 attempts. A counter that never reset would
        // grant every tick after the eighth: more than 40.
        let attempts = counter.mainCalls
        #expect(attempts >= 2, "the stall floor never fired twice")
        #expect(attempts <= 12, "\(attempts) attempts in a second: the counter did not reset")
        Self.expectBoard(scenario.match.session, is: scenario.before)
    }

    // MARK: - Guardrail 3 · no rung above the declared depth

    /// Same board, same rack, same word list as the rebuild scenario — only the
    /// depth differs, and rung 2 is one rung too far. With the floor out of
    /// reach the brain must simply sit there: no attempt, no validation, no
    /// board.
    @Test("A rung above ladderDepth is never attempted without the stall floor")
    func noRungAboveTheDeclaredDepth() async throws {
        let scenario = try await Self.rebuildScenario()
        defer { scenario.match.leave() }
        let counter = Counter()
        let brain = BotBrain(
            session: scenario.match.session,
            dictionary: ListedWordList(accepted: scenario.accepted, counter: counter),
            difficulty: Self.tick(1, 1_000_000, .milliseconds(5))
        )
        let driver = Task { await brain.run() }
        defer { driver.cancel() }
        try await Task.sleep(for: .milliseconds(400))
        driver.cancel()

        #expect(counter.mainCalls == 0, "a rung-2 plan was committed at ladderDepth 1")
        #expect(await brain.lastPlacementError == nil)
        Self.expectBoard(scenario.match.session, is: scenario.before)
    }

    // MARK: - Criterion 4 + guardrail 2 · rung 2 is bounded

    /// A full 21-tile rack over a board rungs 0 and 1 both refuse. Rung 2 must
    /// come back with a board, and come back at all.
    @Test("Rung 2 terminates and returns a board on a 21-tile rack")
    func rungTwoTerminatesOnAFullRack() async throws {
        let x = Tile(letter: "X"), y = Tile(letter: "Y")
        let p = Tile(letter: "P"), q = Tile(letter: "Q"), r = Tile(letter: "R")
        // 21 tiles: the three the rebuild needs, and eighteen it cannot use.
        let junk = "BCDEFGHIJKLMNOSTUV".map { Tile(letter: $0) }
        #expect(junk.count == 18)
        let board = Board(placements: [
            Coord(row: 0, col: 0): x, Coord(row: 0, col: 1): y,
        ])
        let list = ListedWordList(accepted: ["XY", "PQ", "PQR"], counter: nil)
        let match = BotMatch(dictionary: list, sleepFor: { _ in })
        defer { match.leave() }
        let brain = BotBrain(session: match.session, dictionary: list, difficulty: .medium)
        let snapshot = BotBrain.Snapshot(
            hand: [p] + junk + [q, r], board: board, options: .standard
        )
        #expect(snapshot.hand.count == 21)

        #expect(await brain.plan(on: snapshot, depth: 1) == nil)
        let started = ContinuousClock.now
        let plan = try #require(await brain.plan(on: snapshot, depth: 2))
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .seconds(5), "rung 2 took \(elapsed) on a 21-tile rack")
        #expect(plan.recalls == [Coord(row: 0, col: 0), Coord(row: 0, col: 1)])
        #expect(plan.moves.count == 3)
        #expect(Set(plan.moves.map(\.tileID)) == Set([p.id, q.id, r.id]))
    }

    /// The budget is declared, finite and named — not "search until done".
    @Test("Rung 2 declares a finite node budget and a finite restart count")
    func rungTwoDeclaresItsBudget() {
        #expect(BotBrain.rebuildNodeBudget == 20_000)
        #expect(BotBrain.rebuildRestarts == 3)
        #expect(BotBrain.repairNodeBudget == 4_000)
        #expect(BotBrain.rebuildNodeBudget < Int.max)
        #expect(BotBrain.rebuildRestarts < Int.max)
    }

    // MARK: - Guardrail 4 · every recall goes through the session

    /// The brain owns no board. Behaviour cannot show this — `state` is
    /// `private(set)`, so the compiler already refuses a direct write — but a
    /// second path to the board (a `Board` handed to the session wholesale, a
    /// recall that is not the session's) is exactly the kind of shortcut a
    /// later rung would reach for.
    @Test("Every recall in the bot source goes through MatchSession.recall(from:)")
    func everyRecallGoesThroughTheSession() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BotSrc")
            .resolvingSymlinksInPath()
        for file in try FileManager.default
            .contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "swift" })
        {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
            let recalls = lines.filter { $0.contains("recall(") }
            #expect(
                recalls.allSatisfy { $0.contains("session.recall(from:") },
                "\(file.lastPathComponent) recalls outside MatchSession: \(recalls)"
            )
            let writes = lines.filter {
                $0.contains("state.board = ") || $0.contains("state.hand = ")
                    || $0.contains("state.board.place(") || $0.contains("state.board.remove(")
            }
            #expect(writes.isEmpty, "\(file.lastPathComponent) writes session state: \(writes)")
        }
    }

    @Test("A tile with no two-letter word goes down inside a whole word, or not at all")
    func aStrandedTileIsLaidAsPartOfAWord() async throws {
        // The shape that stranded the bot in a real match, reduced: `Q` spells
        // nothing with one neighbour, so no sequence of single legal placements
        // ever reaches `QAT` — `QA` is not a word, and the board is invalid the
        // instant the second tile lands. The whole run has to go down together.
        let x = Tile(letter: "X"), y = Tile(letter: "Y")
        let q = Tile(letter: "Q"), a = Tile(letter: "A"), t = Tile(letter: "T")
        let board = Board(placements: [
            Coord(row: 0, col: 0): x, Coord(row: 0, col: 1): y,
        ])
        // No two-letter word touches Q, and nothing in the rack extends `XY`.
        let list = ListedWordList(accepted: ["XY", "QAT"], counter: nil)
        let match = BotMatch(dictionary: list, sleepFor: { _ in })
        defer { match.leave() }
        let brain = BotBrain(session: match.session, dictionary: list, difficulty: .medium)
        let snapshot = BotBrain.Snapshot(hand: [q, a, t], board: board, options: .standard)

        // Rung 0 has one tile to spend and no legal cell for it. Rung 1 would
        // have to pull the whole board, which it refuses. An easy bot lives
        // here, and this tile is why it will sit until the stall floor swaps.
        #expect(await brain.plan(on: snapshot, depth: 0) == nil)
        #expect(await brain.plan(on: snapshot, depth: 1) == nil)

        // Rung 2 tears the board down, and on the empty board it opens with a
        // word rather than a tile — which is the only move that places the Q.
        let plan = try #require(await brain.plan(on: snapshot, depth: 2))
        #expect(plan.recalls == [Coord(row: 0, col: 0), Coord(row: 0, col: 1)])
        #expect(plan.moves.count == 3)
        #expect(plan.moves.contains { $0.tileID == q.id }, "the stranded tile is still stranded")

        // Replayed: the three tiles spell the word, contiguously and in order.
        var replay = Board()
        for move in plan.moves {
            let tile = try #require([q, a, t].first { $0.id == move.tileID })
            try replay.place(tile, at: move.coord)
        }
        #expect(replay.validate(against: list).invalidWords.isEmpty)
        #expect(replay.words().map(\.text).sorted() == ["QAT"])
    }
}
