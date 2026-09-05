//
//  MatchInvite.swift
//  Willagrams
//
//  "Come and play" as one value, and the seam it travels over. Deliberately
//  SDK-free: `Tests/ShellTests` compiles this file by name into a target that
//  has no Supabase dependency, so the shell's banner rules are provable with no
//  project and no network. The `Realtime` half lives in
//  `SupabaseMatchInviteChannel.swift`, which only the packages that carry the
//  SDK compile.
//
//  Nothing here is stored. An invite is a broadcast and only a broadcast — no
//  table, no migration, no history. A recipient who is not listening when it is
//  sent never sees it, which is why ``FakeInviteBus`` drops one on the floor
//  rather than buffering it.
//

import Foundation

/// One "play me" from one friend, as it travels between two devices.
///
/// It carries the *code*, not the match: joining is item 4's `OnlineMatch.join`
/// on `inviteCode`, exactly as a hand-typed code is, so an invite is a shortcut
/// past the keyboard and never a second way into a lobby.
public struct MatchInvite: Sendable, Equatable, Identifiable {

    /// The lobby's `matches` row. The identity a recipient dedupes on: a host
    /// who taps twice must not put two banners up for one lobby.
    public let matchID: UUID

    /// Six uppercase characters — `JoinModel.codeLength`, never the eight of a
    /// friend code.
    public let inviteCode: String

    public let hostID: UUID

    /// The host's display name, carried rather than looked up: the banner says
    /// who is asking, and a profile read on the way to drawing it would leave
    /// the banner nameless for as long as the round trip took.
    ///
    /// Clamped by ``init(matchID:inviteCode:hostID:hostName:sentAt:)`` — see
    /// ``hostNameLimit``. Carried means attacker-chosen, and the banner is the
    /// only thing drawn over four screens.
    public let hostName: String

    /// When the host sent it, by the *host's* clock. Age is decided against an
    /// injected clock on the recipient, so a banner cannot outlive its lobby.
    public let sentAt: Date

    public var id: UUID { matchID }

    /// The most of a sender's name that is ever shown. Long enough for a real
    /// display name and short enough that no name can grow the banner over the
    /// screen and push Join out of reach.
    public static let hostNameLimit = 40

    /// Clamps the name here rather than at the one place that draws it: every
    /// invite — off the wire, off the fake bus, out of a test — goes through
    /// this initialiser, and a view that owned the rule would be one screen's
    /// opinion rather than the value's own.
    public init(matchID: UUID, inviteCode: String, hostID: UUID, hostName: String, sentAt: Date) {
        self.matchID = matchID
        self.inviteCode = inviteCode
        self.hostID = hostID
        self.hostName = String(hostName.filter { !$0.isNewline }.prefix(Self.hostNameLimit))
        self.sentAt = sentAt
    }
}

/// The per-user invite channel, as everything above it sees one.
///
/// A new type beside the backend seam rather than a method on it:
/// `BackendContracts.swift` is frozen, and an invite is a broadcast with no row
/// behind it — nothing about it belongs in a protocol whose every other member
/// reads or writes a table.
///
/// ``invites`` has exactly one consumer, like `MatchTransport`'s streams: the
/// `ShellModel` that owns the channel. Broadcast promises no ordering, so
/// nothing downstream may assume any.
public protocol MatchInviteChannel: Sendable {

    /// Invites addressed to the local user. Finishes when ``leave()`` is called.
    var invites: AsyncStream<MatchInvite> { get }

    /// Joins the local user's topic. Returns once the server has confirmed it;
    /// nothing sent before it returns is delivered.
    func subscribe() async throws

    /// Broadcasts to `recipientID`'s topic. Silent when nobody is listening —
    /// that is what a broadcast is.
    func send(_ invite: MatchInvite, to recipientID: UUID) async throws

    /// Leaves and finishes ``invites``. Synchronous so a teardown can call it.
    func leave()
}

#if DEBUG

/// An in-memory invite bus: two `ShellModel`s, one process, no network.
///
/// `#if DEBUG` for the reason `FakeBackend` is — an in-memory invite channel in
/// a shipped build would look like a working one nobody ever gets an invite on.
///
/// It **withholds**. A channel is reachable only between its ``subscribe()`` and
/// its ``leave()``; an invite sent to anyone else is counted in ``dropped`` and
/// discarded. Buffering would make "arrives while listening", "dropped during a
/// match" and "at most one banner" all vacuously true, which is the opposite of
/// what this double is for.
public final class FakeInviteBus: @unchecked Sendable {

    private let lock = NSLock()

    /// The token is the channel's identity: `AsyncStream.Continuation` is a
    /// struct, so a stale channel's teardown has nothing else to compare and
    /// would otherwise unsubscribe the live channel that replaced it.
    private var live: [UUID: (token: UUID, continuation: AsyncStream<MatchInvite>.Continuation)] = [:]

    /// Invites handed to a live subscriber, and invites thrown away. Both, so a
    /// "nothing was sent" assertion has a positive twin: a bus that quietly
    /// stopped delivering would otherwise pass every refusal check.
    private var deliveredCount = 0
    private var droppedCount = 0

    public init() {}

    public var delivered: Int { lock.withLock { deliveredCount } }
    public var dropped: Int { lock.withLock { droppedCount } }

    /// Whether `userID` is subscribed right now.
    public func isListening(_ userID: UUID) -> Bool { lock.withLock { live[userID] != nil } }

    /// The channel for one user. Built unsubscribed: nothing reaches it until
    /// its owner calls ``MatchInviteChannel/subscribe()``.
    public func channel(for userID: UUID) -> any MatchInviteChannel {
        FakeInviteChannel(bus: self, userID: userID)
    }

    /// The factory ``ShellServices`` takes, on this one bus.
    public var factory: @Sendable (UUID) -> any MatchInviteChannel {
        { [self] in channel(for: $0) }
    }

    fileprivate func register(
        _ userID: UUID,
        _ token: UUID,
        _ continuation: AsyncStream<MatchInvite>.Continuation
    ) {
        lock.withLock { live[userID] = (token, continuation) }
    }

    fileprivate func unregister(_ userID: UUID, _ token: UUID) {
        lock.withLock {
            if live[userID]?.token == token { live[userID] = nil }
        }
    }

    fileprivate func deliver(_ invite: MatchInvite, to recipientID: UUID) {
        let continuation = lock.withLock { () -> AsyncStream<MatchInvite>.Continuation? in
            guard let found = live[recipientID] else {
                droppedCount += 1
                return nil
            }
            deliveredCount += 1
            return found.continuation
        }
        continuation?.yield(invite)
    }
}

/// One user's endpoint on a ``FakeInviteBus``.
public final class FakeInviteChannel: MatchInviteChannel, @unchecked Sendable {

    public let invites: AsyncStream<MatchInvite>
    private let continuation: AsyncStream<MatchInvite>.Continuation
    private let bus: FakeInviteBus
    private let userID: UUID
    private let token = UUID()

    fileprivate init(bus: FakeInviteBus, userID: UUID) {
        self.bus = bus
        self.userID = userID
        (invites, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public func subscribe() async throws {
        bus.register(userID, token, continuation)
    }

    public func send(_ invite: MatchInvite, to recipientID: UUID) async throws {
        bus.deliver(invite, to: recipientID)
    }

    public func leave() {
        bus.unregister(userID, token)
        continuation.finish()
    }
}

#endif
