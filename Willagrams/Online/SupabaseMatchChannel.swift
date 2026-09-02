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

    private let channel: RealtimeChannelV2

    /// `RealtimeSubscription` cancels its callback when the token deallocates,
    /// so the tokens have to outlive registration.
    private var subscriptions: [RealtimeSubscription] = []

    init(realtime: RealtimeClientV2, matchID: UUID, localPlayerID: PlayerID) {
        channel = realtime.channel("match:\(matchID.uuidString.lowercased())") { config in
            // No echo. The transport also filters on `sender`, so this is the
            // first of two doors, not the only one.
            config.broadcast.receiveOwnBroadcasts = false
            config.presence.key = localPlayerID.rawValue
        }
    }

    func onWire(_ handler: @escaping @Sendable (WireEnvelope) -> Void) {
        subscriptions.append(
            channel.onBroadcast(event: Self.wireEvent) { payload in
                guard let frame = try? payload.decode(as: Frame.self),
                    let envelope = Self.envelope(from: frame)
                else { return }
                handler(envelope)
            })
    }

    func onPresence(_ handler: @escaping @Sendable ([PlayerID], [PlayerID]) -> Void) {
        subscriptions.append(
            channel.onPresenceChange { action in
                handler(
                    action.joins.keys.map { PlayerID(rawValue: $0) },
                    action.leaves.keys.map { PlayerID(rawValue: $0) })
            })
    }

    func subscribe(as player: PlayerID) async throws {
        try await channel.subscribeWithError()
        await channel.track(state: ["player": .string(player.rawValue)])
    }

    /// The `some Codable` overload deliberately: the `JSONObject` one is
    /// `@MainActor`, and nothing in this adapter may hop to the main actor.
    func send(_ envelope: WireEnvelope) async throws {
        try await channel.broadcast(event: Self.wireEvent, message: Self.payload(for: envelope))
    }

    func leave() {
        let channel = channel
        Task { await channel.unsubscribe() }
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
