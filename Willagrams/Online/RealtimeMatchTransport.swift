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

    /// The local socket's own view of this subscription: `false` the moment the
    /// channel leaves `.subscribed`, `true` on every return to it.
    ///
    /// Presence is server-pushed, so the endpoint that *lost* the network hears
    /// nothing at all — every peer stays in its roster and it keeps playing
    /// against opponents that have already frozen. No default, for the reason
    /// ``reconnect()`` has none.
    func onLocalStatus(_ handler: @escaping @Sendable (_ subscribed: Bool) -> Void)

    /// Joins the topic and tracks `player`. Returns only once the server has
    /// confirmed the subscription.
    func subscribe(as player: PlayerID) async throws

    func send(_ envelope: WireEnvelope) async throws

    /// Untracks and leaves. Synchronous so `leave()` stays callable from a
    /// `deinit`; the underlying unsubscribe is fire-and-forget.
    func leave()

    /// Nudges the socket back up after the app was off screen.
    ///
    /// Synchronous and fire-and-forget for the reason ``leave()`` is: the
    /// lifecycle callback that drives it is not `async`. No default: a conformer
    /// that silently did nothing here would look identical to a working one
    /// right up until somebody locked their phone.
    func reconnect()
}

public actor RealtimeMatchTransport: MatchTransport, AppActivityListener {

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

    /// Holds a peer's `.connected` after a re-subscribe until this endpoint
    /// sees its own presence join come back. Same reason `peers` is
    /// lock-guarded: the presence handler is a synchronous `@Sendable` closure
    /// called off any thread.
    private nonisolated let selfJoin = SelfJoinGate()

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

    /// See ``defaultSelfJoinWait``. A parameter so a test can drive the
    /// fallback without waiting a real second for it.
    private nonisolated let selfJoinWait: Duration

    /// The production window: `MatchSession.reconnectGraceSeconds` (45) plus
    /// margin, so the transport outlives the session's own reconnect window
    /// rather than finishing the streams 25 seconds early and turning
    /// `MatchSession.peerReturned` into dead code.
    ///
    /// ponytail: the two windows are coupled by convention, not by the type
    /// system — `MatchSession` is `@MainActor`, so its constant is not
    /// referenceable from this nonisolated default. `defaultPeerGraceCoversTheSessionWindow`
    /// is the guard that fails if either number moves.
    static let defaultPeerGrace: Duration = .seconds(50)

    /// How long a gap in a peer's sequence is held open before the messages
    /// stacked behind it are released anyway.
    ///
    /// A transposed pair arrives microseconds apart, so this only ever has to
    /// cover a fan-out, not a network round trip. It exists because the other
    /// answer — hold forever — turns one genuinely lost broadcast into a game
    /// that stops with nothing on screen to say why. Releasing loses exactly
    /// the lost message, which is what happens today anyway.
    static let defaultGapGrace: Duration = .seconds(2)

    /// How long a re-subscribed endpoint waits for its *own* presence join
    /// before it reports the peer back anyway.
    ///
    /// The wait exists to align the two resume countdowns. The returning
    /// device learns its peer is present from the presence state that arrives
    /// with its own channel join; the peer only learns the same thing once
    /// this device's `track` has reached the server and fanned back out — one
    /// round trip later, which reads on device as one device counting a second
    /// ahead of the other. Both keying off that same fan-out closes the gap.
    ///
    /// The fallback is what bounds it: if the self-join never arrives, the
    /// peer is released regardless and the behaviour is exactly what it was
    /// before this gate existed. It is not an error path with no exit.
    static let defaultSelfJoinWait: Duration = .seconds(1)

    /// The outer bound on a shut gate, measured from the loss rather than from
    /// the return.
    ///
    /// ``defaultSelfJoinWait`` cannot do this job: it is armed when the socket
    /// comes *back*, and a socket that never comes back would leave a gate shut
    /// with nothing to open it. Only reachable when a peer is admitted and no
    /// re-subscribe ever follows — a presence event on a socket that never
    /// churned. Long enough to clear `RealtimeClientOptions.reconnectDelay`
    /// plus a handshake, so an ordinary reconnect is always the shorter wait,
    /// and short enough that the odd case costs seconds rather than the whole
    /// reconnect window.
    static let selfJoinBackstop: Duration = .seconds(3)

    /// Builds a transport and returns it only once the channel is subscribed.
    static func connect(
        localPlayerID: PlayerID,
        channel: any MatchChannel,
        peerGrace: Duration = defaultPeerGrace,
        gapGrace: Duration = defaultGapGrace,
        selfJoinWait: Duration = defaultSelfJoinWait
    ) async throws -> RealtimeMatchTransport {
        let transport = RealtimeMatchTransport(
            localPlayerID: localPlayerID, channel: channel,
            peerGrace: peerGrace, gapGrace: gapGrace, selfJoinWait: selfJoinWait)
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
        gapGrace: Duration = defaultGapGrace,
        selfJoinWait: Duration = defaultSelfJoinWait
    ) {
        let inbound = AsyncStream.makeStream(of: MatchMessage.self, bufferingPolicy: .unbounded)
        let states = AsyncStream.makeStream(of: PeerConnectionState.self, bufferingPolicy: .unbounded)
        self.localPlayerID = localPlayerID
        self.channel = channel
        self.peerGrace = peerGrace
        self.selfJoinWait = selfJoinWait
        self.ordering = WireOrdering(gapGrace: gapGrace)
        self.inboundMessages = inbound.stream
        self.peerConnectionStates = states.stream
        self.inbound = inbound.continuation
        self.states = states.continuation
    }

    /// Opens the last-peer window — or closes immediately when there is no
    /// window to open. Shared by the three ways a roster can empty: the peer
    /// leaving, this endpoint losing its socket, and this endpoint coming back
    /// on screen to find it had lost one while suspended.
    private static func startGrace(
        peers: PeerRoster,
        grace: Duration,
        inbound: AsyncStream<MatchMessage>.Continuation,
        states: AsyncStream<PeerConnectionState>.Continuation
    ) {
        let close = { @Sendable in
            // One lock, not two: an emptiness check and a separate latch could
            // interleave with a re-join between them.
            guard peers.finishIfEmpty() else { return }
            inbound.finish()
            states.finish()
        }
        guard grace != .zero else { return close() }
        // Arming replaces any timer still running, so a leave/re-join/leave
        // inside one window closes on the second leave's window rather than
        // the first's. The roster owns the timer, not this function: it also
        // has to be paused and re-armed from `appActivityChanged(to:)`.
        peers.armGrace(grace, close: close)
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
        let selfJoin = selfJoin
        let selfJoinWait = selfJoinWait

        // What the gate releases when it opens, whether that is the self-join
        // arriving or the fallback expiring.
        let release: @Sendable ([PlayerID]) -> Void = { players in
            for player in players { states.yield(.connected(player)) }
        }

        // Captures the locals, never `self`, so the channel holding this does
        // not retain the transport. The body is `Self.startGrace` because
        // `appActivityChanged(to:)` needs the same window and has no reach in
        // here.
        let startGrace: @Sendable () -> Void = {
            Self.startGrace(peers: peers, grace: grace, inbound: inbound, states: states)
        }

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
            // This endpoint's own key, first. The server fans one `presence_diff`
            // out to everybody in the topic, so the moment this device sees
            // itself back is the same moment its peer does — which is the whole
            // point of holding the peer until then. Opened before the loop so a
            // diff carrying both keys yields inline rather than a tick later.
            if joined.contains(local) { release(selfJoin.open()) }
            for player in joined where player != local {
                guard peers.insert(player) else { continue }
                if selfJoin.admit(player) { states.yield(.connected(player)) }
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
            startGrace()
        }

        // The other way a roster empties: this endpoint is the one that fell
        // off the network. Presence cannot report that — no socket, no server
        // messages — so the subscription's own status is the only witness.
        channel.onLocalStatus { subscribed in
            guard !subscribed else {
                // Back on the air, so this endpoint's own presence join is due
                // now — and only now is there any point counting. No-op unless
                // the gate is shut, so a first subscribe is untouched.
                selfJoin.resubscribed(waiting: selfJoinWait, release: release)
                return
            }
            // Emptying the roster is what makes the recovery work: the rejoin's
            // presence sync re-inserts each peer, and `insert` only yields
            // `.connected` for a player the roster did not already hold.
            let dropped = peers.drain()
            guard !dropped.isEmpty else { return }
            for player in dropped { states.yield(.disconnected(player)) }
            // Closed only on the way *down*, so a first subscribe never waits
            // on anything: the gate exists for the return trip.
            selfJoin.close(backstop: Self.selfJoinBackstop, release: release)
            startGrace()
        }
    }

    // MARK: - The app leaving the screen

    /// The app's scene phase changed.
    ///
    /// Already `nonisolated` — no hop, and nothing here touches actor state, so
    /// a notification delivered off the main queue is simply handled where it
    /// lands.
    public nonisolated func appActivityChanged(to phase: AppActivity.Phase) {
        switch phase {
        case .away:
            // A suspended process cannot hear a peer rejoin, so none of the
            // window is the peer's to lose. Without this the streams finish
            // during the lock and `finish()` is one-way: the session's pump
            // exits for good and Draw and Swap stop answering while the rest of
            // the app carries on looking fine.
            peers.pauseGrace()
        case .active:
            // A transport whose streams are already finished has no match left
            // to re-join; without this every foreground re-opens the Realtime
            // socket for a match that is over.
            guard !peers.isFinished else { return }
            // The loss nothing was awake to hear. `onLocalStatus` is the only
            // witness to this endpoint's own socket going down, and a suspended
            // process runs no callback — so a drop across a lock drains no
            // roster, the rejoin's presence sync re-inserts a peer that never
            // left it, and `insert` yields no `.connected`. Without this the
            // device that walked away is the one that never freezes and never
            // counts back in, while the device that stayed on screen does both.
            //
            // ponytail: it cannot tell a socket that died from one that
            // survived a two-second app switch, so that switch also costs a
            // freeze and a 3-2-1 on this device alone. Telling them apart needs
            // the channel to report its live subscription state, which the SDK
            // only pushes on transition — and the transition is exactly what
            // was slept through. Accepted: a count back in after a trip away is
            // defensible on its own.
            let slept = peers.drain()
            for player in slept { states.yield(.disconnected(player)) }
            // The peer that never comes back still has to end the match, and
            // nothing else arms a window on this path.
            if !slept.isEmpty {
                Self.startGrace(peers: peers, grace: peerGrace, inbound: inbound, states: states)
                // Same return trip as the `onLocalStatus` drop, so the same
                // gate: hold the peer until this device's own presence join
                // comes back, and both count from that one fan-out.
                let states = states
                selfJoin.close(backstop: Self.selfJoinBackstop) { players in
                    for player in players { states.yield(.connected(player)) }
                }
            }
            // Re-subscribed first, and only then does the window start counting
            // again: the peer is reachable again only once there is a socket,
            // and a window spent before that is spent on nothing. The channel
            // re-tracks its own presence when the status returns to
            // `.subscribed` — see `SupabaseMatchChannel.subscribe(as:)`.
            channel.reconnect()
            peers.resumeGrace()
        }
    }

    // MARK: - MatchTransport

    /// Whether the peer-gone latch has closed. The streams finishing is the
    /// observable event, but a test that is not consuming them needs to ask.
    nonisolated var isFinishedForTesting: Bool { peers.isFinished }

    /// What is banked of the peer-grace window while the app is off screen.
    ///
    /// Read by value rather than inferred from timing because the invariant that
    /// matters is a *comparison*: across repeated lock/unlock the banked
    /// remainder may only shrink. A window that is topped up by any amount at
    /// all — a second, a millisecond — holds a dead match open for as long as
    /// somebody keeps locking the phone, and no single timing bound catches
    /// every size of top-up.
    nonisolated var bankedGraceForTesting: Duration? { peers.bankedGrace }

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
        _ = selfJoin.open()  // And the same for a self-join nobody is waiting on.
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

/// Holds the peers a re-subscribe re-discovers until this endpoint sees its
/// own presence join, so both devices learn the match is live again on the one
/// server fan-out rather than a round trip apart.
///
/// Open until something closes it, and it is only ever closed on a *loss* —
/// the first subscribe of a match passes straight through. Every close arms a
/// fallback that opens it regardless, so the worst case is the ungated
/// behaviour, never a peer held forever.
///
/// A plain lock, for the reason ``PeerRoster`` is one: the presence handler is
/// a synchronous `@Sendable` closure the SDK calls off any thread.
private final class SelfJoinGate: @unchecked Sendable {
    private let lock = NSLock()

    /// `nil` when the gate is open. Otherwise the peers admitted since it
    /// closed, in arrival order, waiting on the self-join.
    private var held: [PlayerID]?
    private var fallback: Task<Void, Never>?

    /// Shuts the gate and arms the backstop that bounds it.
    ///
    /// Closing twice is a re-arm, not a second gate: whatever is already held
    /// stays held and the backstop restarts. A second drop before the first
    /// return is exactly when that matters.
    func close(backstop: Duration, release: @escaping @Sendable ([PlayerID]) -> Void) {
        arm(backstop, release: release, onlyIfClosed: false)
    }

    /// The channel is subscribed again, so this endpoint's own presence join
    /// is now actually due — restart the wait from here.
    ///
    /// This, not ``close(backstop:release:)``, is what the wait is measured
    /// from. Closing happens when the socket is *lost*, and the reconnect that
    /// follows does not even begin until `RealtimeClientOptions.reconnectDelay`
    /// has passed; a wait armed at that moment expires while the device is
    /// still offline, opens on an empty gate, and the state sync that
    /// eventually arrives is then released on the spot — which is the ungated
    /// behaviour wearing the gate's clothes.
    ///
    /// No-op on an open gate: an ordinary first subscribe must not wait.
    func resubscribed(waiting wait: Duration, release: @escaping @Sendable ([PlayerID]) -> Void) {
        arm(wait, release: release, onlyIfClosed: true)
    }

    private func arm(
        _ wait: Duration,
        release: @escaping @Sendable ([PlayerID]) -> Void,
        onlyIfClosed: Bool
    ) {
        // `skip` rather than an early return out of the closure: a `defer`
        // that closes the gate would still run on the way out and shut a gate
        // this call was only ever allowed to re-arm.
        var skip = false
        let previous: Task<Void, Never>? = lock.withLock {
            if onlyIfClosed, held == nil {
                skip = true
                return nil
            }
            held = held ?? []
            let previous = fallback
            fallback = nil
            return previous
        }
        guard !skip else { return }
        previous?.cancel()
        let task = Task {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            release(self.open())
        }
        // The gate could have opened between the two locks; handing the task
        // over under the lock is what lets `open` cancel it either way.
        let stale: Bool = lock.withLock {
            guard held != nil else { return true }
            fallback = task
            return false
        }
        if stale { task.cancel() }
    }

    /// `true` if `player` may be reported connected now. `false` means the
    /// gate took it, and it comes back out of ``open()``.
    func admit(_ player: PlayerID) -> Bool {
        lock.withLock {
            guard held != nil else { return true }
            held?.append(player)
            return false
        }
    }

    /// Opens the gate and hands back what it was holding. Idempotent: a second
    /// call returns nothing, so the self-join and the fallback racing cannot
    /// yield the same peer twice.
    func open() -> [PlayerID] {
        let task: Task<Void, Never>? = lock.withLock {
            defer { fallback = nil }
            return fallback
        }
        task?.cancel()
        return lock.withLock {
            defer { held = nil }
            return held ?? []
        }
    }
}

/// The peers this endpoint has seen, plus the one-way "this match is over"
/// latch. A plain lock: the contents are two words and every access is O(1).
private final class PeerRoster: @unchecked Sendable {
    private let lock = NSLock()
    private var players: Set<PlayerID> = []
    private var finished = false
    private var channelClosed = false
    private var graceTask: Task<Void, Never>?

    /// When the running window expires, and what to run then. Kept so the
    /// window can be banked while the app is off screen and re-armed with what
    /// was left of it. `ContinuousClock` runs through a suspension, which is
    /// exactly why the remaining time is computed at the moment of pausing —
    /// on screen, where it is still honest — and never by consulting a clock
    /// afterwards.
    private var graceDeadline: ContinuousClock.Instant?
    private var gracePaused: Duration?
    private var graceClose: (@Sendable () -> Void)?

    /// Whether the app is off screen. Arming while away banks the window
    /// instead of starting it — the drop that opens a window is often *heard*
    /// after the phone is already locked, and a window started then would burn
    /// entirely on a process that is not running.
    private var away = false

    /// `true` if `player` was not already present.
    func insert(_ player: PlayerID) -> Bool {
        lock.withLock { finished ? false : players.insert(player).inserted }
    }

    /// `true` if `player` was present.
    func remove(_ player: PlayerID) -> Bool {
        lock.withLock { players.remove(player) != nil }
    }

    /// Empties the roster and hands back what was in it.
    func drain() -> Set<PlayerID> {
        lock.withLock {
            defer { players.removeAll() }
            return players
        }
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

    /// Arms the last-peer grace for `duration`, replacing any predecessor.
    func armGrace(_ duration: Duration, close: @escaping @Sendable () -> Void) {
        let previous: Task<Void, Never>? = lock.withLock {
            defer {
                graceClose = close
                gracePaused = away ? duration : nil
                graceDeadline = away ? nil : ContinuousClock.now.advanced(by: duration)
            }
            let previous = graceTask
            graceTask = nil
            return previous
        }
        previous?.cancel()
        guard !isAwayNow else { return }
        let task = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            close()
        }
        // The window could have been paused between the two locks. Handing the
        // task over under the lock lets `pauseGrace` cancel it either way.
        let stale: Bool = lock.withLock {
            guard !away else { return true }
            graceTask = task
            return false
        }
        if stale { task.cancel() }
    }

    private var isAwayNow: Bool { lock.withLock { away } }

    var bankedGrace: Duration? { lock.withLock { gracePaused } }

    /// Banks what is left of a running window and stops it. Idempotent: a
    /// second background notification cannot bank a second, longer remainder.
    func pauseGrace() {
        let task: Task<Void, Never>? = lock.withLock {
            guard !away else { return nil }
            away = true
            if let deadline = graceDeadline {
                gracePaused = max(.zero, ContinuousClock.now.duration(to: deadline))
                graceDeadline = nil
            }
            defer { graceTask = nil }
            return graceTask
        }
        task?.cancel()
    }

    /// Re-arms a banked window with exactly what was left of it. A peer that
    /// never comes back still runs out: the remainder is what it had, not a
    /// fresh budget, so no amount of locking and unlocking holds a dead match
    /// open.
    func resumeGrace() {
        let work: (Duration, @Sendable () -> Void)? = lock.withLock {
            guard away else { return nil }
            away = false
            guard let remaining = gracePaused, let close = graceClose else { return nil }
            return (remaining, close)
        }
        guard let (remaining, close) = work else { return }
        armGrace(remaining, close: close)
    }

    /// Drops the window entirely. `away` is deliberately *not* cleared: it
    /// tracks where the app is, not what this window is doing, and the only
    /// caller is `leave()`, after which nothing arms a window again. A roster is
    /// owned by exactly one transport and is never reused, so there is no second
    /// match that could inherit a stale `away`.
    func cancelGrace() {
        let task: Task<Void, Never>? = lock.withLock {
            defer {
                graceTask = nil
                graceDeadline = nil
                gracePaused = nil
                graceClose = nil
            }
            return graceTask
        }
        task?.cancel()
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
