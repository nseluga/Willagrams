//
//  RealtimeMatchTransportTests.swift
//
//  The `MatchTransport` stream contract, proved without a project.
//
//  Criteria 2, 3 and 4 are statements about this adapter's own bookkeeping —
//  buffer-and-replay, finish-on-leave, lossy-equals-reliable, no-backpressure —
//  so they are driven through a stub `MatchChannel` rather than the network.
//  Criterion 1 (two real clients over the live project) is irreducibly live and
//  lives in `RealtimeMatchTransportLiveTests.swift`.
//

import Foundation
import Testing
import WillagramsRules

@testable import Online

// MARK: - Stub channel

/// An in-memory stand-in for one Supabase Realtime channel, shared by every
/// endpoint on the same `StubBus`. It reproduces the two channel behaviours the
/// transport is built on: broadcast fan-out and presence join/leave.
final class StubBus: @unchecked Sendable {
    private let lock = NSLock()
    private var members: [(player: PlayerID, channel: StubChannel)] = []

    /// Set to simulate a `self: false` regression: the bus echoes broadcasts
    /// back to their sender, which the transport must still not deliver.
    let echoesOwnBroadcasts: Bool

    init(echoesOwnBroadcasts: Bool = false) {
        self.echoesOwnBroadcasts = echoesOwnBroadcasts
    }

    func channel() -> StubChannel { StubChannel(bus: self) }

    func join(_ channel: StubChannel, as player: PlayerID) {
        let (existing, all) = lock.withLock { () -> ([PlayerID], [StubChannel]) in
            let existing = members.map(\.player)
            members.append((player, channel))
            return (existing, members.map(\.channel))
        }
        // The newcomer's own presence sync carries everyone already here; the
        // incumbents see one join. That is the shape Realtime delivers.
        channel.deliverPresence(joined: existing + [player], left: [])
        for other in all where other !== channel {
            other.deliverPresence(joined: [player], left: [])
        }
    }

    func leave(_ channel: StubChannel) {
        let (player, remaining) = lock.withLock { () -> (PlayerID?, [StubChannel]) in
            guard let index = members.firstIndex(where: { $0.channel === channel }) else {
                return (nil, [])
            }
            let player = members.remove(at: index).player
            return (player, members.map(\.channel))
        }
        guard let player else { return }
        for other in remaining { other.deliverPresence(joined: [], left: [player]) }
    }

    func broadcast(_ envelope: WireEnvelope, from channel: StubChannel) {
        let all = lock.withLock { members.map(\.channel) }
        for other in all where echoesOwnBroadcasts || other !== channel {
            other.deliverWire(envelope)
        }
    }
}

final class StubChannel: MatchChannel, @unchecked Sendable {
    private let lock = NSLock()
    private let bus: StubBus
    private var wire: (@Sendable (WireEnvelope) -> Void)?
    private var presence: (@Sendable ([PlayerID], [PlayerID]) -> Void)?

    /// The guardrail: one subscribe per channel per transport. A second one is
    /// a bug, so it is counted rather than tolerated.
    private(set) var subscribeCount = 0
    private(set) var leaveCount = 0
    private(set) var sentEnvelopes: [WireEnvelope] = []

    /// Set to make `subscribe` throw, standing in for a channel the server
    /// refuses or that times out mid-join.
    var subscribeFailure: (any Error)?

    init(bus: StubBus) { self.bus = bus }

    func onWire(_ handler: @escaping @Sendable (WireEnvelope) -> Void) {
        lock.withLock { wire = handler }
    }

    func onPresence(_ handler: @escaping @Sendable ([PlayerID], [PlayerID]) -> Void) {
        lock.withLock { presence = handler }
    }

    func subscribe(as player: PlayerID) async throws {
        lock.withLock { subscribeCount += 1 }
        if let subscribeFailure { throw subscribeFailure }
        bus.join(self, as: player)
    }

    func send(_ envelope: WireEnvelope) async throws {
        lock.withLock { sentEnvelopes.append(envelope) }
        bus.broadcast(envelope, from: self)
    }

    func leave() {
        lock.withLock { leaveCount += 1 }
        bus.leave(self)
    }

    func deliverWire(_ envelope: WireEnvelope) {
        lock.withLock { wire }?(envelope)
    }

    func deliverPresence(joined: [PlayerID], left: [PlayerID]) {
        lock.withLock { presence }?(joined, left)
    }

    var subscribes: Int { lock.withLock { subscribeCount } }
    var leaves: Int { lock.withLock { leaveCount } }
    var sent: [WireEnvelope] { lock.withLock { sentEnvelopes } }
}

// MARK: - Fixtures

private let hostID = PlayerID(rawValue: "host")
private let guestID = PlayerID(rawValue: "guest")

/// Every offline case runs with a zero grace window, so the last peer leaving
/// finishes the streams inline — no added latency, and criterion 3 still proves
/// finish-on-last-peer-leave exactly as written.
private func connect(
    _ player: PlayerID,
    channel: StubChannel,
    grace: Duration = .zero
) async throws -> RealtimeMatchTransport {
    try await RealtimeMatchTransport.connect(
        localPlayerID: player, channel: channel, peerGrace: grace)
}

/// Twenty distinguishable messages, so "in order" and "not twice" are both
/// observable from the received sequence alone.
private func script(_ count: Int) -> [MatchMessage] {
    (0 ..< count).map { .drawRequest(player: PlayerID(rawValue: "p\($0)")) }
}

/// Drains a stream to completion under a deadline: a message that never
/// arrives, or a stream that never finishes, fails here rather than hanging
/// the whole run.
private func drain<T: Sendable>(
    _ stream: AsyncStream<T>,
    seconds: Double = 5
) async throws -> [T] {
    try await withThrowingTaskGroup(of: [T].self) { group in
        group.addTask {
            var collected: [T] = []
            for await element in stream { collected.append(element) }
            return collected
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw StreamTimedOut()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private struct StreamTimedOut: Error {}

@Suite("Realtime transport, stream contract")
struct RealtimeMatchTransportTests {

    // MARK: - Same stream on every access

    @Test("Each stream property returns the same stream object on every access")
    func streamsAreSingleSubscription() async throws {
        let bus = StubBus()
        let host = try await connect(hostID, channel: bus.channel())

        // `AsyncStream` is a struct, so identity is the shared storage behind
        // it — the same continuation, not a fresh subscription per access.
        var first = host.inboundMessages.makeAsyncIterator()
        let second = host.inboundMessages

        let guest = try await connect(guestID, channel: bus.channel())
        try await guest.send(.poolExhausted, delivery: .reliable)

        #expect(await first.next() == .poolExhausted)
        // The element went to the first iterator, so the second access sees the
        // rest of that same stream — not a replay.
        guest.leave()
        let rest = try await drain(second)
        #expect(rest.isEmpty)
    }

    // MARK: - Criterion 2: buffer and replay

    @Test("A consumer that starts after ten sends still receives all twenty, in order")
    func lateConsumerReceivesEverything() async throws {
        let bus = StubBus()
        let host = try await connect(hostID, channel: bus.channel())
        let guest = try await connect(guestID, channel: bus.channel())

        let sent = script(20)
        for message in sent.prefix(10) {
            try await guest.send(message, delivery: .reliable)
        }

        // Only now does anyone start reading. The first ten are already in the
        // buffer; the last ten arrive while the consumer is running.
        async let received = drain(host.inboundMessages)
        for message in sent.suffix(10) {
            try await guest.send(message, delivery: .reliable)
        }
        guest.leave()

        let got = try await received
        #expect(got == sent)
    }

    @Test("An echoing channel still delivers nothing back to the sender")
    func ownBroadcastsAreDroppedEvenWhenEchoed() async throws {
        // `self: false` regressed to `self: true`. The sender-id filter is the
        // second door, and it has to hold on its own.
        let bus = StubBus(echoesOwnBroadcasts: true)
        let host = try await connect(hostID, channel: bus.channel())
        let guest = try await connect(guestID, channel: bus.channel())

        for message in script(5) { try await host.send(message, delivery: .reliable) }
        try await guest.send(.poolExhausted, delivery: .reliable)
        guest.leave()

        // Exactly the peer's one message: none of the host's five echoes, and
        // the peer's message once rather than twice.
        let received = try await drain(host.inboundMessages)
        #expect(received == [.poolExhausted])
    }

    // MARK: - Criterion 3: termination

    @Test("The peer leaving delivers .disconnected and then finishes both streams")
    func peerLeavingEndsTheSurvivorsStreams() async throws {
        let bus = StubBus()
        let host = try await connect(hostID, channel: bus.channel())
        let guest = try await connect(guestID, channel: bus.channel())

        try await guest.send(.poolExhausted, delivery: .reliable)
        guest.leave()

        let states = try await drain(host.peerConnectionStates)
        #expect(states == [.connected(guestID), .disconnected(guestID)])
        // Buffered before the leave, still delivered after it.
        let received = try await drain(host.inboundMessages)
        #expect(received == [.poolExhausted])
    }

    @Test("The caller's own two streams finish on leave()")
    func leaveEndsTheCallersOwnStreams() async throws {
        let bus = StubBus()
        let host = try await connect(hostID, channel: bus.channel())
        let guest = try await connect(guestID, channel: bus.channel())
        defer { _ = guest }  // A discarded transport deinits, and deinit leaves.

        host.leave()
        host.leave()  // Calling it more than once is harmless.

        let received = try await drain(host.inboundMessages)
        #expect(received.isEmpty)
        let states = try await drain(host.peerConnectionStates)
        #expect(states == [.connected(guestID)])
        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await host.send(.poolExhausted, delivery: .reliable)
        }
    }

    // MARK: - Criterion 4: delivery modes and empty matches

    @Test("A send with no peer present neither throws nor blocks, and lossy sends like reliable")
    func sendsWithoutAPeerAndInBothModes() async throws {
        let bus = StubBus()
        let channel = bus.channel()
        let host = try await connect(hostID, channel: channel)

        // Nobody else is on the channel yet. Both of these return.
        try await host.send(.poolExhausted, delivery: .reliable)
        try await host.send(.poolExhausted, delivery: .lossy)
        #expect(channel.sent.count == 2)
        #expect(channel.subscribes == 1)

        let guest = try await connect(guestID, channel: bus.channel())

        let reliable = MatchMessage.drawRequest(player: hostID)
        let lossy = MatchMessage.resign(player: hostID)
        try await host.send(reliable, delivery: .reliable)
        try await host.send(lossy, delivery: .lossy)
        host.leave()

        // `.lossy` is sent exactly as `.reliable` is, so both land.
        let received = try await drain(guest.inboundMessages)
        #expect(received == [reliable, lossy])
    }

    // MARK: - Fault tolerance

    @Test("A peer that re-joins inside the grace window does not end the match")
    func transientPeerDropDoesNotEndTheMatch() async throws {
        let bus = StubBus()
        let hostChannel = bus.channel()
        // Short enough that the window really elapses inside the case: a timer
        // that fires anyway is then red rather than merely untested.
        let host = try await connect(hostID, channel: hostChannel, grace: .milliseconds(100))
        let guestChannel = bus.channel()
        let guest = try await connect(guestID, channel: guestChannel)
        defer { _ = guest }  // A discarded transport deinits, and deinit leaves.

        // A transient socket drop reaches the host as a real presence leave.
        guestChannel.leave()
        // ...and the peer is back well inside the window.
        bus.join(guestChannel, as: guestID)

        // The match is still live: sending still works rather than throwing.
        try await host.send(.poolExhausted, delivery: .reliable)

        // Past the window. A timer that ignored the re-join has fired by now.
        try await Task.sleep(for: .milliseconds(300))
        try await host.send(.poolExhausted, delivery: .reliable)
        #expect(hostChannel.sent.count == 2)

        // And the host was told about the round trip rather than silence.
        host.leave()
        let states = try await drain(host.peerConnectionStates)
        #expect(states == [.connected(guestID), .disconnected(guestID), .connected(guestID)])
    }

    @Test("A subscribe that throws tears the channel down instead of leaving a caller hanging")
    func failedSubscribeCleansUp() async throws {
        struct Refused: Error {}
        let bus = StubBus()
        let channel = bus.channel()
        channel.subscribeFailure = Refused()

        await #expect(throws: Refused.self) {
            _ = try await connect(hostID, channel: channel)
        }

        // `leave()` is the single path that both tears the channel down and
        // finishes the two streams, so seeing it run is seeing both happen.
        #expect(channel.leaves == 1)
    }

    /// Invisible to any offline behavioural test — the stub channel has no
    /// client to leak an entry into — so it is guarded at the source, the way
    /// this lane already guards the wiring of the protocol methods.
    @Test("The channel is removed from the client, not merely unsubscribed")
    func leavingRemovesTheChannelFromTheClient() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Cases
                .deletingLastPathComponent()  // OnlineTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repo root
                .appendingPathComponent("Willagrams/Online/SupabaseMatchChannel.swift"),
            encoding: .utf8)

        // `unsubscribe` alone leaves the channel in `RealtimeClientV2.channels`,
        // so every match leaks an entry and the socket never tears down.
        #expect(source.contains("removeChannel(channel)"))
        #expect(!source.contains("await channel.unsubscribe()"))
    }

    // MARK: - Framing

    @Test("A frame round-trips, and junk on the channel decodes to nil rather than trapping")
    func framingRoundTrips() throws {
        let envelope = WireEnvelope(sender: hostID, payload: Data([0x00, 0xFF, 0x10]))
        let frame = SupabaseMatchChannel.payload(for: envelope)
        #expect(frame.sender == "host")

        let decoded = try #require(SupabaseMatchChannel.envelope(from: frame))
        #expect(decoded.sender == hostID)
        #expect(decoded.payload == envelope.payload)

        // A peer can put anything on the channel. Junk is a dropped message.
        #expect(
            SupabaseMatchChannel.envelope(
                from: .init(sender: "host", payload: "not base64!!")) == nil)
    }
}
