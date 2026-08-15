//
//  MatchTransport.swift
//  Willagrams
//
//  The one seam every networked match feature is built on. It carries typed
//  `MatchMessage` values only — never `Data`. Encoding, framing and the 16KB
//  reliable-send limit belong to the codec and the GameKit adapter, so nothing
//  above this line can grow a dependency on wire bytes.
//
//  This file must never import GameKit. Only the GameKit adapter may.
//

import WillagramsRules

/// How hard the transport should try to land a single message.
///
/// This is a request, not a guarantee: a conforming transport may deliver a
/// `.lossy` message reliably. It maps onto `GKMatch.SendDataMode` in the
/// GameKit adapter.
public enum MatchDelivery: Sendable, Equatable {
    /// Must arrive, and in send order relative to other reliable messages.
    case reliable
    /// May be discarded in flight. For messages a later message supersedes.
    case lossy
}

/// A change in the connection state of the one remote peer.
///
/// Two players per match this round, so there is exactly one peer. The
/// `PlayerID` is carried anyway because the GameKit adapter and the
/// end-of-match screen both need to name who left.
public enum PeerConnectionState: Sendable, Equatable {
    case connected(PlayerID)
    case disconnected(PlayerID)
}

/// Failures a transport can report to the caller of `send`.
public enum MatchTransportError: Error, Sendable, Equatable {
    /// The peer is gone. Nothing further will be delivered to it.
    case peerDisconnected
}

/// A two-player message channel between this device and its one peer.
///
/// ## AsyncStream semantics (the same for every conforming transport)
///
/// - **Single subscription.** `inboundMessages` and `peerConnectionStates` each
///   return the *same* stream on every access, not a fresh subscription per
///   call. Consuming one from two places divides the elements between the two
///   iterators; that is unsupported. Exactly one consumer per stream per
///   endpoint.
/// - **Unbounded buffering.** Elements produced before a consumer starts
///   iterating are queued and delivered in production order on first iteration.
///   Nothing is discarded for want of a reader, so a consumer that begins
///   iterating after a send neither deadlocks nor misses what it missed — the
///   state machines above this seam are not ordering-sensitive to when they
///   start reading.
/// - **`send` never applies backpressure.** It does not suspend waiting for the
///   peer to read, so a slow or absent consumer cannot stall the sender.
/// - **Termination.** Both streams finish once the peer disconnects, after any
///   already-buffered elements are delivered. A `for await` loop over either
///   stream therefore ends on disconnect rather than hanging.
public protocol MatchTransport: Sendable {

    /// This device's player. Stable for the life of the match.
    var localPlayerID: PlayerID { get }

    /// Messages from the peer, in the order the transport received them.
    ///
    /// See the type-level note above for subscription and buffering semantics.
    var inboundMessages: AsyncStream<MatchMessage> { get }

    /// Connection-state changes for the one remote peer.
    ///
    /// The current state is buffered ahead of the first consumer, so a late
    /// subscriber still learns the peer is connected.
    var peerConnectionStates: AsyncStream<PeerConnectionState> { get }

    /// Hands `message` to the peer.
    ///
    /// Returns as soon as the message is handed off — it does not wait for the
    /// peer to receive or read it. A `.lossy` message discarded in flight is
    /// not an error and returns normally.
    ///
    /// - Throws: `MatchTransportError.peerDisconnected` if the peer has already
    ///   gone, or a transport-specific error if handoff itself failed.
    func send(_ message: MatchMessage, delivery: MatchDelivery) async throws
}
