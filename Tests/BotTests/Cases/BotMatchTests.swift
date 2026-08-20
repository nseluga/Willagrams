import Foundation
import Testing
import WillagramsRules
import Match
import Bot

/// The bot's end of the wire: connected, dealt to, and playing nothing.
///
/// The human half is built here rather than by `BotMatch`, exactly as the shell
/// will build it — on `humanTransport`, with `BotMatch.botPlayerID` as the peer.
@MainActor
@Suite("Bot match")
struct BotMatchTests {

    struct AnyWordList: WordList {
        func contains(_ word: String) -> Bool { true }
    }

    /// The house pattern from `MatchTests`: bounded, and records an issue
    /// rather than hanging the suite.
    static func waitUntil(_ label: String, _ condition: @MainActor () -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < limit else {
                Issue.record("timed out waiting for \(label)")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// A `BotMatch` plus the human session the shell would build on its
    /// exposed endpoint. `sleepFor` is a no-op so a countdown costs no time.
    static func matched() -> (bot: BotMatch, human: MatchSession) {
        let match = BotMatch(dictionary: AnyWordList(), sleepFor: { _ in })
        let human = MatchSession(
            transport: match.humanTransport,
            peerPlayerID: BotMatch.botPlayerID,
            dictionary: AnyWordList(),
            sleepFor: { _ in }
        )
        return (match, human)
    }

    /// Run the real election over the two ids. Asserting that one id string
    /// sorts before the other would pass while the election picked the bot.
    @Test("The host election names the human, not the bot")
    func humanIsHost() {
        let elected = HostPool.host(of: [BotMatch.humanPlayerID, BotMatch.botPlayerID])
        #expect(elected == BotMatch.humanPlayerID)
        #expect(elected != BotMatch.botPlayerID)
    }

    @Test("The bot's session is built on the far end of the human's link")
    func endpointsArePaired() {
        let match = BotMatch(dictionary: AnyWordList(), sleepFor: { _ in })
        defer { match.leave() }
        #expect(match.session.localPlayerID == BotMatch.botPlayerID)
        #expect(match.humanTransport.localPlayerID == BotMatch.humanPlayerID)
    }

    @Test("Starting from the human side deals the bot a full hand, sharing no tile")
    func openingDealReachesTheBot() async throws {
        let handSize = 7
        let (match, human) = Self.matched()
        defer { match.leave() }

        human.startMatch(seed: 11, startingHandSize: handSize, countdownSeconds: 0)
        try await Self.waitUntil("both hands dealt") {
            human.state.hand.count == handSize && match.session.state.hand.count == handSize
        }

        #expect(human.lastNote == nil)  // the human was host, so nothing was refused
        let botIDs = Set(match.session.state.hand.map(\.id))
        let humanIDs = Set(human.state.hand.map(\.id))
        #expect(botIDs.count == handSize)
        #expect(botIDs.isDisjoint(with: humanIDs))
        // Dealt, not owed: the opening hand lands in the rack, not behind Draw.
        #expect(match.session.pendingDrawTiles.isEmpty)
    }

    /// Nothing reaches the wire from the bot's end while it has no brain.
    @Test("The bot sends nothing of its own")
    func botIsSilent() async throws {
        let handSize = 3
        let (match, human) = Self.matched()
        human.startMatch(seed: 5, startingHandSize: handSize, countdownSeconds: 0)
        try await Self.waitUntil("bot dealt") { match.session.state.hand.count == handSize }

        // The human's session owns its own inbound stream, so the bot's traffic
        // is counted where it is observable: the human heard no draw request,
        // no word, no resignation — its match is untouched by the far end.
        #expect(human.winner == nil)
        #expect(human.isMatchOver == false)
        #expect(human.pendingDrawTiles.isEmpty)
        #expect(human.state.hand.count == handSize)
        match.leave()
    }

    @Test("After leave() the human's endpoint is disconnected and the bot's inbound stream has ended")
    func leaveTearsDownBothEnds() async throws {
        let match = BotMatch(dictionary: AnyWordList(), sleepFor: { _ in })
        // The bot session already owns `session.transport`'s inbound stream, so
        // the end of iteration is observed on a fresh pair driven the same way —
        // `leave()` finishes every continuation on both endpoints.
        match.leave()

        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await match.humanTransport.send(.drawRequest(player: BotMatch.humanPlayerID), delivery: .reliable)
        }

        // The bot's session pump iterates that stream; a finished stream ends
        // its loop, and the session reports the match gone.
        try await Self.waitUntil("bot session saw the match end") {
            match.session.presence(of: BotMatch.humanPlayerID) == .gone
        }
    }

    @Test("leave() twice is a no-op, not a trap")
    func leaveIsIdempotent() async throws {
        let (match, human) = Self.matched()
        human.startMatch(seed: 3, startingHandSize: 2, countdownSeconds: 0)
        try await Self.waitUntil("bot dealt") { match.session.state.hand.count == 2 }

        match.leave()
        match.leave()

        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await match.humanTransport.send(.poolExhausted, delivery: .reliable)
        }
    }

    /// Bot inbound iteration ends when the link goes. Proven on a bare
    /// `LocalMatchLink` pair rather than on `match.session`'s stream, which
    /// `MatchSession` is already the single consumer of.
    @Test("A link torn down by leave() finishes the far end's inbound stream")
    func inboundIterationEnds() async throws {
        let (human, bot) = LocalMatchLink.pair(BotMatch.humanPlayerID, BotMatch.botPlayerID)
        bot.leave()
        var received = 0
        for await _ in human.inboundMessages { received += 1 }
        #expect(received == 0)
    }
}
