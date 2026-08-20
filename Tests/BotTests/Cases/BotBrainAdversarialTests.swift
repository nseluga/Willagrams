import Foundation
import Testing
import WillagramsRules
import Match
@testable import Bot

/// Independent verification of the flagged criteria: win honesty, tile
/// conservation under a grant landing mid-search, and the brain stopping dead
/// when the human wins *while it is already running*.
///
/// Every wait is bounded and records an issue on timeout.
@MainActor
@Suite("Bot brain adversarial")
struct BotBrainAdversarialTests {

    struct AnyWordList: WordList {
        func contains(_ word: String) -> Bool { true }
    }

    /// Records which thread the search ran on and lets a test fire a side
    /// effect from *inside* the search, which is where the grant race lives.
    final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var mainThread = false
        private let onCall: (@Sendable (Int) -> Void)?

        init(onCall: (@Sendable (Int) -> Void)? = nil) { self.onCall = onCall }

        func note() -> Int {
            lock.lock()
            calls += 1
            if Thread.isMainThread { mainThread = true }
            let n = calls
            lock.unlock()
            onCall?(n)
            return n
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    }

    /// Agrees with `AnyWordList` on every word, so swapping it into the brain
    /// changes only the observation, never the play.
    struct SpyWordList: WordList {
        let spy: Spy
        func contains(_ word: String) -> Bool {
            _ = spy.note()
            return true
        }
    }

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

    static func waitUntil(
        _ label: String,
        seconds: Int = 10,
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

    // MARK: - Criterion 3: the honesty predicate

    /// The host owns the pool, so the host's own exhaustion latch is the only
    /// account of the pool the bot cannot influence. A bot that claimed early
    /// leaves this `false` for good — it stops drawing the moment it wins, so
    /// nothing afterwards can drain the host's pool and cover the lie.
    @Test("Every win the host receives arrives with the host's own pool already dry",
          arguments: [3, 9, 17, 42] as [UInt64])
    func winIsHonestOnTheHostSide(seed: UInt64) async throws {
        let (match, human) = Self.matched(AnyWordList())
        defer { match.leave() }
        human.startMatch(seed: seed, startingHandSize: 5, countdownSeconds: 0)
        try await Self.waitUntil("bot dealt") { match.session.state.hand.count == 5 }

        let brain = BotBrain(session: match.session, dictionary: AnyWordList(), difficulty: Self.instant)
        let driver = Task { await brain.run() }
        defer { driver.cancel() }

        try await Self.waitUntil("the bot won", seconds: 60) { human.winner != nil }

        #expect(human.winner == BotMatch.botPlayerID)
        // The host's authority, not the bot's word for it.
        #expect(human.poolIsExhausted)
        // And the claim implies a finished board, because `canDraw` is
        // hand-empty-and-complete.
        #expect(match.session.state.hand.isEmpty)
        #expect(match.session.state.board.validate(against: AnyWordList()).isComplete)
        #expect(match.session.state.board.validate(against: AnyWordList()).clusterCount == 1)
    }

    /// The negative half of criterion 3, exercised where it actually bites:
    /// `canDraw` goes true over and over while the pool still has tiles, and
    /// the bot must draw every single time instead of claiming.
    @Test("Many complete boards with a live pool produce draws and never a win")
    func noWinWhileThePoolHasTiles() async throws {
        let (match, human) = Self.matched(AnyWordList())
        defer { match.leave() }
        human.startMatch(seed: 11, startingHandSize: 3, countdownSeconds: 0)
        try await Self.waitUntil("bot dealt") { match.session.state.hand.count == 3 }

        let brain = BotBrain(session: match.session, dictionary: AnyWordList(), difficulty: Self.instant)
        let driver = Task { await brain.run() }
        defer { driver.cancel() }

        var completionsSeen = 0
        let probe: @MainActor () -> Void = {
            if match.session.canDraw { completionsSeen += 1 }
            // While the *host* still holds tiles, nobody may have won.
            if !human.poolIsExhausted {
                #expect(match.session.winner == nil)
                #expect(human.winner == nil)
            }
        }

        // Grow the board well past the opening deal: every step of that growth
        // is a completed board followed by a draw rather than a claim.
        try await Self.waitUntil("the board grew past 24 tiles", seconds: 60, probe: probe) {
            match.session.state.board.placements.count >= 24 || human.poolIsExhausted
        }
        #expect(completionsSeen > 0)
    }

    // MARK: - Guardrail: the search never runs on the main actor

    @Test("The search's dictionary is never consulted from the main thread")
    func searchIsNeverOnMain() async throws {
        let spy = Spy()
        let (match, human) = Self.matched(AnyWordList())
        defer { match.leave() }
        human.startMatch(seed: 7, startingHandSize: 6, countdownSeconds: 0)
        try await Self.waitUntil("bot dealt") { match.session.state.hand.count == 6 }

        // The session keeps its own list; only the brain gets the spy, so every
        // recorded call is a search call.
        let brain = BotBrain(session: match.session, dictionary: SpyWordList(spy: spy), difficulty: Self.instant)
        let driver = Task { await brain.run() }
        defer { driver.cancel() }

        try await Self.waitUntil("the search ran") { spy.count > 0 }
        try await Self.waitUntil("several tiles landed") {
            match.session.state.board.placements.count >= 4
        }
        driver.cancel()
        #expect(spy.count > 0)
        #expect(spy.ranOnMain == false)
    }

    // MARK: - Criterion 2: a grant landing mid-search

    /// Forces the race the happy path never hits: the human draws from *inside*
    /// the bot's search, so the grant lands against a snapshot the brain is
    /// still holding. Every move the brain then chooses is stale.
    @Test("A grant landing mid-search loses and duplicates no tile")
    func grantMidSearchConservesTiles() async throws {
        let (match, human) = Self.matched(AnyWordList())
        defer { match.leave() }

        // Fired from the search thread: request a round and then hold the
        // search still long enough for the grant to land on the main actor
        // while this tick's snapshot is already stale.
        let humanBox = UncheckedBox(human)
        let spy = Spy { n in
            guard n % 8 == 1, n < 600 else { return }
            Task { @MainActor in humanBox.value.draw() }
            Thread.sleep(forTimeInterval: 0.02)
        }

        human.startMatch(seed: 5, startingHandSize: 4, countdownSeconds: 0)
        try await Self.waitUntil("bot dealt") { match.session.state.hand.count == 4 }

        let brain = BotBrain(session: match.session, dictionary: SpyWordList(spy: spy), difficulty: Self.instant)
        let driver = Task { await brain.run() }
        defer { driver.cancel() }

        var everSeen: Set<UUID> = []
        var highWater = 0
        let probe: @MainActor () -> Void = {
            let hand = match.session.state.hand
            let board = match.session.state.board
            let ids = Set(hand.map(\.id)).union(board.placements.values.map(\.id))
            // No tile in two places at once.
            #expect(ids.count == hand.count + board.placements.count)
            // Nothing the bot was granted ever disappears.
            #expect(everSeen.subtracting(ids).isEmpty)
            everSeen.formUnion(ids)
            #expect(ids.count >= highWater)
            highWater = max(highWater, ids.count)
            if !human.poolIsExhausted { #expect(match.session.winner == nil) }
            // A draw storm from the main actor as well, so grants land at
            // arbitrary points in the brain's tick, not only inside `contains`.
            if !human.poolIsExhausted { human.draw() }
        }

        try await Self.waitUntil("the match ended", seconds: 90, probe: probe) {
            match.session.winner != nil
        }

        #expect(match.session.winner == BotMatch.botPlayerID)
        #expect(human.poolIsExhausted)
        let final = Set(match.session.state.hand.map(\.id))
            .union(match.session.state.board.placements.values.map(\.id))
        // Exactly the tiles it was granted, no more and no fewer.
        #expect(final == everSeen)
        #expect(match.session.state.board.validate(against: AnyWordList()).isComplete)
        // The race really happened.
        #expect(spy.count > 8)
    }

    // MARK: - Criterion 4: the human wins mid-run

    @Test("A human win arriving mid-run stops the brain and names the human")
    func humanWinMidRunStopsTheBrain() async throws {
        let (match, human) = Self.matched(AnyWordList())
        defer { match.leave() }
        human.startMatch(seed: 13, startingHandSize: 7, countdownSeconds: 0)
        try await Self.waitUntil("bot dealt") { match.session.state.hand.count == 7 }

        let returned = UncheckedFlag()
        let brain = BotBrain(session: match.session, dictionary: AnyWordList(), difficulty: Self.instant)
        let driver = Task { await brain.run(); returned.set() }
        defer { driver.cancel() }

        // Let the brain get properly under way first.
        try await Self.waitUntil("the brain is placing") {
            match.session.state.board.placements.count >= 2
        }

        human.claimWin()
        try await Self.waitUntil("the bot heard the win") { match.session.winner != nil }
        #expect(match.session.winner == BotMatch.humanPlayerID)

        // `run()` must return on its own; a brain that kept ticking never sets
        // this and the bounded wait fails rather than hangs.
        try await Self.waitUntil("run() returned by itself") { returned.isSet }

        let board = match.session.state.board
        let hand = match.session.state.hand
        for _ in 0..<100 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))

        #expect(match.session.state.board == board)
        #expect(match.session.state.hand == hand)
        #expect(match.session.winner == BotMatch.humanPlayerID)
        #expect(human.winner == BotMatch.humanPlayerID)
    }
}

/// Carries a main-actor value into a `@Sendable` closure that hops back to the
/// main actor before touching it.
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

final class UncheckedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
