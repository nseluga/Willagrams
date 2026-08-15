//
//  FakeTransport.swift
//  Willagrams
//
//  Two `MatchTransport` endpoints wired to each other in memory, so a single
//  test process can drive both sides of a match with no device, no network and
//  no Game Center account.
//
//  Guardrail: this type must never be reachable from a shipping code path. The
//  whole file is behind `#if DEBUG`, so it does not exist in a Release build of
//  the app — a shipping call site fails to compile rather than failing review.
//  SwiftPM test builds are Debug, so the test target still sees it.
//
//  This file must never import GameKit.
//

#if DEBUG

import WillagramsRules

/// An in-memory `MatchTransport` endpoint, paired with exactly one other.
///
/// Test and preview use only. Create endpoints with ``pair(_:_:)``.
///
/// Isolation: `FakeTransport` is an `actor`. The only mutable state is the drop
/// filter, which the actor guards. Everything else is `nonisolated let` —
/// `AsyncStream.Continuation` is itself thread-safe, so delivery needs no lock
/// and `send` never suspends on one.
///
/// Stream semantics are exactly the ones documented on ``MatchTransport``:
/// one stream per endpoint (not one per access), unbounded buffering, both
/// streams finish on disconnect.
public actor FakeTransport: MatchTransport {

    public nonisolated let localPlayerID: PlayerID
    public nonisolated let inboundMessages: AsyncStream<MatchMessage>
    public nonisolated let peerConnectionStates: AsyncStream<PeerConnectionState>

    /// Feeds the *peer's* streams. Held instead of a reference to the peer
    /// itself, which keeps pairing acyclic and every stored property a `let`.
    private nonisolated let peerInbound: AsyncStream<MatchMessage>.Continuation
    private nonisolated let peerStates: AsyncStream<PeerConnectionState>.Continuation
    private nonisolated let ownInbound: AsyncStream<MatchMessage>.Continuation
    private nonisolated let ownStates: AsyncStream<PeerConnectionState>.Continuation

    /// Messages this endpoint sends that match are discarded in flight.
    private var dropFilter: (@Sendable (MatchMessage) -> Bool)?

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

    // MARK: - Hook 1: pair two endpoints

    /// Builds two endpoints wired to each other.
    ///
    /// Each endpoint starts already connected: a `.connected` state for the
    /// other player is buffered on both connection-state streams before this
    /// returns, so a consumer that subscribes later still sees it.
    public static func pair(
        _ first: PlayerID,
        _ second: PlayerID
    ) -> (first: FakeTransport, second: FakeTransport) {
        let firstInbound = AsyncStream.makeStream(of: MatchMessage.self, bufferingPolicy: .unbounded)
        let secondInbound = AsyncStream.makeStream(of: MatchMessage.self, bufferingPolicy: .unbounded)
        let firstStates = AsyncStream.makeStream(of: PeerConnectionState.self, bufferingPolicy: .unbounded)
        let secondStates = AsyncStream.makeStream(of: PeerConnectionState.self, bufferingPolicy: .unbounded)

        let firstEndpoint = FakeTransport(
            localPlayerID: first,
            inboundMessages: firstInbound.stream,
            peerConnectionStates: firstStates.stream,
            ownInbound: firstInbound.continuation,
            ownStates: firstStates.continuation,
            peerInbound: secondInbound.continuation,
            peerStates: secondStates.continuation
        )
        let secondEndpoint = FakeTransport(
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
    /// `delivery` is recorded by real transports; both modes are delivered
    /// identically here — loss is modelled explicitly by ``setDropFilter(_:)``
    /// so tests stay deterministic rather than probabilistic.
    ///
    /// A message the drop filter discards returns normally and promptly: from
    /// the sender's side a lost packet is indistinguishable from a sent one.
    public func send(_ message: MatchMessage, delivery: MatchDelivery) async throws {
        if dropFilter?(message) == true { return }
        guard case .enqueued = peerInbound.yield(message) else {
            throw MatchTransportError.peerDisconnected
        }
    }

    // MARK: - Hook 2: drop a message in flight

    /// Discards every message this endpoint sends for which `shouldDrop`
    /// returns `true`. Pass `nil` to deliver everything again.
    ///
    /// The message is discarded on the sending side, which is what a packet
    /// lost in flight looks like to both peers.
    ///
    /// Precedence: the filter is checked *before* the peer-terminated check, so
    /// a dropped message sent after the peer has gone returns normally instead
    /// of throwing `.peerDisconnected`. That reads right for `.lossy` — a lost
    /// packet looks sent — and is a known corner for `.reliable`. Do not rely on
    /// the throw while a filter is installed.
    public func setDropFilter(_ shouldDrop: (@Sendable (MatchMessage) -> Bool)?) {
        dropFilter = shouldDrop
    }

    // MARK: - Hook 3: leave the match

    /// Leaves the match from this endpoint.
    ///
    /// Double duty: the real leave path, and the test hook for simulating the
    /// peer dropping out — from this side the two are the same operation, and
    /// GameKit reports a graceful leave and a crash as the same state.
    ///
    /// The surviving endpoint sees `.disconnected(localPlayerID)` on its
    /// connection-state stream. Both endpoints' streams then finish, after
    /// their buffered elements are delivered, so no `for await` loop on either
    /// side is left hanging on a peer that will never speak again. Subsequent
    /// sends throw `MatchTransportError.peerDisconnected`.
    public nonisolated func leave() {
        peerStates.yield(.disconnected(localPlayerID))
        peerInbound.finish()
        peerStates.finish()
        ownInbound.finish()
        ownStates.finish()
    }
}

#endif
