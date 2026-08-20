import Foundation
import Testing
import WillagramsRules
import Match
import Bot

/// The shipping in-memory link, asserted against the semantics
/// `MatchTransport` documents on itself: unbounded buffering ahead of any
/// consumer, a `send` that never suspends, and both streams on both endpoints
/// finishing once either side leaves.
///
/// Every stream here is drained only after a `leave()`, so a broken
/// implementation fails the suite rather than hanging it.
@Suite("Local match link")
struct LocalMatchLinkTests {

    private static let alice = PlayerID(rawValue: "alice")
    private static let bob = PlayerID(rawValue: "bob")

    private static func newPair() -> (first: LocalMatchLink, second: LocalMatchLink) {
        LocalMatchLink.pair(alice, bob)
    }

    private static func drain<T>(_ stream: AsyncStream<T>) async -> [T] {
        var collected: [T] = []
        for await element in stream { collected.append(element) }
        return collected
    }

    @Test("Both endpoints start connected, each naming the other")
    func pairStartsConnected() async {
        let (a, b) = Self.newPair()
        a.leave()
        #expect(await Self.drain(a.peerConnectionStates) == [.connected(Self.bob)])
        #expect(await Self.drain(b.peerConnectionStates) == [.connected(Self.alice), .disconnected(Self.alice)])
    }

    @Test("Messages cross in both directions")
    func exchangesBothWays() async throws {
        let (a, b) = Self.newPair()
        try await a.send(.drawRequest(player: Self.alice), delivery: .reliable)
        try await b.send(.drawRequest(player: Self.bob), delivery: .lossy)
        a.leave()

        #expect(await Self.drain(b.inboundMessages) == [.drawRequest(player: Self.alice)])
        #expect(await Self.drain(a.inboundMessages) == [.drawRequest(player: Self.bob)])
    }

    /// The buffering promise: nothing sent before a consumer exists is lost, and
    /// order is production order, not arrival-of-the-reader order.
    @Test("Messages sent before any consumer iterates are all delivered, in order")
    func buffersAheadOfTheFirstConsumer() async throws {
        let (a, b) = Self.newPair()
        let sent: [MatchMessage] = [
            .drawRequest(player: Self.alice),
            .poolExhausted,
            .rejected(reason: .notYourTurn),
            .resign(player: Self.alice),
        ]
        for message in sent {
            try await a.send(message, delivery: .reliable)
        }
        a.leave()

        #expect(await Self.drain(b.inboundMessages) == sent)
    }

    /// A second access must continue the *same* subscription, not restart a
    /// fresh one — one stream per endpoint, not one per access.
    @Test("Every access returns the same stream, not a new subscription")
    func streamIsSingleSubscription() async throws {
        let (a, b) = Self.newPair()
        try await a.send(.poolExhausted, delivery: .reliable)
        try await a.send(.resign(player: Self.alice), delivery: .reliable)
        a.leave()

        var first: MatchMessage?
        for await message in b.inboundMessages {
            first = message
            break
        }
        #expect(first == .poolExhausted)
        // The remainder, read through a separate access to the property.
        #expect(await Self.drain(b.inboundMessages) == [.resign(player: Self.alice)])
    }

    @Test("leave() finishes both streams on both endpoints, after buffered elements drain")
    func leaveFinishesEveryStream() async throws {
        let (a, b) = Self.newPair()
        try await a.send(.poolExhausted, delivery: .reliable)
        try await b.send(.drawRequest(player: Self.bob), delivery: .reliable)
        b.leave()

        // Each of these four loops ends rather than hanging, and the elements
        // buffered before `leave()` still arrive.
        #expect(await Self.drain(a.inboundMessages) == [.drawRequest(player: Self.bob)])
        #expect(await Self.drain(b.inboundMessages) == [.poolExhausted])
        #expect(await Self.drain(a.peerConnectionStates) == [.connected(Self.bob), .disconnected(Self.bob)])
        #expect(await Self.drain(b.peerConnectionStates) == [.connected(Self.alice)])
    }

    @Test("The surviving endpoint is told who left")
    func survivorLearnsWhoLeft() async {
        let (a, b) = Self.newPair()
        a.leave()
        #expect(await Self.drain(b.peerConnectionStates).last == .disconnected(Self.alice))
    }

    @Test("A send after either endpoint leaves throws peerDisconnected")
    func sendAfterLeaveThrows() async throws {
        let (a, b) = Self.newPair()
        a.leave()
        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await a.send(.poolExhausted, delivery: .reliable)
        }
        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await b.send(.poolExhausted, delivery: .reliable)
        }
    }

    @Test("Leaving twice is harmless")
    func doubleLeaveIsHarmless() async {
        let (a, b) = Self.newPair()
        a.leave()
        a.leave()
        #expect(await Self.drain(b.peerConnectionStates) == [.connected(Self.alice), .disconnected(Self.alice)])
    }

    /// `send` hands off and returns; it never waits for a reader. A thousand
    /// sends with nobody iterating complete, and all thousand survive.
    @Test("send never suspends on an absent reader")
    func sendDoesNotApplyBackpressure() async throws {
        let (a, b) = Self.newPair()
        for _ in 0..<1_000 {
            try await a.send(.poolExhausted, delivery: .reliable)
        }
        a.leave()
        #expect(await Self.drain(b.inboundMessages).count == 1_000)
    }

    /// A live consumer already parked on the stream gets elements as they are
    /// produced, not only once the sender leaves.
    @Test("A consumer already iterating receives a later send")
    func deliversToAWaitingConsumer() async throws {
        let (a, b) = Self.newPair()
        async let received: [MatchMessage] = Self.drain(b.inboundMessages)
        try await a.send(.drawRequest(player: Self.alice), delivery: .reliable)
        a.leave()
        #expect(await received == [.drawRequest(player: Self.alice)])
    }
}
