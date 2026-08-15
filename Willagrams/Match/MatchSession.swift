//
//  MatchSession.swift
//  Willagrams
//
//  The client-side match state machine. One per device. It owns this device's
//  view of the match — status, rack, board — and is the only thing that talks to
//  the transport and, when this device is host, to the pool.
//
//  State only: it presents no UI and knows nothing about views.
//
//  This file must never import GameKit.
//

import Foundation
import Observation
import WillagramsRules

/// Why the session refused to move a tile.
///
/// Separate from the frozen `PlacementError` because the reasons are not the
/// rules' business: the rules do not know about the Draw obligation. It carries
/// a `String` rather than the underlying error so the type stays `Sendable` —
/// `any Error` would block the synthesis.
public enum BoardActionError: Error, Sendable, Equatable {
    /// A tile is waiting to be taken. The board is frozen until the player
    /// presses Draw and takes it.
    case drawPending
    /// The rules refused the move. Carries the frozen error's description.
    case placementFailed(String)
}

/// This device's match, as an observable state machine.
///
/// ## What it owns
///
/// The single consumer of `transport.inboundMessages`, and — when this device
/// is host — the single caller of ``HostPool/handle(_:)``. Both are consumed
/// from one place because both break quietly when they are not: a second
/// iterator divides the stream rather than failing, and two concurrent `handle`
/// callers interleave on the wire.
///
/// ## Serialisation invariant
///
/// Everything that reaches the wire or the pool goes through ``enqueue(_:)``,
/// a FIFO chain of tasks where each awaits its predecessor. `tail` is mutated
/// synchronously on the main actor, so enqueue order *is* run order by
/// construction, and at most one `handle` is ever in flight. ``submitToHost(_:)``
/// is the only call site of `handle` in the codebase; nothing else may call it.
///
/// ## A device never receives its own sends
///
/// So the local half of every event is applied locally, never learned from the
/// wire: ``startMatch(seed:startingHandSize:countdownSeconds:)`` applies the
/// start it sends, and the host applies its own tile from `handle`'s return
/// value — that grant never travels.
///
/// ## Arrival order is not trusted
///
/// `.poolExhausted` is a latch, not an end state: the next completed board ends
/// the match, so a grant that arrives after it — a reordering the transport
/// permits — is still applied to the rack. Only `.win` and `.resign` are
/// terminal.
@MainActor
@Observable
public final class MatchSession {

    // MARK: - Observed state

    /// This device's whole view of the match. The rack, board and status the
    /// shell and the board view read.
    ///
    /// `pool` is a placeholder: only the host holds a real pool, and showing how
    /// many tiles are left is a later item.
    public private(set) var state = GameState(
        pool: Pool(tiles: []),
        status: .countdown(secondsRemaining: 0)
    )

    /// Tiles granted to this device because the *opponent* drew, held until the
    /// player takes them.
    ///
    /// Both players take a tile for the same event, so this device owes one.
    /// While this is non-empty the board is frozen — see ``place(tileID:at:)``.
    public private(set) var pendingDrawTiles: [Tile] = []

    /// Whether a tile is waiting to be taken. The Draw button reads this to
    /// change what pressing it means.
    public var hasPendingDraw: Bool { !pendingDrawTiles.isEmpty }

    /// The pool has run out. Latching, and deliberately not an end state: the
    /// next completed board ends the match.
    public private(set) var poolIsExhausted = false

    /// Carried from the start message for the opening deal, a later item.
    public private(set) var startingHandSize = 0

    /// The last thing that went wrong, as text. A `String` rather than an error
    /// so this type stays `Sendable`, and readable so a debug overlay can show
    /// why a peer's message was ignored.
    public private(set) var lastNote: String?

    /// Whether this player may Draw.
    ///
    /// Delegates to the frozen predicate on the state this session already
    /// holds. There is exactly one definition of a complete board and it is not
    /// here.
    public var canDraw: Bool { state.canDraw(against: dictionary) }

    // MARK: - Fixed for the life of the match

    public let localPlayerID: PlayerID
    public let peerPlayerID: PlayerID

    private let transport: any MatchTransport
    private let dictionary: any WordList

    /// The countdown's only source of time. Injected so a test can run a
    /// three-second countdown in no time and watch every value it passes
    /// through. Counts down from receipt — no wall-clock instant from the peer
    /// is ever sent, compared or trusted, because two devices' clocks disagree.
    private let sleepFor: @MainActor @Sendable (Duration) async throws -> Void

    // MARK: - Plumbing

    @ObservationIgnored private var hostPool: HostPool?
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    /// Draw requests this device has sent and not yet seen answered.
    ///
    /// The *wire* cannot tell the two kinds of grant apart — both read
    /// `.grant(player: me, …)` — so this counts the answers this device is owed.
    /// A grant with nothing outstanding is the opponent's draw, and becomes an
    /// obligation. Every request produces exactly one of a grant, a
    /// `.poolExhausted` or a `.rejected`, so any of the three clears one — and a
    /// request that never reached the wire clears its own.
    ///
    /// Only the inbound path guesses from this count. The host answers itself
    /// and knows which request each message it produced belongs to, so
    /// ``applyProduced(_:answering:)`` passes that answer down rather than
    /// reading this.
    @ObservationIgnored private var outstandingDrawRequests = 0

    /// - Parameters:
    ///   - transport: the wire. This session becomes the sole consumer of its
    ///     inbound stream immediately.
    ///   - peerPlayerID: the one opponent. Injected rather than read from
    ///     `peerConnectionStates` so nothing races the arrival of `.start`, and
    ///     so that stream is left free for the item that handles drop-outs.
    ///   - dictionary: what a complete board is validated against.
    ///   - sleepFor: one countdown tick. Defaults to real time.
    public init(
        transport: any MatchTransport,
        peerPlayerID: PlayerID,
        dictionary: any WordList,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.transport = transport
        self.localPlayerID = transport.localPlayerID
        self.peerPlayerID = peerPlayerID
        self.dictionary = dictionary
        self.sleepFor = sleepFor
        beginReceiving()
    }

    // MARK: - Lifecycle

    /// Starts consuming the inbound stream. Called from `init` and nowhere else.
    private func beginReceiving() {
        // Bound once. Reading `inboundMessages` twice and iterating both would
        // divide the messages between the two iterators rather than fail.
        let inbound = transport.inboundMessages
        pump = Task { @MainActor [weak self] in
            for await message in inbound {
                guard let self else { return }
                self.receive(message)
            }
        }
    }

    /// Opens the match from this device.
    ///
    /// Sends `.start` and applies the same start locally, because this device
    /// never receives its own sends — a host that waited to hear its own start
    /// message would wait forever.
    public func startMatch(seed: UInt64, startingHandSize: Int, countdownSeconds: Int) {
        // The same election that hands out the pool decides who opens. Both
        // devices calling this would each honour their own seed and countdown
        // and ignore the other's, and reach play at different moments.
        guard HostPool.host(of: localPlayerID, peerPlayerID) == localPlayerID else {
            lastNote = "only the host opens the match"
            return
        }
        send(
            .start(
                version: WireFormat.current,
                seed: seed,
                startingHandSize: startingHandSize,
                countdownSeconds: countdownSeconds
            )
        )
        applyStart(
            version: WireFormat.current,
            seed: seed,
            startingHandSize: startingHandSize,
            countdownSeconds: countdownSeconds
        )
    }

    /// Leaves the match and stops every task this session owns.
    public func leave() {
        pump?.cancel()
        countdownTask?.cancel()
        tail?.cancel()
        transport.leave()
    }

    /// A session dropped without ``leave()`` would otherwise leave its pump
    /// iterating the inbound stream and its countdown ticking for the life of
    /// the process. Safe from a nonisolated `deinit`: no other reference to
    /// these handles exists by here, and `Task.cancel()` is thread-safe.
    deinit {
        pump?.cancel()
        countdownTask?.cancel()
        tail?.cancel()
    }

    // MARK: - Player actions

    /// The Draw button.
    ///
    /// With a tile waiting this *takes* it and nothing goes on the wire —
    /// accepting the obligation is not a new request. Otherwise it asks for a
    /// round.
    ///
    /// Not gated on ``canDraw``: that predicate is the button's enabled state,
    /// and gating here would be a second, weaker copy of a check the shell
    /// already makes with the real one.
    ///
    /// - Returns: whether the press did anything.
    @discardableResult
    public func draw() -> Bool {
        guard !isFinished else { return false }
        if !pendingDrawTiles.isEmpty {
            state.hand.append(contentsOf: pendingDrawTiles)
            pendingDrawTiles = []
            return true
        }
        // An empty pool can only answer with the same broadcast again, and each
        // one clears a credit on the device that did not ask. Taking a waiting
        // tile above is never suppressed: accepting an obligation is how the
        // board reopens, latch or no latch.
        guard !poolIsExhausted else { return false }
        outstandingDrawRequests += 1
        request(.drawRequest(player: localPlayerID))
        return true
    }

    /// Returns one tile to the pool for three others.
    ///
    /// The tile stays in the rack until the grant lands, so a refusal needs no
    /// rollback.
    ///
    /// - Returns: whether the request was made.
    @discardableResult
    public func swap(_ tile: Tile) -> Bool {
        guard !isFinished, pendingDrawTiles.isEmpty else { return false }
        guard state.hand.contains(where: { $0.id == tile.id }) else { return false }
        request(.swapRequest(player: localPlayerID, returning: tile))
        return true
    }

    /// Moves a tile from the rack onto the board.
    ///
    /// - Throws: ``BoardActionError/drawPending`` while a tile is waiting to be
    ///   taken, or ``BoardActionError/placementFailed(_:)`` if the rules refuse.
    ///   State is unchanged either way.
    public func place(tileID: UUID, at coord: Coord) throws(BoardActionError) {
        // A finished match freezes the board for good; the caller's remedy is
        // the same either way, so it reuses the one refusal this type has.
        guard !isFinished, pendingDrawTiles.isEmpty else { throw BoardActionError.drawPending }
        do {
            try state.place(tileID: tileID, at: coord)
        } catch {
            throw BoardActionError.placementFailed(String(describing: error))
        }
    }

    /// Returns a placed tile to the rack. No-op on an empty cell.
    ///
    /// - Throws: ``BoardActionError/drawPending`` while a tile is waiting.
    public func recall(from coord: Coord) throws(BoardActionError) {
        guard !isFinished, pendingDrawTiles.isEmpty else { throw BoardActionError.drawPending }
        state.recall(from: coord)
    }

    // MARK: - Inbound

    /// Applies one message from the peer. Synchronous, so arrival order is
    /// preserved into the serial chain.
    ///
    /// Nothing here traps: every value in it came off the wire.
    private func receive(_ message: MatchMessage) {
        guard !isFinished else { return }
        switch message {

        case let .start(version, seed, startingHandSize, countdownSeconds):
            applyStart(
                version: version,
                seed: seed,
                startingHandSize: startingHandSize,
                countdownSeconds: countdownSeconds
            )

        case .drawRequest, .swapRequest:
            // Only the host answers these, and only once play has begun.
            // Answered during the countdown, a peer could drain the pool before
            // the first move and hold this board frozen behind obligations; on a
            // guest the submission finds no pool and allocates a chain task to
            // do nothing.
            // ponytail: nothing caps peer submissions in flight — the transport
            // buffers unboundedly by contract — add a cap when a real link
            // shows the buffer is the limit that bites.
            guard hostPool != nil, state.status == .playing else { break }
            submitToHost(message)

        case let .grant(player, tiles):
            // The host is the sole authority for the three cases below: it mints
            // them and applies its own half from `handle`'s return value, so one
            // arriving here is a modified peer minting tiles into the host's
            // rack, desyncing it from the pool, or latching exhaustion.
            guard hostPool == nil, player == localPlayerID else { break }
            applyGrant(tiles, requestedByLocal: clearOneOutstandingDraw())

        case let .swapGrant(player, tiles, returned):
            guard hostPool == nil, player == localPlayerID else { break }
            applySwapGrant(tiles: tiles, returned: returned)

        case .poolExhausted:
            // A latch, not an end. A grant that arrives after this one — the
            // transport may reorder — is still applied above.
            guard hostPool == nil else { break }
            poolIsExhausted = true
            clearOneOutstandingDraw()

        case let .win(player, _):
            // A device declares its own win. One naming this device as the
            // winner of the peer's own message is a modified peer, not a result.
            guard player == peerPlayerID else { break }
            state.status = .finished(winner: peerPlayerID)

        case let .resign(player):
            // Only the peer can resign to this device, so the winner is this
            // device. `.resign(player: localPlayerID)` off the wire would
            // otherwise hand the match to the peer.
            guard player == peerPlayerID else { break }
            state.status = .finished(winner: localPlayerID)

        case let .rejected(reason):
            applyRejection(reason, answeredADraw: reason != .notEnoughTilesToSwap)
        }
    }

    /// Enters the countdown and, if this device is host, takes the pool.
    ///
    /// A second start is ignored rather than trusted: two countdowns racing
    /// would fight over `status`.
    private func applyStart(version: Int, seed: UInt64, startingHandSize: Int, countdownSeconds: Int) {
        guard !hasStarted else { return }
        guard version == WireFormat.current else {
            lastNote = "unsupported wire version \(version)"
            return
        }
        guard peerPlayerID != localPlayerID else {
            lastNote = "a match needs two different players"
            return
        }
        hasStarted = true
        // Negative or absurd values came off the wire; clamp rather than trap.
        // The ceiling is the whole pool: no deal can hand out more tiles than
        // the match contains.
        self.startingHandSize = min(max(0, startingHandSize), LetterDistribution.totalTiles)
        // ponytail: the opening deal of `startingHandSize` tiles is a later
        // item — HostPool has no deal API — upgrade when that API exists.

        if HostPool.host(of: localPlayerID, peerPlayerID) == localPlayerID {
            hostPool = HostPool(
                players: (localPlayerID, peerPlayerID),
                pool: Pool.standard(seed: seed),
                seed: seed,
                transport: transport
            )
        }
        // Clamped at both ends: one `.start` carrying a huge value off the wire
        // would otherwise park this session in `.countdown` for the rest of the
        // process. Ten seconds is the ceiling — longer than any lobby needs and
        // short enough that a wedged session recovers on its own.
        beginCountdown(seconds: min(max(0, countdownSeconds), 10))
    }

    /// Counts down one second at a time from *now*, not towards an instant the
    /// peer named.
    private func beginCountdown(seconds: Int) {
        countdownTask?.cancel()
        state.status = seconds > 0 ? .countdown(secondsRemaining: seconds) : .playing
        guard seconds > 0 else { return }

        countdownTask = Task { @MainActor [weak self] in
            var remaining = seconds
            while remaining > 0 {
                guard let self else { return }
                do {
                    try await self.sleepFor(.seconds(1))
                } catch {
                    return  // cancelled
                }
                remaining -= 1
                self.state.status = remaining > 0
                    ? .countdown(secondsRemaining: remaining)
                    : .playing
            }
        }
    }

    /// Takes a granted tile, or holds it behind the obligation.
    ///
    /// A grant this device asked for goes straight to the rack. One it did not
    /// means the opponent drew, so this device owes a tile for the same event
    /// and the board freezes until the player presses Draw. The caller says
    /// which: on the host it answered a request it can name, and only the wire
    /// has to fall back on the outstanding-request count.
    private func applyGrant(_ tiles: [Tile], requestedByLocal: Bool) {
        // A duplicated grant is peer input: taking it twice would double a tile
        // into the rack and leave the two devices disagreeing about the pool.
        var held = Set(state.hand.map(\.id))
        held.formUnion(pendingDrawTiles.map(\.id))
        held.formUnion(state.board.placementList.map(\.tile.id))
        let fresh = tiles.filter { !held.contains($0.id) }
        guard !fresh.isEmpty else { return }

        if requestedByLocal {
            state.hand.append(contentsOf: fresh)
        } else {
            pendingDrawTiles.append(contentsOf: fresh)
        }
    }

    /// Notes a refusal, and closes the request it answered.
    ///
    /// A refusal that answered a *swap* must not spend a draw credit: the count
    /// would drop low and the opponent's next grant would be taken for this
    /// device's own, so the board would never freeze.
    private func applyRejection(_ reason: RejectionReason, answeredADraw: Bool) {
        lastNote = "refused: \(reason)"
        guard answeredADraw else { return }
        clearOneOutstandingDraw()
    }

    /// A tile this device does not hold cannot leave its rack: the payload came
    /// off the wire, so the whole grant is dropped rather than half applied.
    private func applySwapGrant(tiles: [Tile], returned: Tile) {
        guard let index = state.hand.firstIndex(where: { $0.id == returned.id }) else {
            lastNote = "grant returned a tile this device does not hold"
            return
        }
        state.hand.remove(at: index)
        state.hand.append(contentsOf: tiles)
    }

    @discardableResult
    private func clearOneOutstandingDraw() -> Bool {
        guard outstandingDrawRequests > 0 else { return false }
        outstandingDrawRequests -= 1
        return true
    }

    private var isFinished: Bool {
        if case .finished = state.status { return true }
        return false
    }

    // MARK: - Outbound

    /// Routes one of this device's own requests.
    ///
    /// The host answers itself: its own request never goes on the wire, because
    /// it would be answering a message it can never receive.
    private func request(_ message: MatchMessage) {
        if hostPool == nil {
            send(message)
        } else {
            submitToHost(message)
        }
    }

    /// **The only call site of ``HostPool/handle(_:)``.**
    ///
    /// `handle` suspends while it sends and carries a precondition that it is
    /// called from one place at a time; ``enqueue(_:)`` is what makes that true.
    /// Adding a second call site anywhere lets a later request's
    /// `.poolExhausted` overtake an earlier grant on the wire, which nothing
    /// will fail on.
    private func submitToHost(_ message: MatchMessage) {
        enqueue { [weak self] in
            guard let self, let hostPool = self.hostPool else { return }
            let produced = await hostPool.handle(message)
            self.applyProduced(produced, answering: message)
        }
    }

    /// Applies the half of an authoritative pool movement that belongs to this
    /// device. The grant addressed to the host never travels, so this — not the
    /// inbound stream — is where the host gets its own tile.
    ///
    /// `request` is the message these answer, so which device asked and which
    /// kind of request it was are both known exactly here. Nothing on this path
    /// has to guess from the outstanding-request count the way the wire does.
    private func applyProduced(_ produced: [MatchMessage], answering request: MatchMessage) {
        let requestedByLocal = Self.requester(of: request) == localPlayerID
        let wasDrawRequest: Bool
        if case .drawRequest = request { wasDrawRequest = true } else { wasDrawRequest = false }

        for message in produced {
            switch message {
            case let .grant(player, tiles) where player == localPlayerID:
                // Closed, not consulted: a peer-initiated grant landing while
                // this device has a Draw outstanding is still an obligation.
                if requestedByLocal { clearOneOutstandingDraw() }
                applyGrant(tiles, requestedByLocal: requestedByLocal)
            case let .swapGrant(player, tiles, returned) where player == localPlayerID:
                applySwapGrant(tiles: tiles, returned: returned)
            case .poolExhausted:
                poolIsExhausted = true
                // The broadcast names no requester; only the device that asked
                // is owed an answer by it.
                if requestedByLocal { clearOneOutstandingDraw() }
            case let .rejected(reason) where requestedByLocal:
                applyRejection(reason, answeredADraw: wasDrawRequest)
            default:
                break
            }
        }
    }

    private func send(_ message: MatchMessage) {
        enqueue { [weak self] in
            guard let self else { return }
            do {
                try await self.transport.send(message, delivery: .reliable)
            } catch {
                // A send that fails means the peer is gone; the connection-state
                // stream reports that authoritatively and this is not the place.
                // But a request that never left is owed no answer, so the credit
                // it opened must not outlive it and take the opponent's next
                // grant for this device's own.
                if case .drawRequest = message { self.clearOneOutstandingDraw() }
            }
        }
    }

    /// Runs `work` after everything enqueued before it, and before everything
    /// enqueued after.
    ///
    /// `tail` is read and written synchronously on the main actor, so the order
    /// callers enqueue in is the order the work runs in, with no lock and no
    /// queue type. One `HostPool.handle` is in flight at a time as a
    /// consequence.
    private func enqueue(_ work: @escaping @Sendable @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            // `await previous?.value` does not propagate cancellation, so this
            // is where a cancelled chain actually stops.
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    private static func requester(of message: MatchMessage) -> PlayerID? {
        switch message {
        case let .drawRequest(player): return player
        case let .swapRequest(player, _): return player
        default: return nil
        }
    }
}
