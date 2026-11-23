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
/// no terminal case without a winner, and a peer that has only dropped out
/// must not be turned into one while it may still come back.
public enum PeerPresence: Sendable, Equatable {
    /// The peer is here. The only state in which anything is sent.
    case present
    /// The peer has dropped and may come back until `deadline`, which the shell
    /// shows as a banner and a countdown. The board is locked and nothing is
    /// sent meanwhile, so a peer that returns finds the match untouched.
    case reconnecting(deadline: Date)
    /// The peer did not come back. In a two-player match that is a forfeit:
    /// the player who stayed is the winner.
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
/// not has **forfeited**: the player who stayed is the ``winner`` and
/// ``endedByDisconnect`` says why. A device that was itself out of touch for
/// the whole deadline takes the loss instead, so no ordering gives two winners.
///
/// One exception, and only for those two messages: a `.win` or `.resign` that
/// *arrives* while frozen is applied — see ``receive(_:)`` — because the peer
/// legitimately sent it while it was still here and the two streams are a race.
/// Nothing else moves. Nothing is sent while frozen either: this device's own
/// terminal message caught by the freeze is remembered and put on the wire only
/// once the peer is back and the session is no longer frozen.
@MainActor
@Observable
public final class MatchSession: AppActivityListener {

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

    /// Where every peer is. Everything that locks the board while a peer is
    /// away, and the deadline the shell counts down to, reads from here.
    ///
    /// Absent means present: a six-player roster would otherwise need six
    /// entries written before the first message ever arrives, and an empty
    /// dictionary is the state every match opens in. Read it through
    /// ``presence(of:)`` rather than subscripting it.
    public private(set) var peerPresences: [PlayerID: PeerPresence] = [:]

    /// Where one player is. `.present` for anyone this session has heard
    /// nothing about, ``localPlayerID`` included.
    public func presence(of player: PlayerID) -> PeerPresence {
        peerPresences[player] ?? .present
    }

    /// The match's presence as one value: how far the *worst-placed* peer is.
    ///
    /// What a banner and a lock actually want to know — somebody is away, or
    /// somebody has left — never which of six it was. `.reconnecting` wins over
    /// `.gone` because a match with anyone still inside their window is frozen,
    /// not over. Derived, so it costs no observed storage.
    public var peerPresence: PeerPresence {
        for player in peerPlayerIDs {
            let presence = presence(of: player)
            if case .reconnecting = presence { return presence }
        }
        return peerPlayerIDs.contains { presence(of: $0) == .gone } ? .gone : .present
    }

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

    // MARK: - Options state, and why it is stored the way it is
    //
    // ⚠️ This class is at a hard limit of the Swift 6.3.3 toolchain: adding one
    // more *observed* stored property to `MatchSession` makes MatchTests abort
    // with `swift_task_dealloc` — "freed pointer was not the last allocation" —
    // while the reconnect task is suspended in `peerDropped()`. Bisected: a bare
    // `var probe: Int = 0` is enough to trigger it, and marking any one existing
    // observed property `@ObservationIgnored` to keep the net count unchanged
    // makes it pass again. It is a layout threshold, not a bug in this logic.
    //
    // Update 2026-11-23: the cause was the inline default `sleepFor` closure,
    // not this class's layout. See ``realSleep``. The storage below was left as
    // it is because it works.
    //
    // So the two values below are stored `@ObservationIgnored` and read back
    // through computed properties that first touch a property that *is*
    // observed. Reading `session.options` in a SwiftUI body therefore still
    // registers a dependency and still updates — the observation is real, only
    // the storage moved. Each pairs with a property assigned on its own code
    // path in `applyStart`: `startingHandSize` on the accepting path, `lastNote`
    // on the refusing one.
    //
    // Before adding observed state here, re-run `swift test --package-path
    // Tests/MatchTests`. A green engine suite does not cover this.

    /// The last count read back from ``HostPool/pool`` or received as
    /// `.poolCount`, or `nil` before either. `@ObservationIgnored` for the reason above; observers
    /// are driven through ``poolRemaining`` and ``setPoolRemaining(_:)``, which
    /// register and fire on that computed key path directly rather than
    /// borrowing another property's code path.
    @ObservationIgnored private var storedPoolRemaining: Int?

    /// How many tiles the host's pool still holds, or `nil` until the number is
    /// known.
    ///
    /// Never a tally of grants. On the pool's device it is read back from
    /// ``HostPool/pool`` itself after every movement of it. A guest knows it
    /// too: the host broadcasts `.poolCount` after the deal, every round and
    /// every swap, and the guest keeps the smallest count it has received —
    /// `nil` only before the first one lands.
    public var poolRemaining: Int? {
        access(keyPath: \.poolRemaining)
        return storedPoolRemaining
    }

    private func setPoolRemaining(_ count: Int?) {
        withMutation(keyPath: \.poolRemaining) { storedPoolRemaining = count }
    }

    /// Re-reads the count from the pool. Called after every `HostPool` call
    /// that can move it, from the main actor, inside the same enqueued step.
    private func refreshPoolRemaining(from hostPool: HostPool) async {
        setPoolRemaining(await hostPool.pool.count)
    }

    @ObservationIgnored private var storedOptions: MatchOptions = .standard

    /// The rules this match is playing under, validated on arrival.
    ///
    /// `.standard` until a start lands, so a session read before the match opens
    /// reports today's shipped behavior rather than nothing.
    public var options: MatchOptions {
        _ = startingHandSize  // registers the observation; see the note above
        return storedOptions
    }

    @ObservationIgnored private var storedOptionsRefusal: OptionsRefusal?

    /// Set when a start was refused because the two devices do not hold the same
    /// word list. The match never opens, and this says why.
    ///
    /// A mismatch cannot be played through: each device validates its own board,
    /// so the two would disagree about legal words for the whole match. Silently
    /// adopting the host's id while holding different content is the one outcome
    /// worse than refusing.
    public var optionsRefusal: OptionsRefusal? {
        _ = lastNote  // registers the observation; see the note above
        return storedOptionsRefusal
    }

    /// Why a start was refused before the match opened.
    public enum OptionsRefusal: Equatable, Sendable {
        /// The host's list and this device's list are not the same content.
        case dictionaryMismatch(expected: String, received: String)
        /// The host's start speaks another wire version: one side is out of date.
        case unsupportedVersion(received: Int)
    }

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
    /// Three ways in: somebody won, resigned or forfeited by staying out of
    /// touch; a pause ran its whole limit and the match was voided; or this
    /// device left. `state.status` alone cannot answer this — it has no
    /// terminal case without a winner — so a void leaves the status where it
    /// stood and is reported here.
    public var isMatchOver: Bool { isFinished || isVoided || presentPlayers.count < 2 }

    /// Who won, or `nil` if nobody did.
    ///
    /// `nil` while the match is live and after a void. A player out of touch
    /// for ``reconnectGraceSeconds`` forfeits, so the other player is named
    /// here: see ``endedByDisconnect``.
    public var winner: PlayerID? {
        guard case let .finished(winner) = state.status else { return nil }
        return winner
    }

    /// The match ended because a player stayed out of touch for
    /// ``reconnectGraceSeconds``, not because somebody won or resigned.
    /// ``winner`` is the player who stayed.
    public var endedByDisconnect: Bool { time.endedByDisconnect }

    /// A pause ran for ``pauseLimitSeconds``, so the match is over with no
    /// winner and nothing for anybody's record.
    ///
    /// Observed by hand, like ``isPaused``: the shell watches ``isMatchOver``
    /// and this is one of the ways in.
    public var isVoided: Bool {
        access(keyPath: \.isVoided)
        return time.voided
    }

    /// When the pause in force runs out, or `nil` when no agreed pause is in
    /// force. A local pause, the solo kind, has none.
    ///
    /// ponytail: each device stamps this from its own clock when it learns of
    /// the pause, so the two agree to within the delivery of one message. A
    /// guest that hears of the pause late shows a clock late by that much, and
    /// is still voided on time by the host. Carry the seconds left in
    /// `pauseState` if that ever shows.
    public var pauseDeadline: Date? {
        access(keyPath: \.pauseDeadline)
        return time.pauseDeadline
    }

    /// How long both boards stay covered after a peer comes back mid-match.
    ///
    /// Computed, not a `static let`: a stored static added to this class walks
    /// MatchTests into the `swift_task_dealloc` abort `docs/amendment-wire-v2.md`
    /// records against adding stored properties here. Bisected, not guessed —
    /// the same diff with this one line stored aborts and passes without it.
    ///
    /// ponytail: each device counts its own three seconds from its own
    /// `.connected`, not from a shared clock. `SelfJoinGate` is what keeps
    /// those two moments together — it holds the returning device's
    /// `.connected` until that device sees its own presence join, which is the
    /// same server fan-out that tells its peer. Aligned to the fan-out, so
    /// tens of milliseconds; without the gate it was a full round trip and
    /// showed on device as one player counting a second ahead. A `.resume` on
    /// the wire would make it exact, and is a wire-version bump.
    public static var resumeCountdownSeconds: Int { 3 }

    /// How long a player may be out of touch before forfeiting the match,
    /// paused or not.
    ///
    /// Public so the shell can size its banner, and so a test can name the same
    /// number the session does.
    public static let reconnectGraceSeconds = 30

    /// How long an agreed pause may last before the match is voided. Computed
    /// for the reason ``resumeCountdownSeconds`` is.
    public static var pauseLimitSeconds: Int { 300 }

    /// How much longer than the limit a guest waits before voiding on its own.
    /// The host decides; this only covers a `matchVoided` that never arrived.
    public static var pauseVoidMarginSeconds: Int { 5 }

    /// How long after coming back on screen a dead link may still be reported
    /// and counted as dead since the app went away. Realtime notices a dead
    /// socket one to two heartbeats (10 s each) after the fact.
    static var linkProbeSeconds: Int { 25 }

    // MARK: - Fixed for the life of the match

    public let localPlayerID: PlayerID

    /// Every player in this match, sorted ascending by `rawValue`.
    ///
    /// Sorted is load-bearing, not tidiness: the host election is the first
    /// element, so every device computes the same host from the same list with
    /// no message about it.
    public let roster: [PlayerID]

    /// The roster without this device.
    public var peerPlayerIDs: [PlayerID] { roster.filter { $0 != localPlayerID } }

    /// The players who have not left. A match is over when fewer than two are
    /// left, whoever went and however they went.
    private var presentPlayers: [PlayerID] {
        roster.filter { presence(of: $0) != .gone }
    }

    /// Whether a `PlayerID` off the wire is somebody *else* in this match.
    ///
    /// Everything inbound that names a player is gated on this. A message
    /// naming this device, or naming nobody on the roster, is a modified peer
    /// rather than a move.
    private func isPeer(_ player: PlayerID) -> Bool {
        player != localPlayerID && roster.contains(player)
    }

    private let transport: any MatchTransport

    /// The list this session validates against.
    ///
    /// Not `let`: once options arrive, it is wrapped in a
    /// ``MinimumLengthWordList`` so the host's minimum applies everywhere the
    /// base list already did — `canDraw` included — rather than at one call site
    /// somebody has to remember.
    ///
    /// `@ObservationIgnored` is load-bearing, not tidiness: a stored `var` here
    /// would be a third observed property and cross the toolchain threshold
    /// described above. Nothing observes a private field, so opting out is free.
    @ObservationIgnored private var dictionary: any WordList

    /// The session's only source of elapsed time: the countdown, and the wait
    /// for a dropped peer. Injected so a test can run a three-second countdown
    /// in no time and watch every value it passes through, and expire a
    /// thirty-second reconnect window without waiting thirty seconds. Counts
    /// down from receipt — no wall-clock instant from the peer is ever sent,
    /// compared or trusted, because two devices' clocks disagree.
    private let sleepFor: @MainActor @Sendable (Duration) async throws -> Void

    /// The other half of that same clock: what time it is *on it*.
    ///
    /// Injected together with ``sleepFor`` and never separately, because the
    /// reconnect window is armed from both at once — the `Date` the banner
    /// counts down to is `now() + seconds` and the wait is `sleepFor(seconds)`.
    /// Reading the wall clock here while the wait ran on an injected one is
    /// what used to make a partial spend unobservable: a test could run a
    /// thirty-second window to its end in 300ms and the deadline would still
    /// say thirty seconds were owed, so a resume that topped the budget back up
    /// looked exactly like one that banked it. One clock, both halves.
    private let now: @Sendable () -> Date

    // MARK: - Plumbing

    @ObservationIgnored private var hostPool: HostPool?
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var presencePump: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    /// Whether this match is the half-length game. Set by the device that opens
    /// the match, or by `gameLength` off the wire before the start. Only the
    /// device that builds the pool ever reads it.
    @ObservationIgnored private var halfGame = false

    // MARK: - Pause

    /// Who wants the match paused right now, this device included. A wish list,
    /// never the state: see ``isPaused``.
    @ObservationIgnored private var pauseWanted: [PlayerID] = []
    @ObservationIgnored private var storedPaused = false
    @ObservationIgnored private var storedWasPaused = false
    /// This device has voted at least once, so its vote is worth re-sending
    /// after a reconnect.
    @ObservationIgnored private var hasVotedOnPause = false

    /// The match is paused: nobody may draw, swap, move a tile or claim a win.
    ///
    /// Online, the device that runs the pool decides this and everyone else
    /// takes its word, so two devices cannot disagree. It turns on when every
    /// player wants a pause and off when none does; in between it keeps its
    /// value, which is what makes pausing and resuming both need everyone.
    ///
    /// A pause shuts this device's own moves and nothing else. Tiles the host
    /// has already taken out of the pool still arrive and still land.
    public var isPaused: Bool {
        access(keyPath: \.isPaused)
        return storedPaused
    }

    /// The players who want the match paused. Online screens read it to show a
    /// request the other player has made and has not been answered yet.
    public var playersWantingPause: [PlayerID] {
        access(keyPath: \.playersWantingPause)
        return pauseWanted
    }

    /// The match was paused at some point, so its length is not a playing time.
    public var wasPaused: Bool { storedWasPaused }

    /// Says whether this player wants the match paused. Asking to pause and
    /// agreeing to one are the same vote, and so are cancelling and resuming.
    ///
    /// Nothing pauses here. The vote goes to the device that runs the pool,
    /// and a peer that never answers (a 1.0 build cannot) leaves the match
    /// running with the vote free to take back.
    public func votePause(_ wanted: Bool) {
        guard hasStarted, !isMatchOver else { return }
        hasVotedOnPause = true
        send(.pauseVote(player: localPlayerID, wanted: wanted))
        recordPauseVote(localPlayerID, wanted: wanted)
    }

    /// Pauses or resumes this session alone, with nothing sent. For a match
    /// with no second person to ask: solo play pauses both of its sessions
    /// this way, at once.
    public func setPausedLocally(_ paused: Bool) {
        guard hasStarted, !isMatchOver else { return }
        setPaused(paused)
    }

    private func recordPauseVote(_ player: PlayerID, wanted: Bool) {
        withMutation(keyPath: \.playersWantingPause) {
            pauseWanted.removeAll { $0 == player }
            if wanted { pauseWanted.append(player) }
        }
        // Only the device that runs the pool decides.
        guard hostPool != nil else { return }
        // ponytail: a player leaving does not re-run this, so with three or
        // more players a vote that became unanimous by a departure waits for
        // the next vote. Two-player matches end on a departure instead.
        let present = presentPlayers
        let wanting = present.filter(pauseWanted.contains)
        let wasPaused = storedPaused
        if wanting.count == present.count {
            setPaused(true)
        } else if wanting.isEmpty {
            setPaused(false)
        }
        pauseLimitFollows(wasPaused)
        // A fact, so sending it again after every vote changes nothing.
        send(.pauseState(paused: storedPaused))
    }

    private func setPaused(_ paused: Bool) {
        guard paused != storedPaused else { return }
        withMutation(keyPath: \.isPaused) { storedPaused = paused }
        if paused { storedWasPaused = true }
    }

    /// Starts the limit when an agreed pause begins and stops it on a resume.
    ///
    /// Called by the two places an agreed pause changes, never from
    /// ``setPaused(_:)``: a local pause, the solo kind, has no limit.
    private func pauseLimitFollows(_ wasPaused: Bool) {
        guard storedPaused != wasPaused else { return }
        withMutation(keyPath: \.pauseDeadline) {
            time.pauseDeadline = storedPaused
                ? now().addingTimeInterval(TimeInterval(Self.pauseLimitSeconds)) : nil
        }
        armPauseLimit()
    }

    /// Waits out what is left of the pause, then voids the match if it is still
    /// paused. Always counted from ``pauseDeadline``, so arming it again after
    /// a reconnect cannot move the end.
    ///
    /// The device that runs the pool decides. Every other device waits
    /// ``pauseVoidMarginSeconds`` longer and acts only if it never heard.
    private func armPauseLimit() {
        time.pauseTask?.cancel()
        time.pauseTask = nil
        guard let deadline = time.pauseDeadline else { return }
        let left = max(0, Int(deadline.timeIntervalSince(now()).rounded(.up)))
        let wait = left + (hostPool == nil ? Self.pauseVoidMarginSeconds : 0)
        time.pauseTask = Task { @MainActor [weak self] in
            guard let sleepFor = self?.sleepFor else { return }
            do {
                try await sleepFor(.seconds(wait))
            } catch {
                return  // cancelled
            }
            guard !Task.isCancelled, let self else { return }
            self.time.pauseTask = nil
            // Believed only when the wall clock agrees. A sleep that came back
            // early, as an instant test clock does, must not void a pause that
            // has barely begun.
            // ponytail: a wall clock set back by more than the margin during a
            // pause leaves that pause with no limit until the next reconnect or
            // resume. Loop on the remainder if that is ever seen.
            guard deadline.timeIntervalSince(self.now()) <= TimeInterval(Self.pauseVoidMarginSeconds)
            else { return }
            // Somebody out of touch at the limit is the forfeit rule's to
            // settle, and this device being the one out of touch is too. If
            // the match is still paused when everyone is back, the return arms
            // this again with nothing left to wait.
            guard self.storedPaused, !self.isMatchOver, !self.isFrozen,
                  !self.isAway, !self.time.linkDown else { return }
            self.voidMatch()
        }
    }

    /// Arms the limit again if its wait was spent while somebody was away.
    private func rearmSpentPauseLimit() {
        if storedPaused, time.pauseTask == nil, !isMatchOver { armPauseLimit() }
    }

    /// Ends the match with no winner. See ``isVoided``.
    private func voidMatch() {
        guard !isMatchOver else { return }
        let somebodyIsAway = isFrozen
        stopEveryClock()
        withMutation(keyPath: \.isVoided) { time.voided = true }
        // Only the device that runs the pool says so. Everyone still shows
        // everyone their board, as after a win.
        if hostPool != nil { send(.matchVoided) }
        guard !somebodyIsAway else { return }
        send(.finalBoard(player: localPlayerID, placements: state.board.placementList))
    }

    /// The board is shut to this player's own moves.
    private var refusesMoves: Bool { isLocked || storedPaused }

    // MARK: - Final boards

    @ObservationIgnored private var storedFinalBoards: [PlayerID: [Placement]] = [:]

    /// Each other player's board, as that player sent it once the match was
    /// over.
    ///
    /// Peer input, kept exactly as it arrived for the reason
    /// ``winningPlacements`` is: the end screen decides whether a board can be
    /// built from it. Empty until a board arrives, and for good against a 1.0
    /// build, which never sends one.
    public var peerFinalBoards: [PlayerID: [Placement]] {
        access(keyPath: \.peerFinalBoards)
        return storedFinalBoards
    }

    /// The opening deal has not happened yet on this device.
    ///
    /// Host-side only: it stops a second deal, because a peer returning restarts
    /// the countdown and that would hand out two hands. A guest has no pool, so
    /// it reads this nowhere — the deal simply arrives as a `.grant`.
    @ObservationIgnored private var awaitingOpeningDeal = false

    /// The countdown the freeze interrupted, held so a peer that comes back
    /// resumes from the second it stopped on rather than from the top.
    @ObservationIgnored private var heldCountdownSeconds: Int?

    /// Draw requests this device has sent and not yet seen answered.
    ///
    /// Nothing reads this to work out what an inbound message *means* — the
    /// wire says so: `.grant` answers this device's own request, `.obligation`
    /// is the tile it owes for somebody else's. This is only the in-flight
    /// count, and ``draw()`` refuses a second request while it is non-zero.
    ///
    /// Every request produces exactly one of a `.grant`, a `.poolExhausted`
    /// naming this device or a `.rejected`, so any of the three clears one —
    /// and a request that never reached the wire clears its own.
    ///
    /// A request that reaches a host which cannot serve it yet — frozen, or
    /// still counting back in — is held there in ``heldDrawRequests`` and
    /// answered when play resumes, so the credit it opened is closed, when the
    /// host runs this build or later. A 1.0 host drops the request, and the
    /// credit then stands until this device's own return resets it.
    @ObservationIgnored private var outstandingDrawRequests = 0

    /// Host only: players whose draw request arrived while this device could
    /// not serve it, answered by ``answerHeldDrawRequests()`` when the board is
    /// live again.
    ///
    /// The two devices do not freeze together. One that steps out of the app
    /// and back freezes and counts back in alone, while the other plays on and
    /// can press Draw. Dropping that request left the asker waiting on an answer
    /// that never came, with Draw refusing every later press.
    ///
    /// One per player: an honest peer has one request in flight at a time, and
    /// a second entry would let a modified one queue rounds against the pool.
    @ObservationIgnored private var heldDrawRequests: [PlayerID] = []

    /// Whether the board has been live at least once. A request sent before
    /// that is early, not late: it is dropped, as it always was, so nobody
    /// takes tiles out of the pool ahead of the opening deal.
    @ObservationIgnored private var playHasBegun = false

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

    /// Seconds of reconnect grace not yet spent *on screen*.
    ///
    /// Non-nil exactly while somebody is inside their window. It is what makes
    /// the window survivable across a screen lock: the budget is banked when the
    /// app goes away and re-armed from the same number when it comes back, so a
    /// suspended minute costs the peer nothing and a peer that never returns
    /// still runs out of it. An `Int` rather than a `Duration` — see the
    /// toolchain note on ``owesTerminalMessage``.
    @ObservationIgnored private var reconnectSecondsOwed: Int?

    /// The app is off screen.
    ///
    /// Nothing arms a reconnect window here. A suspended process gives the peer
    /// no chance to come back, and both clocks this session could use — `Date()`
    /// and `ContinuousClock` behind `Task.sleep` — keep running through the
    /// suspension, so an un-paused window is spent entirely on time in which
    /// nothing could possibly have happened.
    @ObservationIgnored private var isAway = false

    /// ``leave()`` has run. A `Bool` beside ``isAway``, for the same toolchain
    /// reason — see the note on ``owesTerminalMessage``.
    ///
    /// ponytail: defence-in-depth, not load-bearing — every reachable path is
    /// already covered by `peerDropped`'s `.present` guard and `peerReturned`'s
    /// `.reconnecting` guard, so deleting this flag alone changes no behaviour
    /// and no single mutation kills it. `PresenceHandoffTests`'
    /// "A state forwarded after leave() cannot bring a left match back" is the
    /// real pin. Delete the flag if either absorbing guard is ever made
    /// unconditional — at that point this one stops being redundant, or the
    /// test stops passing, and you want to notice which.
    @ObservationIgnored private var hasLeft = false

    /// Everything the forfeit and pause-limit rules remember, behind one
    /// pointer.
    @ObservationIgnored private let time = Timekeeping()

    /// The only sleep a shipping build ever uses, and the default for every
    /// `sleepFor` parameter in the app.
    ///
    /// It is a named value on purpose. Do not write this closure inline as a
    /// default argument of a public function: Swift 6.3.3 then compiles a copy
    /// of it into every test file that relies on the default, the copies record
    /// different async context sizes (144 and 160 bytes), and the linker may
    /// pair one copy's code with another copy's size. A cancelled or finished
    /// sleep then aborts with `swift_task_dealloc`, "freed pointer was not the
    /// last allocation". Which copy wins moves with any unrelated edit, which is
    /// what the older "one more stored property" notes in this file were seeing.
    /// Found 2026-11-23 with `nm -m` on the test objects (the closure and its
    /// `Tu` record are both `weak private external` in several of them).
    nonisolated public static let realSleep: @MainActor @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

    /// - Parameters:
    ///   - transport: the wire. This session becomes the sole consumer of its
    ///     inbound stream immediately.
    ///   - roster: every player in the match, this device included, sorted
    ///     ascending by `rawValue`. Injected rather than read from
    ///     `peerConnectionStates` so nothing races the arrival of `.start`;
    ///     that stream is consumed here only to learn when a player leaves and
    ///     comes back, and a state naming anyone off the roster is ignored.
    ///   - dictionary: what a complete board is validated against.
    ///   - dictionaryHash: the content hash of `dictionary`, per
    ///     ``canonicalWordListHash(_:)``. Declared rather than derived: `any
    ///     WordList` exposes only `contains`, so this type cannot enumerate the
    ///     list it was handed. The caller that loaded the list is the one that
    ///     knows which it is — for the bundled list that is
    ///     ``MatchOptions/standardDictionaryHash``, which is the default.
    ///   - sleepFor: one countdown tick, and the reconnect window. Defaults to
    ///     real time.
    ///   - observesPeerConnections: whether this session subscribes to
    ///     `peerConnectionStates` itself. False where something upstream is
    ///     already the stream's one consumer and forwards each state in through
    ///     ``receive(peerConnection:)`` — `OnlineMatch`, whose lobby pump took
    ///     that stream first. `peerConnectionStates` allows exactly one
    ///     consumer per endpoint, so a session that subscribed anyway would be
    ///     opening a second iterator on a stream the lobby pump had already
    ///     finished, and no drop would ever reach it. Not stored: it is read
    ///     once, here, and `MatchSession` is at the toolchain's stored-property
    ///     limit.
    public init(
        transport: any MatchTransport,
        roster: [PlayerID],
        dictionary: any WordList,
        dictionaryHash: String = MatchOptions.standardDictionaryHash,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = MatchSession.realSleep,
        now: @escaping @Sendable () -> Date = Date.init,
        observesPeerConnections: Bool = true
    ) {
        // Trapping, not refusing: none of this came off the wire. A caller that
        // built a roster this way has a bug, and a session that quietly played
        // on with it would desync every device in the match.
        precondition(
            MatchLimits.players.contains(roster.count),
            "a match holds \(MatchLimits.players.lowerBound)...\(MatchLimits.players.upperBound) players"
        )
        precondition(Set(roster).count == roster.count, "a match needs distinct players")
        precondition(
            roster == roster.sorted(by: { $0.rawValue < $1.rawValue }),
            "the roster travels sorted, so every device elects the same host"
        )
        precondition(
            roster.contains(transport.localPlayerID),
            "the roster must contain the device playing it"
        )
        self.transport = transport
        self.localPlayerID = transport.localPlayerID
        self.roster = roster
        self.dictionary = dictionary
        self.localDictionaryHash = dictionaryHash
        self.sleepFor = sleepFor
        self.now = now
        beginReceiving(observingPeerConnections: observesPeerConnections)
    }

    /// The two-player case: the only lobby this release ships.
    ///
    /// Sorts the pair into the order every device computes the host from, so a
    /// caller never has to know that the roster travels sorted.
    public convenience init(
        transport: any MatchTransport,
        peerPlayerID: PlayerID,
        dictionary: any WordList,
        dictionaryHash: String = MatchOptions.standardDictionaryHash,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = MatchSession.realSleep,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            transport: transport,
            roster: [transport.localPlayerID, peerPlayerID]
                .sorted { $0.rawValue < $1.rawValue },
            dictionary: dictionary,
            dictionaryHash: dictionaryHash,
            sleepFor: sleepFor,
            now: now
        )
    }

    /// This device's word-list hash, compared against the host's on start.
    private let localDictionaryHash: String

    // MARK: - Lifecycle

    /// Starts consuming both transport streams. Called from `init` and nowhere
    /// else.
    ///
    /// One task per stream, and each stream bound to a `let` exactly once:
    /// reading either property twice and iterating both would divide its
    /// elements between the two iterators rather than fail, and the symptom is
    /// a message that never arrives.
    private func beginReceiving(observingPeerConnections: Bool) {
        let inbound = transport.inboundMessages
        pump = Task { @MainActor [weak self] in
            for await message in inbound {
                guard let self else { return }
                self.receive(message)
            }
        }
        guard observingPeerConnections else { return }
        let connections = transport.peerConnectionStates
        presencePump = Task { @MainActor [weak self] in
            for await connection in connections {
                guard let self else { return }
                self.apply(connection)
            }
        }
    }

    /// Hands this session one connection-state change from whoever owns the
    /// stream.
    ///
    /// The other half of `observesPeerConnections: false`: a session that does
    /// not subscribe learns about drops and returns only through here. Applied
    /// by exactly the same code a self-subscribed session runs, so the two
    /// ownership arrangements cannot drift.
    ///
    /// Refused after ``leave()``. A self-subscribed session stops hearing when
    /// its own pump is cancelled; a forwarded one is fed by somebody else's
    /// pump, which keeps running until that owner is torn down too — one line
    /// later in `OnlineOpponent.leave()`, but not zero. This is what makes
    /// "a left session takes no more presence" true by construction rather than
    /// by the two absorbing guards in `peerDropped` and `peerReturned` that
    /// happen to cover it today.
    public func receive(peerConnection: PeerConnectionState) {
        guard !hasLeft else { return }
        apply(peerConnection)
    }

    /// Applies one connection-state change for one peer.
    ///
    /// A state naming somebody off this match's roster is ignored rather than
    /// trusted. One naming this device is the transport's word on this
    /// device's own link.
    private func apply(_ connection: PeerConnectionState) {
        switch connection {
        case let .connected(player):
            if player == localPlayerID { ownLinkReturned() }
            guard isPeer(player) else { return }
            peerReturned(player)
        case let .disconnected(player):
            if player == localPlayerID { ownLinkDropped() }
            guard isPeer(player) else { return }
            peerDropped(player)
        }
    }

    // MARK: - This device out of touch

    // A dead link looks, from inside, exactly like everybody else leaving. So
    // this device also times itself: from when it went off screen or lost its
    // link, to when its link is known to work again. Out of touch for
    // ``reconnectGraceSeconds``, it takes the loss rather than the win.

    /// A stretch out of touch begins: the app left the screen, or the link
    /// went down.
    ///
    /// The app coming back does not end a stretch, because a link that died
    /// off screen is only found dead a heartbeat or two later. `linkDied`
    /// says that is what just happened: the trip and the time back on screen
    /// were one outage, and count as one. A second trip off screen with no
    /// word of a dead link is a trip of its own. Short trips do not add up,
    /// or two looks at another app during a pause, when nothing is said that
    /// could show the link alive, would forfeit the match.
    private func beginOutOfTouch(linkDied: Bool) {
        if let back = time.cameBackAt {
            let lived = now().timeIntervalSince(back) >= TimeInterval(Self.linkProbeSeconds)
            if lived || !linkDied { time.outOfTouchSince = nil }
            time.cameBackAt = nil
        }
        guard hasStarted, !isMatchOver, time.outOfTouchSince == nil else { return }
        time.outOfTouchSince = now()
    }

    private var outOfTouchTooLong: Bool {
        guard let since = time.outOfTouchSince else { return false }
        return now().timeIntervalSince(since) >= TimeInterval(Self.reconnectGraceSeconds)
    }

    /// A peer was heard, so the link works and the stretch is over.
    private func backInTouch() {
        time.outOfTouchSince = nil
        time.cameBackAt = nil
    }

    private func ownLinkDropped() {
        beginOutOfTouch(linkDied: true)
        time.linkDown = true
        time.lostLinkSincePeerSeen = true
    }

    /// The link is back, which is not yet being back in the match: the peers
    /// only reappear a moment later, and until one does this device cannot
    /// tell a peer who left from a peer it simply cannot see yet. So the
    /// stretch stays open, and ``awayPeersAreGone()`` will not take a win.
    private func ownLinkReturned() {
        let wasDown = time.linkDown
        time.linkDown = false
        // Off screen, the trip is still running: ``appCameBack()`` judges it.
        guard !isAway else { return }
        if wasDown, outOfTouchTooLong { forfeitByLosingTouch() }
        rearmSpentPauseLimit()
    }

    /// This device was the one out of touch, so it resigns. The message goes
    /// out now if anybody can hear it, and again at the next contact either
    /// way: a link can be dead for seconds before anything says so.
    private func forfeitByLosingTouch() {
        guard hasStarted, !isMatchOver else { return }
        time.endedByDisconnect = true
        send(.resign(player: localPlayerID))
        depart(localPlayerID)
        owesTerminalMessage = true
    }

    /// Freezes the session and starts the wait for the peer to come back.
    ///
    /// Nothing about the game moves here. Nobody has forfeited yet: that is
    /// ``awayPeersAreGone()``, when the window runs out.
    ///
    /// ponytail: one reconnect window covers every away peer at once, so a
    /// second drop restarts it and hands the first peer extra grace. Give each
    /// player its own task when a six-player match shows the difference
    /// matters; at two players there is only ever one window.
    private func peerDropped(_ player: PlayerID) {
        guard presence(of: player) == .present else { return }
        // A countdown that kept ticking through the freeze would move `status`,
        // which is game state, and could reach `.playing` on a match nobody is
        // playing. Cancelled here and resumed from the same second if the peer
        // comes back.
        countdownTask?.cancel()
        if case let .countdown(secondsRemaining) = state.status, secondsRemaining > 0 {
            heldCountdownSeconds = secondsRemaining
        }

        guard !isSettled else {
            // The match already ended, so there is nothing to wait for and a
            // reconnecting banner over the end screen would be a lie.
            peerPresences[player] = .gone
            return
        }
        // A pause already past its limit was voided by the device that runs
        // the pool, which then left before this device heard. Not a drop.
        // With this device's own link down it is a drop, and this device's.
        if storedPaused, !time.linkDown, let deadline = time.pauseDeadline, now() >= deadline {
            voidMatch()
            peerPresences[player] = .gone
            return
        }

        // Puts the peer in the state ``armReconnectWait(seconds:)`` looks for.
        // The deadline it stamps a line below is the real one — both the
        // banner's `Date` and the wait come from that one call, so they cannot
        // be derived from two different instants.
        peerPresences[player] = .reconnecting(deadline: now())
        armReconnectWait(seconds: Self.reconnectGraceSeconds)
    }

    /// Stamps the reconnect deadline and arms the wait for it, from one number
    /// and one instant.
    ///
    /// One clock, not two. The `Date` the shell counts down to and the
    /// `sleepFor` the window actually runs on are both derived here, in the same
    /// synchronous call: the deadline is `now + seconds` and the sleep is
    /// exactly `seconds`. Every path that pauses or resumes the window comes
    /// back through here, so the two can never drift apart by a suspension —
    /// which is precisely what they used to do.
    ///
    /// Arms nothing while the app is away; ``appCameBack()`` arms it then.
    private func armReconnectWait(seconds: Int) {
        reconnectSecondsOwed = seconds
        time.reconnectTask?.cancel()
        time.reconnectTask = nil
        let deadline = now().addingTimeInterval(TimeInterval(seconds))
        for player in roster {
            guard case .reconnecting = presence(of: player) else { continue }
            peerPresences[player] = .reconnecting(deadline: deadline)
        }
        guard !isAway else { return }
        time.reconnectTask = Task { @MainActor [weak self] in
            // The closure, not `self`: holding the session across the whole
            // window would keep a dropped session alive for it.
            guard let sleepFor = self?.sleepFor else { return }
            do {
                try await sleepFor(.seconds(seconds))
            } catch {
                return  // cancelled
            }
            // Re-checked after the suspension: an injected clock need not
            // observe cancellation, and a peer that came back must not have the
            // match ended out from under it.
            guard !Task.isCancelled else { return }
            self?.reconnectSecondsOwed = nil
            self?.awayPeersAreGone()
        }
    }

    // MARK: - The app leaving the screen

    /// The app's scene phase changed.
    ///
    /// `nonisolated`, and it hops rather than assuming: this is called from
    /// ``AppActivity``, which is driven by a UIKit notification, and a
    /// `@MainActor` callback UIKit ever delivers off the main queue traps.
    /// Still `nonisolated` — see above; a `@MainActor` conformance traps. What
    /// it does *not* do any more is always hop: a hop is a queued block, and the
    /// suspension that follows a lock can land before it runs. The window is
    /// then banked from a deadline already in the past, which banks zero and
    /// ends the match on resume — the exact failure this item exists to fix.
    /// On the main thread, which is where UIKit posts from, the bank is taken
    /// synchronously, inside the notification, before anything can suspend.
    public nonisolated func appActivityChanged(to phase: AppActivity.Phase) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                switch phase {
                case .away: appWentAway()
                case .active: appCameBack()
                }
            }
            return
        }
        Task { @MainActor [weak self] in
            switch phase {
            case .away: self?.appWentAway()
            case .active: self?.appCameBack()
            }
        }
    }

    /// Seconds still owed to a reconnecting peer, or nil where no window is
    /// running. Read by value so a test can assert the budget only ever
    /// *shrinks* across a lock/unlock loop — a window topped back up by any
    /// amount hangs a dead match for as long as somebody keeps locking, and that
    /// is a comparison, not a timing bound.
    public var reconnectSecondsOwedForTesting: Int? { reconnectSecondsOwed }

    /// Banks whatever is left of the reconnect window.
    ///
    /// Only the part of it that ran on screen is spent. The stamped deadline is
    /// the authority for how much that was, because on screen it and the wait
    /// were armed from the same instant.
    public func appWentAway() {
        guard !isAway else { return }
        isAway = true
        beginOutOfTouch(linkDied: false)
        guard reconnectSecondsOwed != nil else { return }
        time.reconnectTask?.cancel()
        time.reconnectTask = nil
        let furthest = peerPlayerIDs.compactMap { player -> Date? in
            guard case let .reconnecting(deadline) = presence(of: player) else { return nil }
            return deadline
        }.max()
        guard let furthest else { return }
        // DOWN, never up. Ceiling refunds every spend shorter than a second, so
        // a lock/unlock loop with a sub-second stretch on screen holds the
        // budget at thirty for ever while the transport's exact 35s still
        // finishes the streams — a frozen board behind a banner nothing
        // resolves. Flooring over-charges by under a second, which is the safe
        // direction: the grace stays honest and still runs out.
        reconnectSecondsOwed = max(0, Int(furthest.timeIntervalSince(now()).rounded(.down)))
    }

    /// Resumes the window with what was left of it, re-stamped so the banner
    /// and the wait start from this instant rather than the one before the
    /// suspension.
    ///
    /// Not a reset: a peer that is genuinely gone keeps whatever it had already
    /// spent, so a lock/unlock loop cannot hold a dead match open for ever.
    public func appCameBack() {
        guard isAway else { return }
        isAway = false
        // Off screen for the whole window is out of touch for the whole
        // window, whatever became of the link meanwhile.
        if outOfTouchTooLong {
            forfeitByLosingTouch()
            return
        }
        if !time.linkDown, time.outOfTouchSince != nil { time.cameBackAt = now() }
        rearmSpentPauseLimit()
        guard let owed = reconnectSecondsOwed else { return }
        armReconnectWait(seconds: owed)
    }

    /// The window ran out. Whoever was out of touch for it forfeits.
    ///
    /// That is this device when its own link is the one that went down: every
    /// peer "left" only because nothing could be heard. A link that came back
    /// since does not change that until a peer has been seen again, because
    /// the peer may have waited out its own window and gone. Otherwise each
    /// peer still away has left for good, exactly as if it had resigned, and
    /// the last player standing wins.
    private func awayPeersAreGone() {
        reconnectSecondsOwed = nil
        guard !time.linkDown, !time.lostLinkSincePeerSeen else {
            forfeitByLosingTouch()
            return
        }
        for player in roster {
            guard case .reconnecting = presence(of: player) else { continue }
            depart(player)
        }
        guard isFinished else { return }
        time.endedByDisconnect = true
        // Nobody was there to hear it. A player who comes back is told then:
        // see the finished branch of ``peerReturned(_:)``.
        owesTerminalMessage = true
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
    private func peerReturned(_ player: PlayerID) {
        // Seeing a peer is the proof that this device is back in the match.
        if !time.linkDown {
            time.lostLinkSincePeerSeen = false
            if !isAway { backInTouch() }
        }
        if isFinished {
            guard owesTerminalMessage, let outcome = winner else { return }
            owesTerminalMessage = false
            // Unfrozen first, so the flush is not a frozen session sending: the
            // peer really is back, and only `isFinished` locks the session now.
            peerPresences[player] = .present
            // Rebuilt, not replayed: `finish()` recorded the same placements
            // `claimWin()` sent, and a resignation carries nothing but its
            // sender, so this is the message that was blocked.
            send(
                outcome == localPlayerID
                    ? .win(player: localPlayerID, placements: winningPlacements ?? [])
                    : .resign(player: localPlayerID)
            )
            send(.finalBoard(player: localPlayerID, placements: state.board.placementList))
            return
        }
        guard case .reconnecting = presence(of: player) else { return }
        peerPresences[player] = .present
        // A credit still standing here may never be answered: a 1.0 host drops
        // every request that reaches it frozen. Left at 1 it latches Draw shut
        // for the rest of the match, so it is reset.
        // ponytail: a host on this build holds that request and answers it on
        // resume, so a player who presses Draw again right after a return can
        // get two rounds for one intended draw. Tiles are still conserved. Keep
        // the credit across the return once no 1.0 host is left in the field.
        outstandingDrawRequests = 0
        // Another peer still away keeps the match frozen, and its window keeps
        // running: resuming the countdown now would move game state nobody is
        // playing through.
        guard !isFrozen else { return }
        // Anything about a pause said while somebody was away may not have
        // arrived, in either direction. Both kinds are facts, so saying them
        // again is harmless, and it is what puts the two devices back on the
        // same answer.
        if hasVotedOnPause {
            send(.pauseVote(player: localPlayerID, wanted: pauseWanted.contains(localPlayerID)))
        }
        if hostPool != nil, storedWasPaused {
            send(.pauseState(paused: storedPaused))
        }
        rearmSpentPauseLimit()
        time.reconnectTask?.cancel()
        time.reconnectTask = nil
        // The second gate on the same window. Cancelling the task alone would
        // leave a budget behind that `appCameBack()` would happily re-arm, and
        // a peer that is back would be waited out all over again.
        reconnectSecondsOwed = nil
        guard let seconds = heldCountdownSeconds else {
            // A freeze that landed on the moment of the deal bailed out of it and
            // re-armed it. The countdown is already spent, so this is the only
            // place left to deal: without it both racks stay empty for the rest
            // of the match and nothing says why.
            //
            // `awaitingOpeningDeal`, not the status, is what tells that case
            // apart: the deal is enqueued ahead of the flip to `.playing`, so a
            // freeze on that exact moment leaves a session that is `.playing`
            // and still owes two hands.
            guard !awaitingOpeningDeal else {
                dealOpeningHands()
                answerHeldDrawRequests()
                return
            }
            // Mid-match. The deal is long done, and what a returning peer owes
            // the two players is a moment to look at the board before it is
            // live again — not a board that snaps back under their thumbs.
            guard case .playing = state.status else { return }
            beginCountdown(seconds: Self.resumeCountdownSeconds)
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
    public func startMatch(
        seed: UInt64,
        startingHandSize: Int,
        countdownSeconds: Int,
        options: MatchOptions = .standard,
        halfGame: Bool = false
    ) {
        // Any player in the match may send the `.start` — online, that is the
        // lobby creator, which need not be `roster[0]`. The pool still goes to
        // `roster[0]` in `applyStart`, and a second start is ignored there.
        guard roster.contains(localPlayerID) else {
            lastNote = "only a player in this match opens it"
            return
        }
        guard !isLocked else { return }
        // A half pool deals a smaller hand. Clamped here, by the opener, so
        // every device reads the same hand size off `.start`.
        let startingHandSize = halfGame
            ? min(startingHandSize, LetterDistribution.halfTotalTiles / roster.count)
            : startingHandSize
        let message = MatchMessage.start(
            version: WireFormat.current,
            seed: seed,
            startingHandSize: startingHandSize,
            countdownSeconds: countdownSeconds,
            options: options,
            roster: roster
        )
        // Validated before it is sent, not after: the host is the one device
        // that can still refuse a set of settings without the match already
        // being half open on somebody else's screen.
        guard let start = message.validatedStart(for: localPlayerID) else {
            lastNote = "these match settings cannot be played"
            return
        }
        // The pool may be on the other device (`roster[0]`), so the choice has
        // to travel, and ahead of the start that builds the pool. A build that
        // drops this kind deals a full pool: a longer game, still one pool.
        // The opener's own choice always wins over one heard off the wire.
        if halfGame { send(.gameLength(half: true)) }
        self.halfGame = halfGame
        send(message)
        applyStart(start)
    }

    /// Leaves the match and stops every task this session owns.
    public func leave() {
        // Before the streams go: `tail?.cancel()` reaches the last task enqueued
        // and not its predecessors, one of which can still be parked inside
        // `transport.send`. The lock is what actually stops those, and it is read
        // when each piece of work runs rather than when it was enqueued.
        // The whole roster, not just this device: leaving ends the match here,
        // and every banner, lock and end screen reads presence to find that out.
        for player in roster { peerPresences[player] = .gone }
        // Shuts ``receive(peerConnection:)``, which is the only way presence
        // still reaches a session fed by a façade's pump: `presencePump` below
        // is nil on every session built with `observesPeerConnections: false`,
        // so cancelling it stops nothing on the path that ships.
        hasLeft = true
        // A `.connected` already buffered when a self-subscribed session's pump
        // is cancelled can still be delivered, and the flush would put a message
        // on the wire from a device that has left.
        owesTerminalMessage = false
        pump?.cancel()
        presencePump?.cancel()
        countdownTask?.cancel()
        time.reconnectTask?.cancel()
        time.pauseTask?.cancel()
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
        time.reconnectTask?.cancel()
        time.pauseTask?.cancel()
        tail?.cancel()
    }

    // MARK: - Player actions

    /// The Draw button.
    ///
    /// With a tile waiting this *takes one* and nothing goes on the wire —
    /// accepting the obligation is not a new request. Otherwise it asks for a
    /// round.
    ///
    /// One tile per press, always, however many are waiting. A player who fell
    /// six tiles behind presses six times. The button is the only place a tile
    /// enters a hand, so letting one press empty a queue of six would drop six
    /// letters into the rack at once with no way to take them one at a time and
    /// play between them — and it would hide how far behind they are behind a
    /// single tap.
    ///
    /// Not gated on ``canDraw``: that predicate is the button's enabled state,
    /// and gating here would be a second, weaker copy of a check the shell
    /// already makes with the real one.
    ///
    /// - Returns: whether the press did anything.
    @discardableResult
    public func draw() -> Bool {
        guard !refusesMoves else { return false }
        if !pendingDrawTiles.isEmpty {
            state.hand.append(pendingDrawTiles.removeFirst())
            return true
        }
        // One request at a time. The board stays complete and the hand stays
        // empty for the whole round trip, so `canDraw` — the button's own gate
        // — is still true while a request is in flight. Without this, a player
        // pressing Draw N times fast sends N `.drawRequest`s: each one drains a
        // full round from the pool all-or-nothing and hands every opponent
        // another obligation, and the N grants land together, so nothing
        // appears and then everything does.
        //
        // Below the `pendingDrawTiles` branch on purpose: taking a waiting tile
        // is local, touches no wire, and must stay unguarded, because accepting
        // an obligation is how the board reopens.
        guard outstandingDrawRequests == 0 else { return false }
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
        // The host is the authority and refuses this anyway; returning here
        // saves a round trip to be told so. A guest with a modified build still
        // hits the host's refusal, which is where the rule actually lives.
        guard options.swapEnabled else {
            lastNote = "swap is off for this match"
            return false
        }
        guard !refusesMoves, pendingDrawTiles.isEmpty else { return false }
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
        guard !storedPaused, pendingDrawTiles.isEmpty else { throw BoardActionError.drawPending }
        try lay(tileID: tileID, at: coord)
    }

    /// Lays a tile this session itself just handed over, without waiting for the
    /// rest of the obligation to be taken.
    ///
    /// The obligation is a rule about *playing*, not about a tile appearing.
    /// Draw takes one waiting tile per press, so gating this the way ``place``
    /// is gated meant a press with two tiles still queued behind it took a tile
    /// that could not be laid: the press did nothing visible, and the whole
    /// queue then arrived at once on the last one. Every press now puts its
    /// tile down where the player can see it, and ``place`` — the player's own
    /// moves — stays frozen until the queue is empty, which is where the
    /// obligation actually bites.
    ///
    /// Still refused outright by a finished match or an absent peer. Not by a
    /// pause: a pause stops the player's own moves, and a tile the host already
    /// took out of the pool still has to land on the board.
    public func lay(tileID: UUID, at coord: Coord) throws(BoardActionError) {
        guard !isLocked else { throw BoardActionError.drawPending }
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
        guard !storedPaused, pendingDrawTiles.isEmpty else { throw BoardActionError.drawPending }
        try unlay(from: coord)
    }

    /// ``recall(from:)``'s half of the same exemption: the roll-back path for a
    /// delivery that was refused part way. A delivery that could be laid must be
    /// undoable on the same terms, or half of it is stranded on the board.
    public func unlay(from coord: Coord) throws(BoardActionError) {
        guard !isLocked else { throw BoardActionError.drawPending }
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
        guard !refusesMoves else { return false }
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
        depart(localPlayerID)
        return true
    }

    /// A player left for good, by resigning here or on the wire.
    ///
    /// Only the last player standing wins. With more than two on the roster the
    /// rest play on, and this device — if it was the one that left — is shut out
    /// by ``isLocked`` rather than by an ending nobody else sees.
    private func depart(_ player: PlayerID) {
        peerPresences[player] = .gone
        let remaining = presentPlayers
        guard remaining.count == 1 else { return }
        finish(winner: remaining[0], placements: nil)
    }

    // MARK: - Inbound

    /// Applies one message from the peer. Synchronous, so arrival order is
    /// preserved into the serial chain.
    ///
    /// Nothing here traps: every value in it came off the wire.
    private func receive(_ message: MatchMessage) {
        // The one kind taken after the end, and only after it: a board read
        // while the match is still being played would be a look at the other
        // player's hand. It moves nothing, so it is not a move on a settled
        // match either.
        if case let .finalBoard(player, placements) = message {
            // The first one stands: a board is a fact, sent once.
            guard isSettled, isPeer(player), storedFinalBoards[player] == nil else { return }
            withMutation(keyPath: \.peerFinalBoards) { storedFinalBoards[player] = placements }
            return
        }
        // Over is over, however it ended: nothing may move a settled match.
        guard !isMatchOver else { return }
        // Anything heard on screen, with no word of a dead link, shows this
        // device's link works.
        if !time.linkDown {
            time.lostLinkSincePeerSeen = false
            if !isAway { backInTouch() }
        }
        // Frozen, the two streams are a race — messages the peer sent before it
        // dropped can still be buffered behind the disconnect. A request to
        // begin or move play is dropped so the match stands still. What the
        // peer already *did* is honoured: a `.win` or a `.resign` it sent while
        // it was here, and every tile the host has already taken out of the
        // pool for this device. The pool never moves back, so dropping a grant
        // here loses the tile for good.
        guard !isFrozen || Self.survivesAFreeze(message) else { return }
        switch message {

        case let .start(version, _, _, _, _, _):
            // A game length heard ahead of a start that is refused belongs to
            // that start. Kept, it would shape the pool of a later match.
            defer { if !hasStarted { halfGame = false } }
            // One gate for six checks — version, roster shape, roster
            // membership, and a deal the pool can cover. Everything past it is
            // inside its documented bounds.
            guard let start = message.validatedStart(for: localPlayerID) else {
                if version != WireFormat.current, !hasStarted { storedOptionsRefusal = .unsupportedVersion(received: version) }
                lastNote = version == WireFormat.current
                    ? "this start message cannot be played"
                    : "unsupported wire version \(version)"
                return
            }
            applyStart(start)

        case .drawRequest, .swapRequest:
            // Only the host answers these, and only once play has begun.
            // Answered during the countdown, a peer could drain the pool before
            // the first move and hold this board frozen behind obligations; on a
            // guest the submission finds no pool and allocates a chain task to
            // do nothing.
            // ponytail: nothing caps peer submissions in flight — the transport
            // buffers unboundedly by contract — add a cap when a real link
            // shows the buffer is the limit that bites.
            guard hostPool != nil else { break }
            guard !isFrozen, state.status == .playing else {
                // Held, not dropped: the asker is waiting on an answer. Only a
                // draw — a swap leaves its tile in the rack and can be pressed
                // again, and replaying one late could return a tile twice.
                if playHasBegun, case let .drawRequest(player) = message, isPeer(player),
                   !heldDrawRequests.contains(player) {
                    heldDrawRequests.append(player)
                }
                break
            }
            submitToHost(message)

        case let .grant(player, tiles):
            // The host is the sole authority for the four cases below: it mints
            // them and applies its own half from `handle`'s return value, so one
            // arriving here is a modified peer minting tiles into the host's
            // rack, desyncing it from the pool, or latching exhaustion.
            guard hostPool == nil, player == localPlayerID else { break }
            applyGrant(tiles)

        case let .obligation(player, tiles):
            guard hostPool == nil, player == localPlayerID else { break }
            applyObligation(tiles)

        case let .swapGrant(player, tiles, returned):
            guard hostPool == nil, player == localPlayerID else { break }
            applySwapGrant(tiles: tiles, returned: returned)

        case let .poolExhausted(requester):
            // A latch, not an end. A grant that arrives after this one — the
            // transport may reorder — is still applied above.
            guard hostPool == nil else { break }
            poolIsExhausted = true
            // It reaches both devices, but it answers one request. Spending a
            // credit on somebody else's refusal would reopen this device's Draw
            // gate with its own request still in flight.
            if requester == localPlayerID { clearOneOutstandingDraw() }

        case let .win(player, placements):
            // A device declares its own win. One naming this device as the
            // winner of the peer's own message is a modified peer, not a result.
            guard isPeer(player) else { break }
            // The placements are kept exactly as they arrived. Nothing here
            // trusts them enough to build a board out of: that can fail, and
            // this is a decode path.
            //
            // A win with no board behind it is the one a player takes when
            // this device was out of touch for the whole window, said on this
            // device's return.
            time.endedByDisconnect = placements.isEmpty
            finish(winner: player, placements: placements.isEmpty ? nil : placements)

        case let .resign(player):
            // Only somebody else can resign to this device.
            // `.resign(player: localPlayerID)` off the wire would otherwise let
            // a modified peer forfeit this device's match for it.
            guard isPeer(player) else { break }
            depart(player)

        case let .rejected(reason):
            // Both swap refusals answer a swap, not a draw. Counting either as a
            // draw would retire a credit the player never spent and leave them
            // one Draw short for the rest of the match.
            applyRejection(
                reason,
                answeredADraw: reason != .notEnoughTilesToSwap && reason != .swapDisabled
            )

        case let .poolCount(remaining):
            // Informational: the HUD's bag, nothing more. Exhaustion is still
            // `poolExhausted`'s to latch. A device running the pool trusts only
            // the pool; a count out of range came from a modified peer; and the
            // pool never grows, so a larger count is a reordered, stale one.
            guard hostPool == nil,
                  (0...MatchLimits.poolSize).contains(remaining) else { break }
            setPoolRemaining(min(storedPoolRemaining ?? remaining, remaining))

        case .gameLength(let half):
            // A request to the device that builds the pool, read only before
            // the pool exists.
            guard !hasStarted else { break }
            halfGame = half

        case let .pauseVote(player, wanted):
            // Somebody else's wish. This device records its own in `votePause`.
            guard hasStarted, isPeer(player) else { break }
            recordPauseVote(player, wanted: wanted)

        case let .pauseState(paused):
            // The device that runs the pool decides, and takes this from nobody,
            // exactly as it takes no `.grant`. A message does not carry its
            // sender, so that is the one check there is.
            guard hasStarted, hostPool == nil else { break }
            let wasPaused = storedPaused
            setPaused(paused)
            pauseLimitFollows(wasPaused)

        case .matchVoided:
            // From the device that runs the pool, like `pauseState`, and only
            // about a pause this device knows is in force.
            guard hasStarted, hostPool == nil, storedPaused else { break }
            voidMatch()

        case .finalBoard:
            // Taken above the guards, or not at all.
            break
        }
    }

    /// Enters the countdown and, if this device is host, takes the pool.
    ///
    /// A second start is ignored rather than trusted: two countdowns racing
    /// would fight over `status`.
    private func applyStart(_ start: MatchMessage.ValidatedStart) {
        guard !hasStarted else { return }
        // The host deals to the roster it sent. A roster that is not this
        // session's is a different match, and playing it would leave this
        // device filtering grants addressed to players it never joined with.
        guard start.roster == roster else {
            lastNote = "this start message is for a different match"
            return
        }

        // Already validated by ``MatchMessage/validatedStart(for:)``; the raw
        // values off the wire are never used again.
        let options = start.options

        // The hash gate, before anything moves. Two devices holding different
        // word lists disagree about legal words for the whole match, and the
        // symptom lands mid-play on somebody's screen as a rejected word rather
        // than as a setup error. Refuse here, where it is still explainable.
        guard options.dictionaryHash == localDictionaryHash else {
            storedOptionsRefusal = .dictionaryMismatch(
                expected: options.dictionaryHash,
                received: localDictionaryHash
            )
            lastNote = "word lists differ — this match cannot be played"
            return
        }

        hasStarted = true
        storedOptions = options
        // Wrap once, here, so the minimum reaches every existing reader of
        // `dictionary` — `canDraw` above included — instead of one call site.
        // WILLA first, so a minimum above five still refuses it.
        if !(dictionary is WillaWordList) {
            dictionary = WillaWordList(base: dictionary)
        }
        if options.minimumWordLength > MatchOptions.lengthRange.lowerBound {
            dictionary = MinimumLengthWordList(
                base: dictionary,
                minimum: options.minimumWordLength
            )
        }
        // Negative or absurd values came off the wire; clamp rather than trap.
        // The ceiling is *half* the pool, not all of it: the deal is one draw of
        // `handSize * 2`, so anything above half leaves that draw short and
        // ``HostPool/deal(handSize:)`` hands out nothing at all — a silently
        // dealless match instead of a clamped one.
        self.startingHandSize = min(
            max(0, start.startingHandSize),
            (halfGame ? LetterDistribution.halfTotalTiles : LetterDistribution.totalTiles) / roster.count
        )
        // Only the device holding the pool has a deal to owe: everyone else's
        // opening hand arrives as a `.grant`. Armed on those devices too, and
        // nothing ever cleared it — `dealOpeningHands()` returns at its
        // `let hostPool` guard without reaching the line that does — so the
        // flag stayed true for the whole match and `peerReturned` took the
        // deal branch and returned before the resume countdown. Only the pool
        // holder ever counted 3-2-1.
        self.awaitingOpeningDeal = self.startingHandSize > 0 && start.host == localPlayerID

        if start.host == localPlayerID {
            let pool = halfGame ? Pool.half(seed: start.seed) : Pool.standard(seed: start.seed)
            hostPool = HostPool(
                players: roster,
                pool: pool,
                seed: start.seed,
                transport: transport,
                swapEnabled: options.swapEnabled
            )
            // The opening count, from the very pool just handed over — the HUD
            // shows a full pool before the deal rather than a placeholder.
            setPoolRemaining(pool.count)
        }
        // Clamped at both ends: one `.start` carrying a huge value off the wire
        // would otherwise park this session in `.countdown` for the rest of the
        // process. Ten seconds is the ceiling — longer than any lobby needs and
        // short enough that a wedged session recovers on its own.
        beginCountdown(seconds: min(max(0, start.countdownSeconds), 10))
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
            answerHeldDrawRequests()
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
                if remaining == 0 { self.answerHeldDrawRequests() }
            }
        }
    }

    /// Deals both opening hands, once, from the host's pool.
    ///
    /// Only the host has a pool to deal from; the guest's hand arrives as a
    /// `.grant` and lands through ``applyGrant(_:)``. Nothing happens on the
    /// guest, and nothing happens twice.
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
            await self.refreshPoolRemaining(from: hostPool)
            for case let .grant(player, tiles) in produced where player == self.localPlayerID {
                // The grant addressed to the host never travels — this is where
                // the host's own opening hand lands, as `applyProduced` does for
                // a draw.
                self.applyGrant(tiles)
            }
        }
    }

    /// Takes a granted tile into the rack.
    ///
    /// A grant is only ever the answer to this device's own request or the
    /// opening deal — the host addresses no other kind to it — and both land in
    /// the rack, so there is nothing here to tell apart. Nobody requests the
    /// deal, so the outstanding count decides the one thing that differs: a
    /// deal spends no credit, because it answers nothing.
    ///
    /// This replaced a heuristic that read the match phase and the tile count to
    /// guess whether a grant was the deal. Both triggers had known misfires — a
    /// dropped deal, or a hand size of one — and both are gone with the guess.
    private func applyGrant(_ tiles: [Tile]) {
        clearOneOutstandingDraw()

        let fresh = unheld(tiles)
        guard !fresh.isEmpty else { return }
        state.hand.append(contentsOf: fresh)
    }

    /// Takes the tile this device owes for the opponent's draw, straight into
    /// the rack.
    ///
    /// It used to wait behind the Draw button with the board shut, which also
    /// shut swap. Now the opponent's draw simply gives this device its tile.
    /// Spends no credit: this answers nothing this device asked for.
    private func applyObligation(_ tiles: [Tile]) {
        let fresh = unheld(tiles)
        guard !fresh.isEmpty else { return }
        state.hand.append(contentsOf: fresh)
    }

    /// Answers every draw request this host held while it could not serve one.
    /// Called at each flip to a live board, the first one included, which is
    /// what marks play as begun.
    private func answerHeldDrawRequests() {
        playHasBegun = true
        let held = heldDrawRequests
        heldDrawRequests = []
        for player in held { submitToHost(.drawRequest(player: player)) }
    }

    /// The tiles of `tiles` this device is not already holding somewhere.
    ///
    /// A duplicated grant is peer input: taking it twice would double a tile
    /// into the rack and leave the two devices disagreeing about the pool.
    private func unheld(_ tiles: [Tile]) -> [Tile] {
        var held = Set(state.hand.map(\.id))
        held.formUnion(pendingDrawTiles.map(\.id))
        held.formUnion(state.board.placementList.map(\.tile.id))
        return tiles.filter { !held.contains($0.id) }
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
        // Read before the loop below turns an absence into a departure.
        let somebodyIsAway = isFrozen
        stopEveryClock()
        state.status = .finished(winner: winner)
        winningPlacements = placements
        // The inbound pump stays, for the one message still to come: the other
        // player's final board. `receive` discards everything else from here
        // on. The presence pump stays too: a peer coming back is how an unsent
        // terminal message still gets out.
        //
        // This device's own board goes out now and never sooner. `claimWin()`
        // and `resign()` put their terminal message on the chain before they
        // call this, so the board always follows it.
        // ponytail: not sent to a peer that is away right now, and not sent
        // later either, so a winner who dropped at the moment of winning sees
        // "not available". Send it from `peerReturned` if that shows up.
        guard !somebodyIsAway else { return }
        send(.finalBoard(player: localPlayerID, placements: state.board.placementList))
    }

    /// What every ending stops: the countdown, the reconnect window and the
    /// pause limit.
    private func stopEveryClock() {
        countdownTask?.cancel()
        heldCountdownSeconds = nil
        time.reconnectTask?.cancel()
        reconnectSecondsOwed = nil
        time.pauseTask?.cancel()
        time.pauseTask = nil
        // The window that cancel just closed will never resolve, so a presence
        // left at `.reconnecting` puts a banner and a countdown to a deadline
        // nothing reaches over an end screen — the same lie `peerDropped()`
        // guards against in the opposite ordering.
        for player in roster {
            if case .reconnecting = presence(of: player) { peerPresences[player] = .gone }
        }
    }

    private var isFinished: Bool {
        if case .finished = state.status { return true }
        return false
    }

    /// The match ended with a result every device shares: a winner, or a void.
    private var isSettled: Bool { isFinished || time.voided }

    /// Somebody is away and may yet come back, so nothing may be sent and
    /// nothing may move. A peer that already left for good does not freeze the
    /// match — ``isMatchOver`` answers that one.
    private var isFrozen: Bool {
        peerPlayerIDs.contains { player in
            if case .reconnecting = presence(of: player) { return true }
            return false
        }
    }

    /// Nobody is away, however far away. The exemption that lets this device's
    /// own terminal message onto the wire is gated on this rather than on
    /// ``isFrozen``: a peer that already left is not coming back for it either,
    /// and the message has to be remembered instead of thrown at a closed link.
    private var everyPeerIsPresent: Bool {
        peerPlayerIDs.allSatisfy { presence(of: $0) == .present }
    }

    /// The board is shut: the match ended, somebody is away, or this device is
    /// the one that left.
    private var isLocked: Bool {
        isFinished || isFrozen || isMatchOver || presence(of: localPlayerID) == .gone
    }

    /// The two messages that name a winner, and the only two a frozen session
    /// still honours.
    private static func endsTheMatch(_ message: MatchMessage) -> Bool {
        switch message {
        case .win, .resign: return true
        default: return false
        }
    }

    /// What a frozen session still takes in: how the match ended, and anything
    /// the host has already done with the pool. Everything else is dropped,
    /// which is the safe side for a kind this list has not heard of: a kind
    /// that must survive a freeze has to be added here on purpose.
    private static func survivesAFreeze(_ message: MatchMessage) -> Bool {
        switch message {
        case .win, .resign, .grant, .obligation, .swapGrant, .poolExhausted, .poolCount, .rejected,
             .drawRequest, .pauseVote, .pauseState, .matchVoided:
            // The pause kinds too: one device can be frozen while the other
            // plays on, and a pause the two disagree about is the one thing a
            // pause must never be.
            return true
        default:
            return false
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
            await self.refreshPoolRemaining(from: hostPool)
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
                applyGrant(tiles)
            case let .obligation(player, tiles) where player == localPlayerID:
                applyObligation(tiles)
            case let .swapGrant(player, tiles, returned) where player == localPlayerID:
                applySwapGrant(tiles: tiles, returned: returned)
            case let .poolExhausted(requester):
                poolIsExhausted = true
                // The broadcast reaches both; only the device that asked is
                // owed an answer by it.
                if requester == localPlayerID { clearOneOutstandingDraw() }
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
        if everyPeerIsPresent, Self.endsTheMatch(message) { return false }
        // A final board is the one thing a finished session still sends. Not
        // gated on presence: the player who resigned is marked gone and is
        // still there to read it. Held back only while the terminal message is
        // owed, because that means the peer is away and has not heard the match
        // is over; ``peerReturned(_:)`` sends both then.
        if isSettled, !owesTerminalMessage, case .finalBoard = message { return false }
        // The void itself, from the session that just declared it.
        if time.voided, case .matchVoided = message { return false }
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

/// What ``MatchSession`` remembers for its two rules about time: a player out
/// of touch too long forfeits, and a pause that runs too long voids the match.
///
/// A class of its own only because `MatchSession` is at a stored-property
/// limit of the toolchain. Touched on the main actor, and once more from
/// `MatchSession.deinit`, which by then holds the only reference.
private final class Timekeeping: @unchecked Sendable {
    /// This device's own link to the match is reported down.
    var linkDown = false
    /// This device's link went down and no peer has been seen present since.
    /// While it is set, a reconnect window that runs out is this device's loss.
    var lostLinkSincePeerSeen = false
    /// When this device's current stretch out of touch began: off screen, or
    /// with its link down.
    var outOfTouchSince: Date?
    /// When the app last came back on screen with no word that its link had
    /// died. A dead link reported soon after still counts from
    /// ``outOfTouchSince``.
    var cameBackAt: Date?
    var endedByDisconnect = false
    var voided = false
    var pauseDeadline: Date?
    var pauseTask: Task<Void, Never>?
    /// Lives here only so that this box takes the place of a field the session
    /// already had, and the session stays the size it was.
    var reconnectTask: Task<Void, Never>?
}
