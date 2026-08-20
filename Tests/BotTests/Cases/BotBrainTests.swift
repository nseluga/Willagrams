import Foundation
import Testing
import WillagramsRules
import Match
@testable import Bot

/// The brain, driven against a real `MatchSession` on a real link.
///
/// Every wait here is bounded and records an issue on timeout: a brain that
/// never reaches the condition must fail the suite, not hang it.
@MainActor
@Suite("Bot brain")
struct BotBrainTests {

    /// Every word is a word. Lets the search always find a legal cell, so a
    /// full match runs deterministically instead of on the luck of the deal.
    struct AnyWordList: WordList {
        func contains(_ word: String) -> Bool { true }
    }

    /// Nothing is a word. Any run of two tiles is invalid, so the bot can place
    /// exactly one tile and then legitimately has no move.
    struct NoWordList: WordList {
        func contains(_ word: String) -> Bool { false }
    }

    /// Only `AB` is a word — and only when the minimum length allows it.
    struct TinyWordList: WordList {
        func contains(_ word: String) -> Bool { word == "AB" }
    }

    /// No pause at all: `.zero` still suspends, so the main actor is never
    /// starved, but no test spends real time thinking.
    static let instant = BotDifficulty(ladderDepth: 0, thinkDelay: .zero, stallFloorTicks: 4)

    static func matched(
        _ dictionary: some WordList
    ) -> (bot: BotMatch, human: MatchSession) {
        let match = BotMatch(dictionary: dictionary, sleepFor: { _ in })
        let human = MatchSession(
            transport: match.humanTransport,
            peerPlayerID: BotMatch.botPlayerID,
            dictionary: dictionary,
            sleepFor: { _ in }
        )
        return (match, human)
    }

    /// Bounded wait. `probe` runs on every poll, which is where the invariants
    /// that must hold *throughout* a run are checked.
    static func waitUntil(
        _ label: String,
        seconds: Int = 5,
        probe: @MainActor () -> Void = {},
        _ condition: @MainActor () -> Bool
    ) async throws {
        let limit = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            probe()
            guard ContinuousClock.now < limit else {
                Issue.record("timed out waiting for \(label)")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        probe()
    }

    // MARK: - Search shape

    @Test("An empty board offers exactly the origin")
    func frontierOfEmptyBoard() {
        #expect(BotBrain.frontier(of: Board()) == [Coord(row: 0, col: 0)])
    }

    @Test("The frontier is every empty neighbour, deduplicated and in a fixed order")
    func frontierIsOrderedAndUnique() {
        let board = Board(placements: [
            Coord(row: 0, col: 0): Tile(letter: "A"),
            Coord(row: 0, col: 1): Tile(letter: "B"),
        ])
        let frontier = BotBrain.frontier(of: board)
        #expect(frontier == [
            Coord(row: -1, col: 0), Coord(row: -1, col: 1),
            Coord(row: 0, col: -1), Coord(row: 0, col: 2),
            Coord(row: 1, col: 0), Coord(row: 1, col: 1),
        ])
        #expect(!frontier.contains(Coord(row: 0, col: 0)))
    }

    /// The guardrail: the bot plays by the match's minimum word length, not by
    /// the raw list it was handed.
    @Test("The effective list is the base list wrapped by the match's minimum length")
    func effectiveDictionaryHonoursOptions() {
        var raised = MatchOptions.standard
        raised.minimumWordLength = 4
        let strict = BotBrain.effectiveDictionary(base: TinyWordList(), options: raised)
        #expect(strict.contains("AB") == false)

        let standard = BotBrain.effectiveDictionary(base: TinyWordList(), options: .standard)
        #expect(standard.contains("AB") == true)
    }

    @Test("The presets carry distinct ladder depths and the tuning constants")
    func presets() {
        #expect(BotDifficulty.easy.ladderDepth == 0)
        #expect(BotDifficulty.medium.ladderDepth == 2)
        #expect(BotDifficulty.hard.ladderDepth == 3)
        #expect(BotDifficulty.hard.thinkDelay < BotDifficulty.easy.thinkDelay)
        #expect(BotDifficulty.hard.stallFloorTicks < BotDifficulty.easy.stallFloorTicks)
        #expect(BotDifficulty.easy == BotDifficulty(
            ladderDepth: 0, thinkDelay: .milliseconds(1200), stallFloorTicks: 12
        ))
    }

    // MARK: - Playing

    @Test("The bot empties its rack onto one valid cluster and then draws")
    func placesUntilItCanDrawThenDraws() async throws {
        let handSize = 3
        let (match, human) = Self.matched(AnyWordList())
        defer { match.leave() }
        human.startMatch(seed: 21, startingHandSize: handSize, countdownSeconds: 0)
        try await Self.waitUntil("bot dealt") { match.session.state.hand.count == handSize }

        let brain = BotBrain(
            session: match.session,
            dictionary: AnyWordList(),
            difficulty: Self.instant
        )
        let driver = Task { await brain.run() }
        defer { driver.cancel() }

        // The rack empties onto the board, and the board it stopped on is one
        // cluster with no invalid words.
        try await Self.waitUntil("rack emptied onto the board") {
            match.session.state.hand.isEmpty
                && match.session.state.board.placements.count >= handSize
        }
        let validation = match.session.state.board.validate(against: AnyWordList())
        #expect(validation.clusterCount == 1)
        #expect(validation.invalidWords.isEmpty)
        #expect(validation.isComplete)

        // `canDraw` was therefore true, and the next thing on the wire was a
        // draw request: the host answered it, so the bot holds more tiles than
        // it was dealt.
        try await Self.waitUntil("the draw request came back granted") {
            match.session.state.hand.count + match.session.state.board.placements.count > handSize
        }
    }

    /// The conservation criterion. Polled on the main actor, so no intermediate
    /// state is observable: a tile is in the rack or on the board, never
    /// neither and never both.
    @Test("A full match loses and duplicates no tile, and the bot wins on exhaustion")
    func fullMatchConservesTilesAndWinsHonestly() async throws {
        let (match, human) = Self.matched(AnyWordList())
        defer { match.leave() }
        human.startMatch(seed: 9, startingHandSize: 7, countdownSeconds: 0)
        try await Self.waitUntil("bot dealt") { match.session.state.hand.count == 7 }

        let brain = BotBrain(
            session: match.session,
            dictionary: AnyWordList(),
            difficulty: Self.instant
        )
        let driver = Task { await brain.run() }
        defer { driver.cancel() }

        var highWater = 0
        let probe: @MainActor () -> Void = {
            let hand = match.session.state.hand
            let board = match.session.state.board
            let ids = Set(hand.map(\.id)).union(board.placements.values.map(\.id))
            // No tile is in two places, and none has been dropped.
            #expect(ids.count == hand.count + board.placements.count)
            #expect(hand.count + board.placements.count >= highWater)
            highWater = max(highWater, hand.count + board.placements.count)
            // The honesty predicate: no win reached the human before the pool
            // ran dry.
            if human.winner != nil {
                #expect(match.session.poolIsExhausted)
            }
        }

        try await Self.waitUntil("the bot won", seconds: 60, probe: probe) {
            human.winner != nil
        }

        #expect(human.winner == BotMatch.botPlayerID)
        #expect(match.session.winner == BotMatch.botPlayerID)
        #expect(match.session.poolIsExhausted)
        #expect(match.session.state.board.validate(against: AnyWordList()).isComplete)
        #expect(match.session.state.hand.isEmpty)
        #expect(highWater == match.session.state.board.placements.count)

        // Exactly once: the session is finished, so a second claim is refused
        // and the human's winner cannot be overwritten.
        #expect(match.session.claimWin() == false)
    }

    @Test("With no legal word the bot never claims a win and never draws")
    func noWinWhileTheBoardIsIncomplete() async throws {
        let (match, human) = Self.matched(NoWordList())
        defer { match.leave() }
        human.startMatch(seed: 4, startingHandSize: 5, countdownSeconds: 0)
        try await Self.waitUntil("bot dealt") { match.session.state.hand.count == 5 }

        let brain = BotBrain(
            session: match.session,
            dictionary: NoWordList(),
            difficulty: Self.instant
        )
        let driver = Task { await brain.run() }
        defer { driver.cancel() }

        // One lone tile spells nothing, so it is legal; a second would make a
        // two-letter run that is not a word. The bot stalls there.
        try await Self.waitUntil("the first tile landed") {
            match.session.state.board.placements.count == 1
        }
        // Many ticks later, still stalled and still silent.
        for _ in 0..<50 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))

        #expect(match.session.state.board.placements.count == 1)
        #expect(match.session.state.hand.count == 4)
        #expect(match.session.canDraw == false)
        #expect(match.session.poolIsExhausted == false)
        #expect(human.winner == nil)
        #expect(match.session.winner == nil)
    }

    @Test("A human win stops the brain dead and names the human")
    func humanWinEndsIt() async throws {
        let (match, human) = Self.matched(AnyWordList())
        defer { match.leave() }
        human.startMatch(seed: 15, startingHandSize: 4, countdownSeconds: 0)
        try await Self.waitUntil("bot dealt") { match.session.state.hand.count == 4 }

        human.claimWin()
        try await Self.waitUntil("the bot heard the human win") {
            match.session.winner != nil
        }
        #expect(match.session.winner == BotMatch.humanPlayerID)

        let board = match.session.state.board
        let hand = match.session.state.hand
        let brain = BotBrain(
            session: match.session,
            dictionary: AnyWordList(),
            difficulty: Self.instant
        )
        // `run()` returns of its own accord on a finished match rather than
        // being cancelled — awaiting it here would hang if it did not.
        await brain.run()

        #expect(match.session.state.board == board)
        #expect(match.session.state.hand == hand)
        #expect(match.session.winner == BotMatch.humanPlayerID)
        #expect(human.winner == BotMatch.humanPlayerID)
    }

    /// The stale-snapshot path, forced: a grant is waiting, so `place` throws
    /// `.drawPending` for any move the brain chooses. The brain must take the
    /// tile rather than jam.
    @Test("A pending grant is taken first, before any search")
    func pendingDrawComesFirst() async throws {
        let (match, human) = Self.matched(AnyWordList())
        defer { match.leave() }
        human.startMatch(seed: 33, startingHandSize: 2, countdownSeconds: 0)
        try await Self.waitUntil("bot dealt") { match.session.state.hand.count == 2 }

        // The human draws; the host grants to both players, and the bot's
        // grant arrives as a pending obligation that freezes its board.
        human.draw()
        try await Self.waitUntil("the bot owes a draw") { match.session.hasPendingDraw }
        #expect(throws: BoardActionError.drawPending) {
            try match.session.place(
                tileID: match.session.state.hand[0].id,
                at: Coord(row: 0, col: 0)
            )
        }

        let brain = BotBrain(
            session: match.session,
            dictionary: AnyWordList(),
            difficulty: Self.instant
        )
        let driver = Task { await brain.run() }
        defer { driver.cancel() }

        try await Self.waitUntil("the bot took the pending tile and played on") {
            !match.session.hasPendingDraw && !match.session.state.board.placements.isEmpty
        }
        // Nothing was lost taking it: three tiles granted, three accounted for.
        #expect(
            match.session.state.hand.count + match.session.state.board.placements.count >= 3
        )
    }
}
