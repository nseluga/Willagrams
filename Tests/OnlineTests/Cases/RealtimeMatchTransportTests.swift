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
import Realtime
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

/// Order of completion, from tasks that finish on whatever thread they like.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func record(_ entry: String) { lock.withLock { seen.append(entry) } }
    var entries: [String] { lock.withLock { seen } }
}

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

    /// Proves the end state only: after a refused subscribe the channel is torn
    /// down exactly once. It does *not* pin down which path got there —
    /// `connect`'s catch and `deinit` are two routes to the same `leave()`, and
    /// ARC releases the local transport deterministically when `connect`
    /// throws, so removing either one alone keeps this green. Removing both is
    /// red, which is the property that actually matters to a caller.
    @Test("A refused subscribe does not leave the channel joined")
    func refusedSubscribeLeavesNothingJoined() async throws {
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

    /// The transport's window has to outlive `MatchSession`'s, or the session's
    /// reconnect path is dead code over this transport: the streams would
    /// finish, and `peerReturned` would never be reached. Coupled by
    /// convention — this is the guard that fails if either number moves.
    @Test("The default grace window covers the session's reconnect window")
    @MainActor
    func defaultPeerGraceCoversTheSessionWindow() {
        #expect(
            RealtimeMatchTransport.defaultPeerGrace
                >= .seconds(MatchSession.reconnectGraceSeconds))
    }

    /// A second leave restarts the clock rather than inheriting the first
    /// leave's deadline. Windows are short so the whole sequence — two windows,
    /// a re-join between them — really elapses inside the case.
    @Test("A leave inside an open grace window re-arms it instead of closing early")
    func aSecondLeaveRestartsTheGraceWindow() async throws {
        let bus = StubBus()
        let hostChannel = bus.channel()
        let host = try await connect(hostID, channel: hostChannel, grace: .milliseconds(200))
        let guestChannel = bus.channel()
        let guest = try await connect(guestID, channel: guestChannel)
        defer { _ = guest }  // A discarded transport deinits, and deinit leaves.

        guestChannel.leave()  // First window opens here.
        try await Task.sleep(for: .milliseconds(50))
        bus.join(guestChannel, as: guestID)
        try await Task.sleep(for: .milliseconds(50))
        guestChannel.leave()  // Second window opens here; the first must not survive.

        // Past the *first* leave's deadline but inside the second's. A stale
        // timer has fired by now, and the match would already be over.
        try await Task.sleep(for: .milliseconds(150))
        try await host.send(.poolExhausted, delivery: .reliable)

        // And the second window still closes the match on its own schedule.
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: MatchTransportError.self) {
            try await host.send(.poolExhausted, delivery: .reliable)
        }
        let states = try await drain(host.peerConnectionStates)
        #expect(
            states == [
                .connected(guestID), .disconnected(guestID), .connected(guestID),
                .disconnected(guestID),
            ])
    }

    /// 2.55.1 rejoins a channel without re-sending presence, so a socket blip
    /// would make this endpoint permanently absent to its peer. The gate is the
    /// decision that fixes it; it is kept SDK-free so it can be driven here
    /// without a project.
    @Test("Presence is re-tracked on a rejoin, but not on the first subscribe or after leaving")
    func rejoiningRetracksPresence() {
        let gate = RetrackGate()
        gate.track(hostID)

        // The registration replay of the status we are already in.
        #expect(gate.player(subscribed: true) == nil)

        // A drop and a rejoin.
        #expect(gate.player(subscribed: false) == nil)
        #expect(gate.player(subscribed: true) == hostID)

        // A repeat of `.subscribed` without an intervening drop is not a rejoin.
        #expect(gate.player(subscribed: true) == nil)

        // Nothing re-tracks a channel that has been left.
        gate.close()
        #expect(gate.player(subscribed: false) == nil)
        #expect(gate.player(subscribed: true) == nil)
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
        // so every match leaks an entry and the socket never tears down. But
        // `removeChannel` only unsubscribes when the status is exactly
        // `.subscribed`, so an explicit unsubscribe has to come first or a
        // teardown mid-join drops the channel with its join still in flight.
        let unsubscribe = source.range(of: "await channel.unsubscribe()")
        let remove = source.range(of: "await realtime.removeChannel(channel)")
        #expect(unsubscribe != nil)
        #expect(remove != nil)
        if let unsubscribe, let remove { #expect(unsubscribe.upperBound < remove.lowerBound) }

        // The SDK rejoins without presence after a socket drop, so the endpoint
        // has to track again on a return to `.subscribed`. Invisible offline
        // for the same reason: the stub has no socket to drop.
        #expect(source.contains("channel.onStatusChange"))
        #expect(source.contains("retrack.player(subscribed: subscribed)"))

        // ...and the gate has to be closed *by* `leave()`, or a re-track can
        // still fire on a channel the match is done with.
        #expect(leaveBody(of: source).contains("retrack.close()"))
    }

    /// The body of the file's `leave()`. Text, not behaviour — a leaked timer
    /// and a late re-track are both invisible to the stub, which has no socket
    /// to drop and no clock to leak.
    private func leaveBody(of source: String) -> String {
        guard let start = source.range(of: "func leave() {"),
            let end = source.range(of: "\n    }", range: start.upperBound ..< source.endIndex)
        else { return "" }
        return String(source[start.upperBound ..< end.lowerBound])
    }

    @Test("leave() cancels the grace timer rather than leaving a 35-second task running")
    func leaveCancelsTheGraceTimer() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Cases
                .deletingLastPathComponent()  // OnlineTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repo root
                .appendingPathComponent("Willagrams/Online/RealtimeMatchTransport.swift"),
            encoding: .utf8)
        #expect(leaveBody(of: source).contains("peers.cancelGrace()"))
    }

    /// Teardown is async and `leave()` is not, so a new transport on the same
    /// match has to wait the old one's removal out. Driveable offline: the
    /// bookkeeping is a dictionary of tasks, not a socket.
    @Test("A pending removal is awaited, and a second one queues behind the first")
    func pendingRemovalsSequenceByTopic() async throws {
        let removals = PendingRemovals()
        let order = Recorder()

        await removals.wait("match:absent")  // Nothing pending: returns at once.

        removals.begin("match:a") {
            try? await Task.sleep(for: .milliseconds(50))
            order.record("first")
        }
        removals.begin("match:a") { order.record("second") }

        // A different topic is independent, so it gets its own recorder rather
        // than racing into this one's ordering.
        let other = Recorder()
        removals.begin("match:b") { other.record("other") }

        await removals.wait("match:a")
        #expect(order.entries == ["first", "second"])

        // The entry cleared itself, so waiting again is not a second wait on a
        // task that already ran.
        await removals.wait("match:a")
        await removals.wait("match:b")
        #expect(order.entries == ["first", "second"])
        #expect(other.entries == ["other"])
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

    @Test("A broadcast message carries the frame under `payload`, not at the top level")
    func broadcastMessageShape() throws {
        let envelope = WireEnvelope(sender: hostID, payload: Data([0x01, 0x02]))
        let frame = SupabaseMatchChannel.payload(for: envelope)
        // Exactly what the SDK hands `onBroadcast` — proven against the live
        // project on 2026-09-02, when decoding the top level dropped every message.
        let message: JSONObject = [
            "type": "broadcast", "event": "wire",
            "payload": ["sender": .string(frame.sender), "payload": .string(frame.payload)],
        ]
        let decoded = try #require(SupabaseMatchChannel.envelope(fromBroadcast: message))
        #expect(decoded.sender == envelope.sender)
        #expect(decoded.payload == envelope.payload)
        #expect(
            SupabaseMatchChannel.envelope(
                fromBroadcast: ["sender": .string(frame.sender), "payload": .string(frame.payload)])
                == nil)
    }
}
