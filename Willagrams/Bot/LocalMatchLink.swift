//
//  LocalMatchLink.swift
//  Willagrams
//
//  Two `MatchTransport` endpoints wired to each other in memory — the shipping
//  link a solo match runs over, with the bot's `MatchSession` on the far end.
//
//  This is NOT a test double. It carries no `#if DEBUG` fence and no drop
//  filter: it exists in a Release build precisely so solo play can ship.
//  `FakeTransport` is the debug-only cousin and must never be referenced here.
//
//  This file must never import GameKit.
//

// The app compiles `Willagrams/Match` and `Willagrams/Bot` into one module,
// where there is nothing to import. `Tests/BotTests` compiles them as two, so
// the import is real there and only there.
#if canImport(Match)
import Match
#endif

import WillagramsRules

/// An in-memory `MatchTransport` endpoint, paired with exactly one other.
///
/// Create endpoints with ``pair(_:_:)``; an endpoint built any other way has no
/// peer to talk to, which is why `init` is private.
///
/// Isolation: every stored property is a `nonisolated let`. An
/// `AsyncStream.Continuation` is itself thread-safe, so delivery needs no lock,
/// `send` never suspends on one, and there is no cached "connected" flag that
/// could outlive `leave()` — the continuation's own terminated state is the
/// single source of truth for whether the peer is still there.
///
/// Stream semantics are exactly the ones documented on ``MatchTransport``: one
/// stream per endpoint (not one per access), unbounded buffering, both streams
/// finish on disconnect.
public actor LocalMatchLink: MatchTransport {

    public nonisolated let localPlayerID: PlayerID
    public nonisolated let inboundMessages: AsyncStream<MatchMessage>
    public nonisolated let peerConnectionStates: AsyncStream<PeerConnectionState>

    /// Feeds the *peer's* streams. Held instead of a reference to the peer
    /// itself, which keeps pairing acyclic and every stored property a `let`.
    private nonisolated let peerInbound: AsyncStream<MatchMessage>.Continuation
    private nonisolated let peerStates: AsyncStream<PeerConnectionState>.Continuation
    private nonisolated let ownInbound: AsyncStream<MatchMessage>.Continuation
    private nonisolated let ownStates: AsyncStream<PeerConnectionState>.Continuation

    private init(
        localPlayerID: PlayerID,
        inboundMessages: AsyncStream<MatchMessage>,
        peerConnectionStates: AsyncStream<PeerConnectionState>,
        ownInbound: AsyncStream<MatchMessage>.Continuation,
        ownStates: AsyncStream<PeerConnectionState>.Continuation,
        peerInbound: AsyncStream<MatchMessage>.Continuation,
        peerStates: AsyncStream<PeerConnectionState>.Continuation
    ) {
        self.localPlayerID = localPlayerID
        self.inboundMessages = inboundMessages
        self.peerConnectionStates = peerConnectionStates
        self.ownInbound = ownInbound
        self.ownStates = ownStates
        self.peerInbound = peerInbound
        self.peerStates = peerStates
    }

    /// Builds two endpoints wired to each other.
    ///
    /// Each endpoint starts already connected: a `.connected` state naming the
    /// other player is buffered on both connection-state streams before this
    /// returns, so a consumer that subscribes later still sees it.
    public static func pair(
        _ first: PlayerID,
        _ second: PlayerID
    ) -> (first: LocalMatchLink, second: LocalMatchLink) {
        // `.unbounded`, not `.bufferingNewest`: the protocol promises nothing is
        // discarded for want of a reader, and that `send` never suspends.
        let firstInbound = AsyncStream.makeStream(of: MatchMessage.self, bufferingPolicy: .unbounded)
        let secondInbound = AsyncStream.makeStream(of: MatchMessage.self, bufferingPolicy: .unbounded)
        let firstStates = AsyncStream.makeStream(of: PeerConnectionState.self, bufferingPolicy: .unbounded)
        let secondStates = AsyncStream.makeStream(of: PeerConnectionState.self, bufferingPolicy: .unbounded)

        let firstEndpoint = LocalMatchLink(
            localPlayerID: first,
            inboundMessages: firstInbound.stream,
            peerConnectionStates: firstStates.stream,
            ownInbound: firstInbound.continuation,
            ownStates: firstStates.continuation,
            peerInbound: secondInbound.continuation,
            peerStates: secondStates.continuation
        )
        let secondEndpoint = LocalMatchLink(
            localPlayerID: second,
            inboundMessages: secondInbound.stream,
            peerConnectionStates: secondStates.stream,
            ownInbound: secondInbound.continuation,
            ownStates: secondStates.continuation,
            peerInbound: firstInbound.continuation,
            peerStates: firstStates.continuation
        )

        firstStates.continuation.yield(.connected(second))
        secondStates.continuation.yield(.connected(first))
        return (firstEndpoint, secondEndpoint)
    }

    // MARK: - MatchTransport

    /// Hands `message` to the paired endpoint's inbound stream and returns.
    ///
    /// `delivery` is honoured by real transports; both modes are delivered
    /// identically over a link that has no wire to lose anything on.
    public func send(_ message: MatchMessage, delivery: MatchDelivery) async throws {
        guard case .enqueued = peerInbound.yield(message) else {
            throw MatchTransportError.peerDisconnected
        }
    }

    /// Leaves the match from this endpoint.
    ///
    /// The surviving endpoint sees `.disconnected(localPlayerID)` on its
    /// connection-state stream. Both endpoints' streams then finish, after their
    /// buffered elements are delivered, so no `for await` loop on either side is
    /// left hanging on a peer that will never speak again. Subsequent sends
    /// throw `MatchTransportError.peerDisconnected`.
    ///
    /// Calling it more than once is harmless: `yield` and `finish` on an already
    /// finished continuation are both no-ops.
    public nonisolated func leave() {
        peerStates.yield(.disconnected(localPlayerID))
        peerInbound.finish()
        peerStates.finish()
        ownInbound.finish()
        ownStates.finish()
    }
}
