//
//  SupabaseMatchInviteChannel.swift
//  Willagrams
//
//  The one place the invite seam touches the Realtime SDK, modelled on
//  `SupabaseMatchChannel`. Everything above it speaks `MatchInviteChannel`, so
//  the banner rules are provable with no project — and this file stays out of
//  `Tests/ShellTests`, which compiles `Willagrams/Online` by name and has no
//  SDK dependency.
//
//  No migration and no table: an invite is a broadcast on the recipient's own
//  topic and nothing else is written anywhere.
//

import Foundation
import Realtime

/// One `RealtimeChannelV2` on topic `invites:<user uuid>`.
///
/// Broadcast only — no presence, no postgres changes. The topic is named for
/// the *recipient*, so sending is "open theirs, say it, leave" and listening is
/// "stay on mine".
final class SupabaseMatchInviteChannel: MatchInviteChannel, @unchecked Sendable {

    /// The broadcast event every invite travels as.
    static let inviteEvent = "invite"

    static func topic(for userID: UUID) -> String {
        "invites:\(userID.uuidString.lowercased())"
    }

    private let realtime: RealtimeClientV2
    private let channel: RealtimeChannelV2

    private let lock = NSLock()

    /// `RealtimeSubscription` cancels its callback when the token deallocates,
    /// so the tokens have to outlive registration.
    private var subscriptions: [RealtimeSubscription] = []

    let invites: AsyncStream<MatchInvite>

    /// Unbounded, so nothing is discarded for want of a reader and the SDK's
    /// synchronous broadcast callback never suspends.
    private let continuation: AsyncStream<MatchInvite>.Continuation

    init(realtime: RealtimeClientV2, userID: UUID) {
        self.realtime = realtime
        channel = realtime.channel(Self.topic(for: userID)) { config in
            // Nobody invites themselves, and an echo would put a banner over
            // the host's own lobby.
            config.broadcast.receiveOwnBroadcasts = false
        }
        (invites, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Registers the handler *before* joining: the Realtime SDK ignores
    /// callbacks added after a channel is subscribed, exactly as
    /// ``MatchChannel`` documents.
    func subscribe() async throws {
        let continuation = continuation
        let token = channel.onBroadcast(event: Self.inviteEvent) { message in
            guard let invite = Self.invite(fromBroadcast: message) else { return }
            continuation.yield(invite)
        }
        lock.withLock { subscriptions.append(token) }
        try await channel.subscribeWithError()
    }

    /// Opens the recipient's topic, says it, and leaves again.
    ///
    /// Subscribed first rather than broadcast cold: a channel the client has
    /// never joined has no socket behind it, and this is the same
    /// subscribe-then-broadcast order `SupabaseMatchChannel` proved live.
    func send(_ invite: MatchInvite, to recipientID: UUID) async throws {
        let target = realtime.channel(Self.topic(for: recipientID))
        do {
            try await target.subscribeWithError()
            try await target.broadcast(event: Self.inviteEvent, message: Self.payload(for: invite))
        } catch {
            await target.unsubscribe()
            await realtime.removeChannel(target)
            throw error
        }
        // `removeChannel`, not `unsubscribe` alone: unsubscribing leaves the
        // entry in `RealtimeClientV2.channels`, so every invite would leak one
        // and the socket would never tear down. Same rule as `MatchChannel`.
        await target.unsubscribe()
        await realtime.removeChannel(target)
    }

    func leave() {
        continuation.finish()
        // Dropping the tokens cancels their callbacks, so nothing can yield
        // into a finished stream after this returns.
        lock.withLock { subscriptions.removeAll() }
        let realtime = realtime
        let channel = channel
        Task {
            await channel.unsubscribe()
            await realtime.removeChannel(channel)
        }
    }

    // MARK: - Framing

    /// Every field a primitive, and every key a single lowercase word, so no
    /// encoder strategy — key or date — can rename or reshape one. `sent` is
    /// epoch seconds rather than a `Date` for exactly that reason: the SDK's
    /// own encoder owns `dateEncodingStrategy` and this frame must not care.
    struct Frame: Codable, Sendable, Equatable {
        let match: String
        let code: String
        let host: String
        let name: String
        let sent: Double
    }

    static func payload(for invite: MatchInvite) -> Frame {
        Frame(
            match: invite.matchID.uuidString,
            code: invite.inviteCode,
            host: invite.hostID.uuidString,
            name: invite.hostName,
            sent: invite.sentAt.timeIntervalSince1970)
    }

    /// `nil` for anything that is not a frame this build wrote. A peer can put
    /// arbitrary JSON on the topic; that is a dropped invite, not a crash.
    static func invite(from frame: Frame) -> MatchInvite? {
        guard let matchID = UUID(uuidString: frame.match),
              let hostID = UUID(uuidString: frame.host)
        else { return nil }
        return MatchInvite(
            matchID: matchID,
            inviteCode: frame.code,
            hostID: hostID,
            hostName: frame.name,
            sentAt: Date(timeIntervalSince1970: frame.sent))
    }

    /// The broadcast callback gets the whole `{type, event, payload}` message;
    /// the frame is under `payload`. This is the failure
    /// ``SupabaseMatchChannel/envelope(fromBroadcast:)`` had to be fixed for —
    /// decoding the message itself as a `Frame` yields `nil` for every invite
    /// while subscribe and send both look perfectly healthy. Pinned by an
    /// offline case in `Tests/OnlineTests` against a realistic SDK message, not
    /// only against a `Frame`.
    static func invite(fromBroadcast message: JSONObject) -> MatchInvite? {
        guard let frame = try? (message["payload"]?.objectValue ?? [:]).decode(as: Frame.self)
        else { return nil }
        return invite(from: frame)
    }
}

extension SupabaseBackend {

    /// The invite channel for one signed-in player. Handed to `ShellServices`
    /// as a factory by the app root; nothing else builds one.
    ///
    /// `nonisolated` because the factory the shell holds is a synchronous
    /// `@Sendable (UUID) -> …` and this reaches nothing but an immutable,
    /// `Sendable` `let` — hopping the actor to read it would buy nothing.
    public nonisolated func inviteChannel(for userID: UUID) -> any MatchInviteChannel {
        SupabaseMatchInviteChannel(realtime: realtime, userID: userID)
    }
}
