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

/// Where the one remote peer is.
///
/// A session-level surface, not a `MatchStatus`: the frozen `MatchStatus` has
/// no terminal case without a winner, and a peer that drops out must never be
/// turned into one. A match this ends is over with nobody named.
public enum PeerPresence: Sendable, Equatable {
    /// The peer is here. The only state in which anything is sent.
    case present
    /// The peer has dropped and may come back until `deadline`, which the shell
    /// shows as a banner and a countdown. The board is locked and nothing is
    /// sent meanwhile, so a peer that returns finds the match untouched.
    case reconnecting(deadline: Date)
    /// The peer did not come back. The match is over and no winner is named.
    case gone
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
///
/// ## When the peer goes
///
/// ``peerPresence`` freezes the session rather than ending it: the board locks,
/// nothing reaches the wire, and no game state moves, so a peer that comes back
/// inside the deadline finds the match exactly where it was. A peer that does
/// not ends the match with **no winner** — ``isMatchOver`` turns true while
/// ``winner`` stays `nil`. Only an explicit `.win` or `.resign` ever names one.
///
/// One exception, and only for those two messages: a `.win` or `.resign` that
/// *arrives* while frozen is applied — see ``receive(_:)`` — because the peer
/// legitimately sent it while it was still here and the two streams are a race.
/// Nothing else moves. Nothing is sent while frozen either: this device's own
/// terminal message caught by the freeze is remembered and put on the wire only
/// once the peer is back and the session is no longer frozen.
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

    /// Where the peer is. Everything that locks the board while the peer is
    /// away, and the deadline the shell counts down to, reads from here.
    public private(set) var peerPresence: PeerPresence = .present

    /// The winner's board as it was sent, straight off the wire.
    ///
    /// Set from the `.win` message and by this device's own ``claimWin()``,
    /// `nil` for a resignation and until a match ends. Kept as the list rather
    /// than a `Board` because it is peer input: building a board from it can
    /// fail on a duplicate coordinate, and the end screen — not this type — is
    /// where that decision belongs.
    public private(set) var winningPlacements: [Placement]?

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

    /// Whether this match is over, however it ended.
    ///
    /// Two ways in: somebody won or resigned, or the peer never came back.
    /// `state.status` alone cannot answer this — it has no terminal case
    /// without a winner — so a lost peer leaves the status where it stood and
    /// is reported here. Nothing is sent and no game state moves either way.
    public var isMatchOver: Bool { isFinished || peerPresence == .gone }

    /// Who won, or `nil` if nobody did.
    ///
    /// `nil` while the match is live *and* after a peer simply vanished: a
    /// dropped peer never hands anyone a win.
    public var winner: PlayerID? {
        guard case let .finished(winner) = state.status else { return nil }
        return winner
    }

    /// How long a dropped peer has to come back.
    ///
    /// Public so the shell can size its banner, and so a test can name the same
    /// number the session does.
    public static let reconnectGraceSeconds = 30

    // MARK: - Fixed for the life of the match

    public let localPlayerID: PlayerID
    public let peerPlayerID: PlayerID

    private let transport: any MatchTransport
    private let dictionary: any WordList

    /// The session's only source of elapsed time: the countdown, and the wait
    /// for a dropped peer. Injected so a test can run a three-second countdown
    /// in no time and watch every value it passes through, and expire a
    /// thirty-second reconnect window without waiting thirty seconds. Counts
    /// down from receipt — no wall-clock instant from the peer is ever sent,
    /// compared or trusted, because two devices' clocks disagree.
    private let sleepFor: @MainActor @Sendable (Duration) async throws -> Void

    // MARK: - Plumbing

    @ObservationIgnored private var hostPool: HostPool?
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var presencePump: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    /// The opening deal has not happened yet on this device.
    ///
    /// On the host it stops a second deal — a peer returning restarts the
    /// countdown, and that would hand out two hands. On the guest it is half of
    /// how an opening grant is told from a peer's draw; see
    /// ``takeOpeningDeal(_:)``.
    @ObservationIgnored private var awaitingOpeningDeal = false

    /// The countdown the freeze interrupted, held so a peer that comes back
    /// resumes from the second it stopped on rather than from the top.
    @ObservationIgnored private var heldCountdownSeconds: Int?

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

    /// This device's own `.win`/`.resign` was caught by the freeze and still
    /// owes the peer an outcome.
    ///
    /// Without it that message is lost for good: ``peerDropped()`` sees a
    /// finished match and goes straight to `.gone`, so the `!isFrozen` half of
    /// the exemption in ``blockedByLock(_:)`` never fires again, and a peer that
    /// reconnects never learns the match ended. `.finished` is terminal on both
    /// devices, so no later message can put that right — this device shows an
    /// end screen while the peer plays on alone. ``peerReturned()`` flushes it
    /// after unfreezing, so a frozen session still sends nothing.
    ///
    /// One flag is enough for one message: `claimWin()`/`resign()` both
    /// `guard !isLocked` and settle the match synchronously, so a second
    /// terminal message can never be enqueued, and `winner` cannot change once
    /// this is set. The message itself is rebuilt from `winner` and
    /// ``winningPlacements`` rather than stored — see ``peerReturned()``.
    ///
    /// ponytail: a stored `MatchMessage?` reads better, but adding a field that
    /// size to this class detonates the Match suite with a `swift_task_dealloc`
    /// "freed pointer was not the last allocation" abort inside `peerDropped()`'s
    /// reconnect task — a toolchain fault, reproducible on an otherwise unused
    /// property and independent of this fix. Store the message when that lands.
    @ObservationIgnored private var owesTerminalMessage = false

    /// - Parameters:
    ///   - transport: the wire. This session becomes the sole consumer of its
    ///     inbound stream immediately.
    ///   - peerPlayerID: the one opponent. Injected rather than read from
    ///     `peerConnectionStates` so nothing races the arrival of `.start`;
    ///     that stream is consumed here only to learn when this player leaves
    ///     and comes back, and a state naming anyone else is ignored.
    ///   - dictionary: what a complete board is validated against.
    ///   - sleepFor: one countdown tick, and the reconnect window. Defaults to
    ///     real time.
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

    /// Starts consuming both transport streams. Called from `init` and nowhere
    /// else.
    ///
    /// One task per stream, and each stream bound to a `let` exactly once:
    /// reading either property twice and iterating both would divide its
    /// elements between the two iterators rather than fail, and the symptom is
    /// a message that never arrives.
    private func beginReceiving() {
        let inbound = transport.inboundMessages
        pump = Task { @MainActor [weak self] in
            for await message in inbound {
                guard let self else { return }
                self.receive(message)
            }
        }
        let connections = transport.peerConnectionStates
        presencePump = Task { @MainActor [weak self] in
            for await connection in connections {
                guard let self else { return }
                self.apply(connection)
            }
        }
    }

    /// Applies one connection-state change for the one peer.
    ///
    /// A state naming anybody else is not about this match's opponent — two
    /// players per match — and is ignored rather than trusted.
    private func apply(_ connection: PeerConnectionState) {
        switch connection {
        case let .connected(player):
            guard player == peerPlayerID else { return }
            peerReturned()
        case let .disconnected(player):
            guard player == peerPlayerID else { return }
            peerDropped()
        }
    }

    /// Freezes the session and starts the wait for the peer to come back.
    ///
    /// Nothing about the game moves here. No winner is declared — a dropped
    /// peer is not a forfeit, and the only two messages that name a winner are
    /// `.win` and `.resign`.
    private func peerDropped() {
        guard peerPresence == .present else { return }
        // A countdown that kept ticking through the freeze would move `status`,
        // which is game state, and could reach `.playing` on a match nobody is
        // playing. Cancelled here and resumed from the same second if the peer
        // comes back.
        countdownTask?.cancel()
        if case let .countdown(secondsRemaining) = state.status, secondsRemaining > 0 {
            heldCountdownSeconds = secondsRemaining
        }

        guard !isFinished else {
            // The match already has a winner, so there is nothing to wait for
            // and a reconnecting banner over the end screen would be a lie.
            peerPresence = .gone
            return
        }

        // A `Date` for the shell to count down to. The wait itself is timed by
        // the injected clock below, never by comparing this against `Date()`:
        // it is a display value, and the clock is the seam a test drives.
        peerPresence = .reconnecting(
            deadline: Date().addingTimeInterval(TimeInterval(Self.reconnectGraceSeconds))
        )
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            // The closure, not `self`: holding the session across the whole
            // window would keep a dropped session alive for it.
            guard let sleepFor = self?.sleepFor else { return }
            do {
                try await sleepFor(.seconds(Self.reconnectGraceSeconds))
            } catch {
                return  // cancelled
            }
            // Re-checked after the suspension: an injected clock need not
            // observe cancellation, and a peer that came back must not have the
            // match ended out from under it.
            guard !Task.isCancelled else { return }
            self?.peerIsGone()
        }
    }

    /// The deadline passed. The match is over and nobody won.
    private func peerIsGone() {
        guard case .reconnecting = peerPresence else { return }
        peerPresence = .gone
        // Over is over, so `receive` discards everything from here on: against a
        // real stream, which never finishes, this task would go on decoding and
        // dropping for the life of the session. The presence pump stays — a peer
        // can still come back, and may still be owed a terminal message.
        pump?.cancel()
    }

    /// The peer came back inside the deadline. Everything is where it was.
    ///
    /// `.gone` is terminal for a live match, so a late `.connected` cannot
    /// restart one that ended with nobody named. `FakeTransport` cannot deliver
    /// one — its `leave()` finishes both streams — but a real match reports a
    /// peer reconnecting.
    ///
    /// A match that finished here while the peer was on its way out is the one
    /// case a return does anything with, and it is not a resumption: `isFinished`
    /// keeps ``isMatchOver`` true and every entry point shut, so nothing goes
    /// back into play. It is the only chance to hand the returning peer the
    /// outcome it never heard.
    private func peerReturned() {
        if isFinished {
            guard owesTerminalMessage, let outcome = winner else { return }
            owesTerminalMessage = false
            // Unfrozen first, so the flush is not a frozen session sending: the
            // peer really is back, and only `isFinished` locks the session now.
            peerPresence = .present
            // Rebuilt, not replayed: `finish()` recorded the same placements
            // `claimWin()` sent, and a resignation carries nothing but its
            // sender, so this is the message that was blocked.
            send(
                outcome == localPlayerID
                    ? .win(player: localPlayerID, placements: winningPlacements ?? [])
                    : .resign(player: localPlayerID)
            )
            return
        }
        guard case .reconnecting = peerPresence else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        peerPresence = .present
        guard let seconds = heldCountdownSeconds else {
            // A freeze that landed on the moment of the deal bailed out of it and
            // re-armed it. The countdown is already spent, so this is the only
            // place left to deal: without it both racks stay empty for the rest
            // of the match and nothing says why.
            dealOpeningHands()
            return
        }
        heldCountdownSeconds = nil
        beginCountdown(seconds: seconds)
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
        guard !isLocked else { return }
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
        // Before the streams go: `tail?.cancel()` reaches the last task enqueued
        // and not its predecessors, one of which can still be parked inside
        // `transport.send`. The lock is what actually stops those, and it is read
        // when each piece of work runs rather than when it was enqueued.
        peerPresence = .gone
        // A `.connected` already buffered when the pump is cancelled can still
        // be delivered, and the flush would put a message on the wire from a
        // device that has left.
        owesTerminalMessage = false
        pump?.cancel()
        presencePump?.cancel()
        countdownTask?.cancel()
        reconnectTask?.cancel()
        tail?.cancel()
        transport.leave()
    }

    /// A session dropped without ``leave()`` would otherwise leave its pump
    /// iterating the inbound stream and its countdown ticking for the life of
    /// the process. Safe from a nonisolated `deinit`: no other reference to
    /// these handles exists by here, and `Task.cancel()` is thread-safe.
    deinit {
        pump?.cancel()
        presencePump?.cancel()
        countdownTask?.cancel()
        reconnectTask?.cancel()
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
        guard !isLocked else { return false }
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
        guard !isLocked, pendingDrawTiles.isEmpty else { return false }
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
        // A finished match freezes the board for good, and so does a peer that
        // is not here; the caller's remedy is the same in all three cases — put
        // the tile down and read `hasPendingDraw`, `isMatchOver` and
        // `peerPresence` to find out which — so this reuses the one refusal
        // this type has rather than growing a case per reason.
        guard !isLocked, pendingDrawTiles.isEmpty else { throw BoardActionError.drawPending }
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
        guard !isLocked, pendingDrawTiles.isEmpty else { throw BoardActionError.drawPending }
        state.recall(from: coord)
    }

    /// Declares this device the winner and tells the peer, carrying the board
    /// behind the claim.
    ///
    /// Applied locally as well as sent, because a device never receives its own
    /// sends: a claimer that waited to hear its own win would wait forever.
    ///
    /// Not gated on ``canDraw``. That predicate is the Win button's enabled
    /// state, and checking it here would be a second, weaker copy of a check
    /// the shell already makes with the real one — the same call the host makes
    /// for `draw()`. The host verifies nothing it receives; that is a later
    /// item.
    ///
    /// - Returns: whether the claim was made.
    @discardableResult
    public func claimWin() -> Bool {
        guard !isLocked else { return false }
        let placements = state.board.placementList
        send(.win(player: localPlayerID, placements: placements))
        finish(winner: localPlayerID, placements: placements)
        return true
    }

    /// Gives the match up. The peer wins.
    ///
    /// Applied locally as well as sent, for the same reason ``claimWin()`` is.
    ///
    /// - Returns: whether the resignation was made.
    @discardableResult
    public func resign() -> Bool {
        guard !isLocked else { return false }
        send(.resign(player: localPlayerID))
        finish(winner: peerPlayerID, placements: nil)
        return true
    }

    // MARK: - Inbound

    /// Applies one message from the peer. Synchronous, so arrival order is
    /// preserved into the serial chain.
    ///
    /// Nothing here traps: every value in it came off the wire.
    private func receive(_ message: MatchMessage) {
        // Over is over, however it ended: nothing may move a settled match.
        guard !isMatchOver else { return }
        // Frozen, the two streams are a race — messages the peer sent before it
        // dropped can still be buffered behind the disconnect. Anything that
        // would move the game is dropped so the match stands still, but a `.win`
        // or a `.resign` is honoured: the peer legitimately sent it while it was
        // here, and taking it whichever stream wins makes the outcome the same
        // on both devices instead of dependent on the race.
        guard !isFrozen || Self.endsTheMatch(message) else { return }
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
            // `nil`: only ``applyGrant(_:requestedByLocal:)`` can tell whether
            // this is the opening deal, and a credit must not be spent on one.
            applyGrant(tiles, requestedByLocal: nil)

        case let .swapGrant(player, tiles, returned):
            guard hostPool == nil, player == localPlayerID else { break }
            applySwapGrant(tiles: tiles, returned: returned)

        case .poolExhausted:
            // A latch, not an end. A grant that arrives after this one — the
            // transport may reorder — is still applied above.
            guard hostPool == nil else { break }
            poolIsExhausted = true
            clearOneOutstandingDraw()

        case let .win(player, placements):
            // A device declares its own win. One naming this device as the
            // winner of the peer's own message is a modified peer, not a result.
            guard player == peerPlayerID else { break }
            // The placements are kept exactly as they arrived. Nothing here
            // trusts them enough to build a board out of: that can fail, and
            // this is a decode path.
            finish(winner: peerPlayerID, placements: placements)

        case let .resign(player):
            // Only the peer can resign to this device, so the winner is this
            // device. `.resign(player: localPlayerID)` off the wire would
            // otherwise hand the match to the peer.
            guard player == peerPlayerID else { break }
            finish(winner: localPlayerID, placements: nil)

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
        // The ceiling is *half* the pool, not all of it: the deal is one draw of
        // `handSize * 2`, so anything above half leaves that draw short and
        // ``HostPool/deal(handSize:)`` hands out nothing at all — a silently
        // dealless match instead of a clamped one.
        self.startingHandSize = min(max(0, startingHandSize), LetterDistribution.totalTiles / 2)
        self.awaitingOpeningDeal = self.startingHandSize > 0

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
        guard seconds > 0 else {
            // Enqueued ahead of the flip — the send itself runs later, off the
            // chain, so this orders the deal before any request this device will
            // answer, not before its own `.playing`.
            dealOpeningHands()
            state.status = .playing
            return
        }
        state.status = .countdown(secondsRemaining: seconds)

        countdownTask = Task { @MainActor [weak self] in
            var remaining = seconds
            while remaining > 0 {
                guard let self else { return }
                do {
                    try await self.sleepFor(.seconds(1))
                } catch {
                    return  // cancelled
                }
                // Re-checked after the suspension: an injected clock need not
                // observe cancellation, and a countdown ticking on through a
                // freeze or past the end of the match would move `status` —
                // game state — and could put a settled match back into play.
                guard !Task.isCancelled, !self.isLocked else { return }
                remaining -= 1
                // Enqueued ahead of the flip, as in the zero-second path.
                if remaining == 0 { self.dealOpeningHands() }
                self.state.status = remaining > 0
                    ? .countdown(secondsRemaining: remaining)
                    : .playing
            }
        }
    }

    /// Deals both opening hands, once, from the host's pool.
    ///
    /// Only the host has a pool to deal from; the guest's hand arrives as a
    /// `.grant` and lands through ``takeOpeningDeal(_:)``. Nothing happens on
    /// the guest, and nothing happens twice.
    private func dealOpeningHands() {
        guard awaitingOpeningDeal, let hostPool else { return }
        // Closed synchronously, before the suspension: a peer returning restarts
        // the countdown, and a second deal would hand out two hands.
        awaitingOpeningDeal = false
        let handSize = startingHandSize
        enqueue { [weak self] in
            guard let self else { return }
            // A frozen or finished session sends nothing and moves nothing, the
            // same bar `blockedByLock` holds every other piece of outbound work
            // to. Re-armed rather than dropped, because a freeze can lift:
            // ``peerReturned()`` deals then, and without this both racks stay
            // empty for a match that goes on to be played.
            guard !self.isLocked else {
                self.awaitingOpeningDeal = true
                return
            }
            let produced = await hostPool.deal(handSize: handSize)
            for case let .grant(player, tiles) in produced where player == self.localPlayerID {
                // The grant addressed to the host never travels — this is where
                // the host's own opening hand lands, as `applyProduced` does for
                // a draw.
                self.applyGrant(tiles, requestedByLocal: true)
            }
        }
    }

    /// Whether this grant is the opening deal, and closes the deal if it is.
    ///
    /// ponytail: the phase carries what the wire cannot say, and it is a
    /// heuristic. Wire v1 has one `.grant` case for both an opening deal and a
    /// draw, and adding a second is a format break, so two triggers stand in for
    /// the case that does not exist. Both can misfire:
    ///
    /// - **the phase trigger** takes the *first* grant arriving in `.countdown`
    ///   as the deal, at any hand size. Sound only because the host gates
    ///   `.drawRequest` on `state.status == .playing` and ``dealOpeningHands()``
    ///   enqueues strictly before that flip, so on `.reliable` delivery the deal
    ///   is always the first grant. Reorder or drop that one grant — a lossy
    ///   link, a transport that does not keep order — and a one-tile round is
    ///   read as a whole opening hand instead.
    /// - **the count trigger** covers a zero-second countdown, which leaves no
    ///   phase to read, by taking a first grant of exactly `startingHandSize`
    ///   tiles. At `startingHandSize == 1` that is any round at all.
    ///
    /// `awaitingOpeningDeal` bounds either misfire to one grant, and the tiles
    /// are real tiles from the real pool — the cost is one round taken into hand
    /// instead of held behind the Draw button. Upgrade to the distinct `deal`
    /// case at the pending wire v2 amendment, and delete all of this.
    private func takeOpeningDeal(_ tiles: [Tile]) -> Bool {
        guard awaitingOpeningDeal else { return false }
        if case .countdown = state.status {
            awaitingOpeningDeal = false
            return true
        }
        guard tiles.count == startingHandSize else { return false }
        awaitingOpeningDeal = false
        return true
    }

    /// Takes a granted tile, or holds it behind the obligation.
    ///
    /// A grant this device asked for goes straight to the rack. One it did not
    /// means the opponent drew, so this device owes a tile for the same event
    /// and the board freezes until the player presses Draw. The caller says
    /// which: on the host it answered a request it can name, and only the wire
    /// has to fall back on the outstanding-request count — pass `nil` for that,
    /// and one credit is spent here on every grant that is not the opening deal.
    private func applyGrant(_ tiles: [Tile], requestedByLocal: Bool?) {
        // First, and whatever else is done with the grant: the deal is closed by
        // the message that carried it, and it answers no request. A credit spent
        // on it would leave the real answer uncredited, and the player owing a
        // second press for a round they already took.
        let isOpeningDeal = takeOpeningDeal(tiles)
        let requested = requestedByLocal ?? (isOpeningDeal ? false : clearOneOutstandingDraw())

        // A duplicated grant is peer input: taking it twice would double a tile
        // into the rack and leave the two devices disagreeing about the pool.
        var held = Set(state.hand.map(\.id))
        held.formUnion(pendingDrawTiles.map(\.id))
        held.formUnion(state.board.placementList.map(\.tile.id))
        let fresh = tiles.filter { !held.contains($0.id) }
        guard !fresh.isEmpty else { return }

        if requested || isOpeningDeal {
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

    /// Ends the match, and stops anything still counting.
    ///
    /// The countdown is the reason this is a method rather than an assignment:
    /// a tick still to come would set `.playing` and move a finished match back
    /// into play.
    private func finish(winner: PlayerID, placements: [Placement]?) {
        countdownTask?.cancel()
        heldCountdownSeconds = nil
        reconnectTask?.cancel()
        // The window that cancel just closed will never resolve, so a presence
        // left at `.reconnecting` puts a banner and a countdown to a deadline
        // nothing reaches over an end screen — the same lie `peerDropped()`
        // guards against in the opposite ordering.
        if case .reconnecting = peerPresence { peerPresence = .gone }
        state.status = .finished(winner: winner)
        winningPlacements = placements
        // Nothing may move a settled match, so every further inbound message is
        // decoded and discarded. The presence pump stays: a peer coming back is
        // how an unsent terminal message still gets out.
        pump?.cancel()
    }

    private var isFinished: Bool {
        if case .finished = state.status { return true }
        return false
    }

    /// The peer is not here, so nothing may be sent and nothing may move.
    private var isFrozen: Bool { peerPresence != .present }

    /// The board is shut: the match ended, or the peer is away.
    private var isLocked: Bool { isFinished || isFrozen }

    /// The two messages that name a winner, and the only two a frozen session
    /// still honours.
    private static func endsTheMatch(_ message: MatchMessage) -> Bool {
        switch message {
        case .win, .resign: return true
        default: return false
        }
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
            guard let self, !self.blockedByLock(message) else { return }
            guard let hostPool = self.hostPool else { return }
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

    /// Whether the lock stops this piece of outbound work, checked at the
    /// moment it would run rather than at the moment it was enqueued.
    ///
    /// The chain is the reason: work enqueued while the match was still live
    /// sits behind its predecessors and would otherwise reach the wire — or the
    /// pool — after the peer had gone or the match had ended. This is the check
    /// that makes "a frozen session sends nothing" and "`.finished` is terminal"
    /// true of messages already in flight, not only of presses made after.
    ///
    /// The one exception is the terminal message this device's own end came
    /// from: `claimWin()`/`resign()` enqueue the send and then settle the match
    /// synchronously, so blocking on `isFinished` alone would swallow the very
    /// message that has to reach the peer. Both run on the main actor with no
    /// suspension between them, so nothing else can have settled the match in
    /// between: a `.win` or `.resign` still on the chain of a finished, unfrozen
    /// session is always this device's own. A frozen session still sends
    /// nothing, terminal message or not — it is remembered in
    /// `owesTerminalMessage` and flushed by ``peerReturned()``.
    private func blockedByLock(_ message: MatchMessage) -> Bool {
        if !isFrozen, Self.endsTheMatch(message) { return false }
        guard isLocked else { return false }
        // Frozen, with this device's own terminal message still on the chain —
        // the only way a terminal message reaches here, since `claimWin()` and
        // `resign()` are its only sources and both are shut once the match is
        // settled. Remembered rather than dropped: without this the peer that
        // comes back never learns the match is over, and the two devices are
        // left disagreeing for good.
        if Self.endsTheMatch(message) { owesTerminalMessage = true }
        // A request that never left is owed no answer, so the credit it opened
        // must not outlive it: left standing, it would take the opponent's next
        // grant for this device's own and the board would never freeze again.
        if case let .drawRequest(player) = message, player == localPlayerID {
            clearOneOutstandingDraw()
        }
        return true
    }

    private func send(_ message: MatchMessage) {
        enqueue { [weak self] in
            guard let self, !self.blockedByLock(message) else { return }
            do {
                try await self.transport.send(message, delivery: .reliable)
            } catch {
                // A send that fails means the peer is gone; the connection-state
                // stream reports that authoritatively and this is not the place.
                // But a request that never left is owed no answer, so the credit
                // it opened must not outlive it and take the opponent's next
                // grant for this device's own.
                if case .drawRequest = message { self.clearOneOutstandingDraw() }
                // The flush cleared `owesTerminalMessage` before this ran, so a
                // throw here loses the rebuilt terminal with nothing left to
                // re-arm it. Re-armed, the next return flushes it again.
                if Self.endsTheMatch(message) { self.owesTerminalMessage = true }
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
