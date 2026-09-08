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

    /// This sender's own count, starting at 0 and rising by one per send.
    ///
    /// Supabase Realtime broadcast is best-effort ordered, not ordered: a
    /// fan-out transposes two frames often enough to see it in a live test.
    /// The game is a command stream — a `grant` applied before the `start` it
    /// answers is a board the two devices no longer agree about — so order has
    /// to be re-established here rather than assumed of the platform.
    let sequence: UInt64

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

    /// This endpoint's own send count. Actor state, so it is stamped under the
    /// actor's serialization rather than a lock.
    private var nextOutboundSequence: UInt64 = 0

    /// Per-peer ordering for the receive path. Lock-guarded for the reason
    /// ``peers`` is: `onWire` is a synchronous `@Sendable` closure the SDK
    /// calls off any thread.
    private nonisolated let ordering: WireOrdering

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

    /// How long a gap in a peer's sequence is held open before the messages
    /// stacked behind it are released anyway.
    ///
    /// A transposed pair arrives microseconds apart, so this only ever has to
    /// cover a fan-out, not a network round trip. It exists because the other
    /// answer — hold forever — turns one genuinely lost broadcast into a game
    /// that stops with nothing on screen to say why. Releasing loses exactly
    /// the lost message, which is what happens today anyway.
    static let defaultGapGrace: Duration = .seconds(2)

    /// Builds a transport and returns it only once the channel is subscribed.
    static func connect(
        localPlayerID: PlayerID,
        channel: any MatchChannel,
        peerGrace: Duration = defaultPeerGrace,
        gapGrace: Duration = defaultGapGrace
    ) async throws -> RealtimeMatchTransport {
        let transport = RealtimeMatchTransport(
            localPlayerID: localPlayerID, channel: channel,
            peerGrace: peerGrace, gapGrace: gapGrace)
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

    init(
        localPlayerID: PlayerID,
        channel: any MatchChannel,
        peerGrace: Duration = defaultPeerGrace,
        gapGrace: Duration = defaultGapGrace
    ) {
        let inbound = AsyncStream.makeStream(of: MatchMessage.self, bufferingPolicy: .unbounded)
        let states = AsyncStream.makeStream(of: PeerConnectionState.self, bufferingPolicy: .unbounded)
        self.localPlayerID = localPlayerID
        self.channel = channel
        self.peerGrace = peerGrace
        self.ordering = WireOrdering(gapGrace: gapGrace)
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
        let ordering = ordering

        // Yields whatever the orderer says is now deliverable, in order.
        // Decoding stays after the reordering: undecodable bytes still occupy
        // a sequence number, so dropping them before the orderer sees them
        // would open a gap that never closes.
        let deliver: @Sendable ([Data]) -> Void = { payloads in
            for payload in payloads {
                // A peer can send anything. Undecodable bytes are dropped, not
                // trapped on — `MatchCodec.decode` is the trust boundary.
                guard let message = try? MatchCodec.decode(payload) else { continue }
                inbound.yield(message)
            }
        }

        channel.onWire { envelope in
            // `self: false` is also set on the channel. This is the second
            // door: a config regression cannot become an echo.
            guard envelope.sender != local else { return }
            deliver(ordering.accept(envelope, release: deliver))
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
        // Stamped before the await, on the actor, so two concurrent sends
        // cannot take the same number or swap them.
        let sequence = nextOutboundSequence
        nextOutboundSequence += 1
        try await channel.send(
            WireEnvelope(
                sender: localPlayerID,
                sequence: sequence,
                payload: try MatchCodec.encode(message)))
    }

    public nonisolated func leave() {
        // Two latches, not one: the channel has to be torn down even when the
        // streams were already finished by the peer's presence leaving, and it
        // must not be torn down twice when `deinit` follows an explicit call.
        peers.cancelGrace()  // Nothing left to wait for; don't outlive the match.
        ordering.cancelGap()  // Same reason: a held gap has nobody to deliver to.
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

/// Puts one peer's broadcasts back into the order that peer sent them.
///
/// A plain lock for the reason `PeerRoster` is: the broadcast handler is a
/// synchronous `@Sendable` closure called off any thread, so this cannot be
/// actor state without making delivery reentrant.
///
/// Only the ordering lives here — decoding, echo-dropping and the streams stay
/// in the transport. What this returns is always a contiguous run, oldest
/// first, and never a message it has already returned.
private final class WireOrdering: @unchecked Sendable {

    private let lock = NSLock()

    /// The next sequence expected from each sender this endpoint has heard.
    /// A sender not in here has not been heard from yet.
    private var expected: [PlayerID: UInt64] = [:]

    /// Arrivals past the gap, held until the gap closes.
    private var held: [PlayerID: [UInt64: Data]] = [:]

    private let gapGrace: Duration
    private var gapTask: Task<Void, Never>?

    init(gapGrace: Duration) { self.gapGrace = gapGrace }

    /// Takes one arrival and returns what is now deliverable, in order.
    ///
    /// `release` is called later, off this call, when a gap times out — a gap
    /// is opened by an arrival but closed by a clock, and the caller has no
    /// other way to hear about the second.
    func accept(
        _ envelope: WireEnvelope,
        release: @escaping @Sendable ([Data]) -> Void
    ) -> [Data] {
        let (ready, hasGap) = lock.withLock { () -> ([Data], Bool) in
            let sender = envelope.sender
            // Every peer is expected to start at 0. Taking the first arrival as
            // the baseline instead would drop the earlier half of a transposed
            // opening pair — and the opening pair is `start`, the one message
            // the whole match is built on. A peer whose earlier numbers really
            // never arrive costs one gap window, once.
            let next = expected[sender] ?? 0
            // Already delivered, or already skipped past. A resend and a replay
            // look the same from here, and both must not reach the session
            // twice.
            guard envelope.sequence >= next else { return ([], !(held[sender] ?? [:]).isEmpty) }
            guard envelope.sequence == next else {
                held[sender, default: [:]][envelope.sequence] = envelope.payload
                return ([], true)
            }
            var payloads = [envelope.payload]
            var cursor = next + 1
            while let payload = held[sender]?.removeValue(forKey: cursor) {
                payloads.append(payload)
                cursor += 1
            }
            if held[sender]?.isEmpty == true { held[sender] = nil }
            expected[sender] = cursor
            return (payloads, !(held[sender] ?? [:]).isEmpty)
        }
        if hasGap { armGap(release) } else { cancelGap() }
        return ready
    }

    /// Gives up on the missing message and releases everything held.
    ///
    /// Losing one broadcast is what happens today for every reordered pair, so
    /// this is not a new failure mode — it is the old one, bounded, and only
    /// after the reordering had its chance.
    private func armGap(_ release: @escaping @Sendable ([Data]) -> Void) {
        let grace = gapGrace
        let task = Task { [weak self] in
            if grace != .zero { try? await Task.sleep(for: grace) }
            guard !Task.isCancelled, let self else { return }
            let payloads = self.drainHeld()
            if !payloads.isEmpty { release(payloads) }
        }
        lock.withLock {
            gapTask?.cancel()
            gapTask = task
        }
    }

    /// Everything held, each sender's run in its own order, with `expected`
    /// moved past the hole so the next arrival is not mistaken for a replay.
    private func drainHeld() -> [Data] {
        lock.withLock {
            var payloads: [Data] = []
            for (sender, buffered) in held {
                for sequence in buffered.keys.sorted() {
                    payloads.append(buffered[sequence]!)
                    expected[sender] = sequence + 1
                }
            }
            held.removeAll()
            gapTask = nil
            return payloads
        }
    }

    func cancelGap() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            defer { gapTask = nil }
            return gapTask
        }
        task?.cancel()
    }
}
