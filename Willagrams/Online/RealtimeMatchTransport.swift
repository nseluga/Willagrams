//
//  RealtimeMatchTransport.swift
//  Willagrams
//
//  `MatchTransport` over one Supabase Realtime channel, `match:<match uuid>`.
//  Wire bytes travel as broadcast event `wire`; presence carries who is in the
//  match.
//
//  The channel is behind ``MatchChannel`` rather than used directly. That is
//  not speculative indirection: every stream property this file has to honour —
//  buffer-and-replay, finish-on-leave, no-backpressure, no self-echo — is a
//  statement about this file's own bookkeeping, and the seam is what lets a
//  test prove them with no project and no network.
//
//  Never imports SwiftUI and never touches the main actor.
//

import Foundation
import WillagramsRules

/// One `wire` broadcast: the codec's bytes plus who sent them.
///
/// `sender` is the belt to `self: false`'s braces. The channel is configured
/// not to echo, *and* the transport drops anything stamped with its own id, so
/// a config regression cannot turn into a player replaying their own moves.
struct WireEnvelope: Sendable {
    let sender: PlayerID
    let payload: Data
}

/// The slice of a realtime channel ``RealtimeMatchTransport`` needs.
///
/// Handlers are registered once, before ``subscribe(as:)`` — the Realtime SDK
/// ignores callbacks added after a channel is subscribed.
protocol MatchChannel: Sendable {
    func onWire(_ handler: @escaping @Sendable (WireEnvelope) -> Void)
    func onPresence(_ handler: @escaping @Sendable (_ joined: [PlayerID], _ left: [PlayerID]) -> Void)

    /// Joins the topic and tracks `player`. Returns only once the server has
    /// confirmed the subscription.
    func subscribe(as player: PlayerID) async throws

    func send(_ envelope: WireEnvelope) async throws

    /// Untracks and leaves. Synchronous so `leave()` stays callable from a
    /// `deinit`; the underlying unsubscribe is fire-and-forget.
    func leave()
}

public actor RealtimeMatchTransport: MatchTransport {

    public nonisolated let localPlayerID: PlayerID
    public nonisolated let inboundMessages: AsyncStream<MatchMessage>
    public nonisolated let peerConnectionStates: AsyncStream<PeerConnectionState>

    /// Unbounded, so nothing is discarded for want of a reader and no producer
    /// ever suspends on a slow consumer.
    private nonisolated let inbound: AsyncStream<MatchMessage>.Continuation
    private nonisolated let states: AsyncStream<PeerConnectionState>.Continuation

    private nonisolated let channel: any MatchChannel

    /// Who is in the match, and whether this endpoint is done. Lock-guarded
    /// rather than actor state: the presence and broadcast handlers are
    /// synchronous `@Sendable` closures the SDK calls off any thread, and
    /// `leave()` is not `async`.
    private nonisolated let peers = PeerRoster()

    /// How long the last peer may be gone before the match is declared over.
    ///
    /// A transient socket drop arrives as a real presence leave, and finishing
    /// is one-way, so without this a two-second blip would permanently end the
    /// match. `.disconnected` is still delivered the moment the leave arrives —
    /// only the stream *finish* waits the window out. Offline tests pass
    /// `.zero`, which finishes inline exactly as before.
    private nonisolated let peerGrace: Duration

    /// The production window: `MatchSession.reconnectGraceSeconds` (30) plus
    /// margin, so the transport outlives the session's own reconnect window
    /// rather than finishing the streams 25 seconds early and turning
    /// `MatchSession.peerReturned` into dead code.
    ///
    /// ponytail: the two windows are coupled by convention, not by the type
    /// system — `MatchSession` is `@MainActor`, so its constant is not
    /// referenceable from this nonisolated default. `defaultPeerGraceCoversTheSessionWindow`
    /// is the guard that fails if either number moves.
    static let defaultPeerGrace: Duration = .seconds(35)

    /// Builds a transport and returns it only once the channel is subscribed.
    static func connect(
        localPlayerID: PlayerID,
        channel: any MatchChannel,
        peerGrace: Duration = defaultPeerGrace
    ) async throws -> RealtimeMatchTransport {
        let transport = RealtimeMatchTransport(
            localPlayerID: localPlayerID, channel: channel, peerGrace: peerGrace)
        transport.attach()
        do {
            try await channel.subscribe(as: localPlayerID)
        } catch {
            // The channel is already registered on the client and may be
            // mid-join, and a caller that grabbed the streams would hang on
            // them forever. Tear both down before rethrowing.
            transport.leave()
            throw error
        }
        return transport
    }

    init(localPlayerID: PlayerID, channel: any MatchChannel, peerGrace: Duration = defaultPeerGrace) {
        let inbound = AsyncStream.makeStream(of: MatchMessage.self, bufferingPolicy: .unbounded)
        let states = AsyncStream.makeStream(of: PeerConnectionState.self, bufferingPolicy: .unbounded)
        self.localPlayerID = localPlayerID
        self.channel = channel
        self.peerGrace = peerGrace
        self.inboundMessages = inbound.stream
        self.peerConnectionStates = states.stream
        self.inbound = inbound.continuation
        self.states = states.continuation
    }

    /// Registers the channel handlers. Captures the continuations and the
    /// roster rather than `self`, so the channel holding these closures does
    /// not keep the transport alive in a cycle.
    private nonisolated func attach() {
        let local = localPlayerID
        let inbound = inbound
        let states = states
        let peers = peers
        let grace = peerGrace

        channel.onWire { envelope in
            // `self: false` is also set on the channel. This is the second
            // door: a config regression cannot become an echo.
            guard envelope.sender != local else { return }
            // A peer can send anything. Undecodable bytes are dropped, not
            // trapped on — `MatchCodec.decode` is the trust boundary.
            guard let message = try? MatchCodec.decode(envelope.payload) else { return }
            inbound.yield(message)
        }

        channel.onPresence { joined, left in
            for player in joined where player != local {
                if peers.insert(player) { states.yield(.connected(player)) }
            }
            var lastLeft = false
            for player in left where player != local {
                guard peers.remove(player) else { continue }
                states.yield(.disconnected(player))
                lastLeft = peers.isEmpty
            }
            // The last peer's presence leaving ends the match from this side,
            // exactly as `leave()` does. Buffered elements — including the
            // `.disconnected` just yielded — still drain first. A peer that
            // re-joins inside the grace window keeps the match alive: the
            // roster is no longer empty, so nothing finishes.
            guard lastLeft else { return }
            let close = { @Sendable in
                // One lock, not two: an emptiness check and a separate latch
                // could interleave with a re-join between them.
                guard peers.finishIfEmpty() else { return }
                inbound.finish()
                states.finish()
            }
            if grace == .zero {
                close()
            } else {
                // Arming replaces any timer still running, so a
                // leave/re-join/leave inside one window closes on the second
                // leave's window rather than the first's.
                peers.armGrace(
                    Task {
                        try? await Task.sleep(for: grace)
                        guard !Task.isCancelled else { return }
                        close()
                    })
            }
        }
    }

    // MARK: - MatchTransport

    /// Hands `message` to the channel.
    ///
    /// `delivery` is recorded by transports that can honour it; Realtime
    /// broadcast has one mode, so `.lossy` is sent exactly as `.reliable` is.
    /// That is allowed — `MatchDelivery` is a request, not a guarantee.
    ///
    /// Does not wait for a peer to read, and does not require one to exist: a
    /// send into an empty match neither throws nor blocks.
    public func send(_ message: MatchMessage, delivery: MatchDelivery) async throws {
        guard !peers.isFinished else { throw MatchTransportError.peerDisconnected }
        try await channel.send(
            WireEnvelope(sender: localPlayerID, payload: try MatchCodec.encode(message)))
    }

    public nonisolated func leave() {
        // Two latches, not one: the channel has to be torn down even when the
        // streams were already finished by the peer's presence leaving, and it
        // must not be torn down twice when `deinit` follows an explicit call.
        peers.cancelGrace()  // Nothing left to wait for; don't outlive the match.
        if peers.closeChannel() { channel.leave() }
        guard peers.finish() else { return }  // Calling it twice is harmless.
        inbound.finish()
        states.finish()
    }

    /// A dropped transport would otherwise leave the channel joined and
    /// presence tracked until the process exits. `leave()` is already
    /// synchronous and idempotent, which is what makes this safe here.
    deinit { leave() }
}

/// The peers this endpoint has seen, plus the one-way "this match is over"
/// latch. A plain lock: the contents are two words and every access is O(1).
private final class PeerRoster: @unchecked Sendable {
    private let lock = NSLock()
    private var players: Set<PlayerID> = []
    private var finished = false
    private var channelClosed = false
    private var graceTask: Task<Void, Never>?

    /// `true` if `player` was not already present.
    func insert(_ player: PlayerID) -> Bool {
        lock.withLock { finished ? false : players.insert(player).inserted }
    }

    /// `true` if `player` was present.
    func remove(_ player: PlayerID) -> Bool {
        lock.withLock { players.remove(player) != nil }
    }

    var isEmpty: Bool { lock.withLock { players.isEmpty } }

    var isFinished: Bool { lock.withLock { finished } }

    /// Latches closed only if the roster is still empty, under one lock.
    /// `true` for the caller that flipped it.
    func finishIfEmpty() -> Bool {
        lock.withLock {
            guard players.isEmpty, !finished else { return false }
            finished = true
            return true
        }
    }

    /// Holds the pending last-peer grace timer, replacing any predecessor.
    func armGrace(_ task: Task<Void, Never>) {
        lock.withLock {
            graceTask?.cancel()
            graceTask = task
        }
    }

    func cancelGrace() {
        lock.withLock {
            graceTask?.cancel()
            graceTask = nil
        }
    }

    /// Latches the channel torn down. `true` only for the first caller.
    func closeChannel() -> Bool {
        lock.withLock {
            defer { channelClosed = true }
            return !channelClosed
        }
    }

    /// Latches the endpoint closed. `true` only for the caller that flipped it,
    /// so the streams are finished exactly once however many paths race here.
    func finish() -> Bool {
        lock.withLock {
            defer { finished = true }
            return !finished
        }
    }
}
