//
//  SupabaseMatchChannel.swift
//  Willagrams
//
//  The one place `RealtimeMatchTransport` touches the Realtime SDK. Everything
//  above this file speaks `MatchChannel`, so the stream contract is provable
//  without a project.
//

import Foundation
import Realtime
import WillagramsRules

/// One `RealtimeChannelV2` on topic `match:<match uuid>`.
///
/// Presence key is the player id, so `joins`/`leaves` are already keyed by the
/// `PlayerID` the transport wants — no state decoding on the hot path.
final class SupabaseMatchChannel: MatchChannel, @unchecked Sendable {

    /// The broadcast event every wire message travels as.
    static let wireEvent = "wire"

    private let realtime: RealtimeClientV2
    private let channel: RealtimeChannelV2
    private let topic: String
    private let retrack = RetrackGate()

    private let lock = NSLock()

    /// `RealtimeSubscription` cancels its callback when the token deallocates,
    /// so the tokens have to outlive registration.
    private var subscriptions: [RealtimeSubscription] = []

    static func topic(for matchID: UUID) -> String {
        "match:\(matchID.uuidString.lowercased())"
    }

    init(realtime: RealtimeClientV2, matchID: UUID, localPlayerID: PlayerID) {
        self.realtime = realtime
        topic = Self.topic(for: matchID)
        channel = realtime.channel(topic) { config in
            // No echo. The transport also filters on `sender`, so this is the
            // first of two doors, not the only one.
            config.broadcast.receiveOwnBroadcasts = false
            config.presence.key = localPlayerID.rawValue
        }
    }

    func onWire(_ handler: @escaping @Sendable (WireEnvelope) -> Void) {
        retain(
            channel.onBroadcast(event: Self.wireEvent) { payload in
                guard let frame = try? payload.decode(as: Frame.self),
                    let envelope = Self.envelope(from: frame)
                else { return }
                handler(envelope)
            })
    }

    func onPresence(_ handler: @escaping @Sendable ([PlayerID], [PlayerID]) -> Void) {
        retain(
            channel.onPresenceChange { action in
                handler(
                    action.joins.keys.map { PlayerID(rawValue: $0) },
                    action.leaves.keys.map { PlayerID(rawValue: $0) })
            })
    }

    func subscribe(as player: PlayerID) async throws {
        try await channel.subscribeWithError()
        retrack.track(player)
        await channel.track(state: Self.presence(player))
        // 2.55.1 rejoins without presence after a socket drop
        // (`ChannelStateManager.resetForReconnect` clears the join and never
        // re-sends `track`), so this endpoint would go permanently absent to
        // its peer. Track again on every *return* to `.subscribed`.
        let channel = channel
        let retrack = retrack
        retain(
            channel.onStatusChange { status in
                let subscribed: Bool
                if case .subscribed = status { subscribed = true } else { subscribed = false }
                guard let player = retrack.player(subscribed: subscribed) else { return }
                Task { await channel.track(state: Self.presence(player)) }
            })
    }

    private func retain(_ subscription: RealtimeSubscription) {
        lock.withLock { subscriptions.append(subscription) }
    }

    static func presence(_ player: PlayerID) -> JSONObject {
        ["player": .string(player.rawValue)]
    }

    /// The `some Codable` overload deliberately: the `JSONObject` one is
    /// `@MainActor`, and nothing in this adapter may hop to the main actor.
    func send(_ envelope: WireEnvelope) async throws {
        try await channel.broadcast(event: Self.wireEvent, message: Self.payload(for: envelope))
    }

    /// `removeChannel`, not `unsubscribe`: unsubscribing leaves the channel in
    /// `RealtimeClientV2.channels`, so every match would leak an entry and the
    /// socket would never tear down after the last one. `removeChannel`
    /// unsubscribes first, clears the map, and is what triggers
    /// disconnect-on-empty.
    func leave() {
        // Dropping the tokens cancels their callbacks, so nothing — the
        // re-track least of all — can fire after this returns.
        retrack.close()
        lock.withLock { subscriptions.removeAll() }
        let realtime = realtime
        let channel = channel
        Self.removals.begin(topic) {
            // `removeChannel` only unsubscribes when the status is exactly
            // `.subscribed`, so a teardown mid-join would drop the channel from
            // the client with the join still in flight.
            await channel.unsubscribe()
            await realtime.removeChannel(channel)
        }
    }

    /// Teardown is async but ``leave()`` is not, so re-entering the same match
    /// races a still-running removal: `RealtimeClientV2.channel(topic:)` hands
    /// back the live instance for a topic it still holds, and the pending
    /// `removeChannel` would then clear it out from under the new transport.
    private static let removals = PendingRemovals()

    /// Waits out any teardown still running for `matchID`'s topic.
    static func awaitPendingRemoval(matchID: UUID) async {
        await removals.wait(topic(for: matchID))
    }

    // MARK: - Framing

    /// Base64 rather than a `Data` field: the payload rides inside a JSON
    /// object either way, and spelling the encoding out here keeps the frame
    /// independent of whatever `dataEncodingStrategy` the SDK's encoder has.
    /// Both keys are single lowercase words, so no key strategy can rename them.
    struct Frame: Codable, Sendable, Equatable {
        let sender: String
        let payload: String
    }

    static func payload(for envelope: WireEnvelope) -> Frame {
        Frame(
            sender: envelope.sender.rawValue,
            payload: envelope.payload.base64EncodedString())
    }

    /// `nil` for anything that is not a frame this build wrote. A peer can put
    /// arbitrary JSON on the channel; that is a dropped message, not a crash.
    static func envelope(from frame: Frame) -> WireEnvelope? {
        guard let data = Data(base64Encoded: frame.payload) else { return nil }
        return WireEnvelope(sender: PlayerID(rawValue: frame.sender), payload: data)
    }
}

/// Decides whether a channel status change is a *return* to `.subscribed`, and
/// with which player.
///
/// The first `.subscribed` is deliberately not a rejoin: `onStatusChange`
/// replays the current status on registration, and ``SupabaseMatchChannel/subscribe(as:)``
/// has already tracked explicitly by then. Kept SDK-free (a `Bool`, not a
/// `RealtimeChannelStatus`) so the decision is testable without the network.
final class RetrackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var player: PlayerID?
    private var rejoined = false
    private var closed = false

    func track(_ player: PlayerID) { lock.withLock { self.player = player } }

    /// One-way. Nothing re-tracks after the channel has been left.
    func close() { lock.withLock { closed = true } }

    /// The player to re-track, or `nil` if this status change is not a rejoin.
    func player(subscribed: Bool) -> PlayerID? {
        lock.withLock {
            guard !closed else { return nil }
            guard subscribed else {
                rejoined = true
                return nil
            }
            guard rejoined else { return nil }
            rejoined = false
            return player
        }
    }
}

/// Per-topic teardown tasks, so a new channel on a topic can wait out the old
/// one. Each entry clears itself when it finishes; ``wait(_:)`` clears it too,
/// so the map holds only teardowns still in flight.
final class PendingRemovals: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    func begin(_ topic: String, _ work: @escaping @Sendable () async -> Void) {
        lock.withLock {
            let previous = tasks[topic]?.task
            let token = UUID()
            tasks[topic] = (
                token,
                Task { [self] in
                    await previous?.value
                    await work()
                    lock.withLock { if tasks[topic]?.token == token { tasks[topic] = nil } }
                }
            )
        }
    }

    func wait(_ topic: String) async {
        guard let entry = lock.withLock({ tasks[topic] }) else { return }
        await entry.task.value
        lock.withLock { if tasks[topic]?.token == entry.token { tasks[topic] = nil } }
    }
}
