//
//  ScreenLockTests.swift
//  OnlineTests
//
//  Item 10: a screen lock no longer kills the match.
//
//  Locking a phone suspends the process and drops the socket, and two windows
//  then spend themselves on a process that is not running: `MatchSession`'s
//  30-second reconnect grace, and `RealtimeMatchTransport`'s 35-second peer
//  grace, which finishes the `inbound`/`states` streams — and a finished
//  `AsyncStream` cannot restart, so the session's pump exits for good while
//  SwiftUI carries on looking fine. That is the reported symptom exactly:
//  everything responds except Draw and Swap.
//
//  Both windows live here, so both are driven here, over the real transport
//  with a stub channel underneath it. The real numbers are 30 and 35 seconds;
//  the cases scale them down so the window really elapses inside the test
//  rather than being asserted about. `theRealWindowsAreShorterThanALock` is
//  what ties the scaled numbers back to the 60-second lock in the criterion.
//

import Foundation
import Testing
import WillagramsRules

@testable import Online

@MainActor
struct ScreenLockTests {

    private static let hostID = PlayerID(rawValue: "lock-host")
    private static let guestID = PlayerID(rawValue: "lock-guest")

    /// A stand-in payload: these cases assert whether a send reaches the wire
    /// at all, never what it carried.
    private static let carrier = MatchMessage.poolExhausted(requester: guestID)

    /// Short enough that a window left running really fires inside the case.
    private static let grace: Duration = .milliseconds(200)

    /// Comfortably past ``grace``: the stand-in for a 60-second lock.
    private static let lockDuration: Duration = .milliseconds(600)

    // MARK: - Setup

    /// One clock, scaled — both halves of it.
    ///
    /// ``now()`` runs *continuously* at exactly the rate ``sleep`` waits at, so
    /// a thirty-second reconnect window is thirty seconds on this clock and
    /// 300ms on the wall, and a window that has run half-way through has half
    /// of it left **by value**. That is the whole point: a session whose
    /// deadline came off `Date()` while its wait came off an injected sleeper
    /// would report a full thirty seconds still owed after the window had
    /// nearly run out, which makes a resume that banks the remainder and one
    /// that tops it back up to full indistinguishable from outside. They are
    /// the two clocks `done when:` 2 forbids, and this type is the one clock.
    final class ScaledClock: @unchecked Sendable {
        /// Session-seconds per real second.
        let factor: Double
        private let started = ContinuousClock.now
        private let epoch = Date()

        init(factor: Double) { self.factor = factor }

        static func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds)
                + Double(duration.components.attoseconds) * 1e-18
        }

        /// Virtual seconds elapsed since this clock started.
        private var elapsed: Double { Self.seconds(started.duration(to: .now)) * factor }

        var sleep: @MainActor @Sendable (Duration) async throws -> Void {
            let factor = self.factor
            return { duration in
                let real = Self.seconds(duration) / factor
                try await Task.sleep(for: .milliseconds(max(1, Int(real * 1000))))
            }
        }

        var now: @Sendable () -> Date {
            { [self] in epoch.addingTimeInterval(elapsed) }
        }
    }

    /// Two sessions playing over two real transports on one stub bus, plus the
    /// guest's scene-phase observer wired the way `OnlineMatch` wires it.
    ///
    /// Only the guest gets an ``AppActivity``: one device locks, the other
    /// stays on screen, which is what actually happens and what makes "the peer
    /// is gone" and "I was asleep" two different situations.
    private struct Table {
        let bus: StubBus
        let hostChannel: StubChannel
        let guestChannel: StubChannel
        let hostTransport: RealtimeMatchTransport
        let guestTransport: RealtimeMatchTransport
        let host: MatchSession
        let guest: MatchSession
        let guestActivity: AppActivity
    }

    /// - Parameter sessionGrace: what the sessions' injected clock does with a
    ///   requested duration. Defaulted to parking forever, so a case that is
    ///   not about the session window cannot be reached by it.
    /// - Parameter clock: the sessions' one clock, supplying both their sleep
    ///   and their `now`. Given one, `sessionSleep` is ignored — a case that
    ///   wants a scaled window wants both halves scaled together or it is back
    ///   to two clocks.
    private static func table(
        countdownSeconds: Int = 0,
        clock: ScaledClock? = nil,
        sessionSleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { _ in
            try await Task.sleep(for: .seconds(3_600))
        }
    ) async throws -> Table {
        let sessionSleep = clock?.sleep ?? sessionSleep
        let sessionNow: @Sendable () -> Date = clock?.now ?? Date.init
        let bus = StubBus()
        let hostChannel = bus.channel()
        let hostTransport = try await RealtimeMatchTransport.connect(
            localPlayerID: hostID, channel: hostChannel, peerGrace: grace, gapGrace: .seconds(60))
        let guestChannel = bus.channel()
        let guestTransport = try await RealtimeMatchTransport.connect(
            localPlayerID: guestID, channel: guestChannel, peerGrace: grace, gapGrace: .seconds(60))

        let host = MatchSession(
            transport: hostTransport, peerPlayerID: guestID,
            dictionary: EveryWordIsReal(), sleepFor: sessionSleep, now: sessionNow)
        let guest = MatchSession(
            transport: guestTransport, peerPlayerID: hostID,
            dictionary: EveryWordIsReal(), sleepFor: sessionSleep, now: sessionNow)

        // Registration order is `OnlineMatch`'s: transport first, so on resume
        // the socket is back before any window resumes counting.
        let guestActivity = AppActivity(center: nil)
        guestActivity.add(guestTransport)
        guestActivity.add(guest)

        host.startMatch(
            seed: 11, startingHandSize: 4, countdownSeconds: countdownSeconds, options: .standard)
        if countdownSeconds == 0 {
            try await waitUntil("both sessions playing") {
                host.state.status == .playing && guest.state.status == .playing
            }
        } else {
            // `.countdown(secondsRemaining: 0)` is also the status a session
            // sits in before the start lands, so the wait is for a tick that has
            // actually been handed a number.
            try await waitUntil("the guest to be counting down") {
                if case let .countdown(remaining) = guest.state.status { return remaining > 0 }
                return false
            }
        }
        return Table(
            bus: bus, hostChannel: hostChannel, guestChannel: guestChannel,
            hostTransport: hostTransport, guestTransport: guestTransport,
            host: host, guest: guest, guestActivity: guestActivity)
    }

    /// Lets a phase change land. ``AppActivity`` calls `appActivityChanged(to:)`
    /// `nonisolated`, and both listeners hop onto the main actor from there, so
    /// nothing a phase change does is readable in the same turn as the `send`.
    private static func settle() async {
        for _ in 0 ..< 50 { await Task.yield() }
    }

    private static func waitUntil(
        _ what: String,
        within deadline: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let limit = ContinuousClock.now + deadline
        while !condition() {
            guard ContinuousClock.now < limit else {
                Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// One screen lock: off screen, socket dropped, time passes, back on
    /// screen.
    ///
    /// The drop is modelled as it reaches the *locked* device — its peer
    /// vanishes from presence, because the socket carrying that presence went
    /// down — not as the peer leaving the bus. The peer is still there and the
    /// wire still routes; only this endpoint stopped hearing about it. That is
    /// the difference between a screen lock and an opponent walking away, and
    /// telling them apart is the whole item.
    ///
    /// The leave is delivered *after* the phase change on purpose: that is the
    /// ordering a real lock produces, and it is the one where a window armed
    /// while suspended would spend itself on nothing.
    private static func lock(
        _ table: Table,
        for duration: Duration = lockDuration
    ) async throws {
        table.guestActivity.send(.away)
        table.guestChannel.deliverPresence(joined: [], left: [hostID])
        try await Task.sleep(for: duration)
        table.guestActivity.send(.active)
    }

    /// The presence re-sync a rejoined channel delivers — `SupabaseMatchChannel`
    /// re-tracks off `onStatusChange`, and the peer comes back in that sync.
    private static func peerReappears(to table: Table) async throws {
        table.guestChannel.deliverPresence(joined: [Self.hostID], left: [])
        // The board is locked while a peer is `.reconnecting`, so nothing about
        // Draw or Swap is decidable until the return has actually landed.
        try await waitUntil("the peer to be present again") {
            table.guest.presence(of: Self.hostID) == .present
        }
    }

    // MARK: - `done when:` 1 — the match survives the lock

    @Test("A locked-and-resumed device can still Draw and Swap")
    func drawAndSwapSurviveAScreenLock() async throws {
        let table = try await Self.table()

        try await Self.lock(table)
        // The socket is back, exactly as `subscribe`'s re-track path puts it.
        try await Self.peerReappears(to: table)
        #expect(table.guestChannel.reconnects == 1)

        // Draw: the request leaves the guest's pump, reaches the host's, and
        // the grant comes back. A finished stream on either side is silence.
        let before = table.guest.state.hand.count
        #expect(table.guest.draw())
        try await Self.waitUntil("the draw to be granted") {
            table.guest.state.hand.count + table.guest.pendingDrawTiles.count > before
        }

        // Swap: the same round trip, the other request.
        let tile = try #require(table.guest.state.hand.first)
        #expect(table.guest.swap(tile))
        try await Self.waitUntil("the swap to be granted") {
            !table.guest.state.hand.contains(tile)
        }
    }

    @Test("A second lock is survivable too — the budget is not spent down by re-entry")
    func repeatedLocksAreSurvivable() async throws {
        let table = try await Self.table()

        for _ in 0 ..< 3 {
            try await Self.lock(table)
            try await Self.peerReappears(to: table)
        }

        let before = table.guest.state.hand.count
        #expect(table.guest.draw())
        try await Self.waitUntil("the draw to be granted after three locks") {
            table.guest.state.hand.count + table.guest.pendingDrawTiles.count > before
        }
    }

    // MARK: - `done when:` 2 — the time off screen is not charged to anyone

    /// The transport half, stated as the thing that used to break: the streams
    /// are still open after a lock far longer than the window.
    @Test("Time spent off screen is not charged against the transport's peer grace")
    func theTransportWindowDoesNotSpendItselfWhileAway() async throws {
        let table = try await Self.table()

        try await Self.lock(table)
        try await Self.peerReappears(to: table)

        // A finished stream is what kills the pump, and `send` throwing
        // `peerDisconnected` is the same latch seen from the other side.
        try await table.guestTransport.send(Self.carrier, delivery: .reliable)
        #expect(!table.guestChannel.sent.isEmpty)
    }

    /// The session half. The clock here maps any requested duration onto a real
    /// 40ms, so the 30-second window is decidable inside the case; the point is
    /// that the wait is not even *started* while the app is away.
    @Test("Time spent off screen is not charged against the session's reconnect grace")
    func theSessionWindowDoesNotSpendItselfWhileAway() async throws {
        let table = try await Self.table(sessionSleep: { _ in
            try await Task.sleep(for: .milliseconds(40))
        })

        // The peer drops while the guest is off screen, and is back on resume.
        try await Self.lock(table, for: .milliseconds(400))
        try await Self.peerReappears(to: table)

        // Without the pause the 40ms stand-in for 30 seconds elapsed long ago
        // and `awayPeersAreGone()` — which is one-way — has already run.
        #expect(table.guest.presence(of: Self.hostID) != .gone)
        #expect(!table.guest.isMatchOver)
    }

    /// `done when:` 2, second half, **by value**: the deadline the banner counts
    /// down to runs down at exactly the rate the wait does, because they are one
    /// clock.
    ///
    /// The window is thirty session-seconds. Fifteen of them are let run on
    /// screen, which is 150ms of wall time — so a deadline stamped off `Date()`
    /// while the wait ran off the injected sleeper would still say thirty
    /// seconds were owed here, and that reading is exactly what used to make a
    /// partial spend unobservable. Fifteen is what one clock reads.
    @Test("The session's reconnect deadline runs down at the rate its sleep does")
    func oneClockArmsBothTheDeadlineAndTheSleep() async throws {
        let table = try await Self.table(clock: ScaledClock(factor: 100))

        // The peer drops while the guest is on screen, so the window really is
        // counting and really is being charged for.
        table.bus.leave(table.hostChannel)
        table.guestChannel.deliverPresence(joined: [], left: [Self.hostID])
        try await Self.waitUntil("the reconnect window to arm") {
            table.guest.reconnectSecondsOwedForTesting != nil
        }
        #expect(table.guest.reconnectSecondsOwedForTesting == MatchSession.reconnectGraceSeconds)

        // Half the window, on screen.
        try await Task.sleep(for: .milliseconds(150))
        table.guestActivity.send(.away)
        await Self.settle()

        // Banked off the stamped deadline. On the wall clock this reads 30.
        let owed = try #require(table.guest.reconnectSecondsOwedForTesting)
        #expect(owed >= 10 && owed <= 20, "half a thirty-second window, not \(owed)")
    }

    /// `done when:` 2's other direction, on the same clock: the time off screen
    /// is charged to nobody, so a long lock leaves the remainder where the lock
    /// found it rather than draining it.
    @Test("A long lock does not spend the banked remainder on the one clock")
    func theBankedRemainderSurvivesALongLock() async throws {
        let table = try await Self.table(clock: ScaledClock(factor: 100))

        table.bus.leave(table.hostChannel)
        table.guestChannel.deliverPresence(joined: [], left: [Self.hostID])
        try await Self.waitUntil("the reconnect window to arm") {
            table.guest.reconnectSecondsOwedForTesting != nil
        }
        try await Task.sleep(for: .milliseconds(100))

        table.guestActivity.send(.away)
        await Self.settle()
        let atLock = try #require(table.guest.reconnectSecondsOwedForTesting)
        // 500ms off screen is fifty session-seconds — well past the whole
        // window. None of it may be charged.
        try await Task.sleep(for: .milliseconds(500))
        table.guestActivity.send(.active)

        // Straight back off screen: whatever is banked now is what the lock
        // left, not what the lock spent.
        table.guestActivity.send(.away)
        await Self.settle()
        let afterLock = try #require(table.guest.reconnectSecondsOwedForTesting)
        #expect(
            afterLock <= atLock && afterLock >= atLock - 1,
            "\(atLock) owed at the lock, \(afterLock) after it")
        #expect(table.guest.presence(of: Self.hostID) != .gone)
    }

    // MARK: - `done when:` 3 — a peer that never returns is still gone

    @Test("A peer that never comes back is still reported gone after a lock")
    func aPeerThatNeverReturnsIsStillGone() async throws {
        // One second of session time is 10ms here, so the real 30-second window
        // is decidable inside the case *and* still proportional: a remainder
        // that was topped back up to a full window — or to anything larger —
        // overruns the deadline below rather than quietly passing.
        let table = try await Self.table(sessionSleep: { duration in
            try await Task.sleep(for: .milliseconds(max(1, duration.components.seconds * 10)))
        })

        // The peer goes for good while the app is on screen, so part of the
        // window burns honestly before the first lock.
        table.bus.leave(table.hostChannel)
        table.guestChannel.deliverPresence(joined: [], left: [Self.hostID])
        try await Task.sleep(for: .milliseconds(40))

        // Three locks, and the peer is gone the whole time. A budget that grew
        // back on every resume would hang the match here forever, which is the
        // failure mode the fix must not introduce.
        for _ in 0 ..< 3 {
            table.guestActivity.send(.away)
            try await Task.sleep(for: .milliseconds(100))
            table.guestActivity.send(.active)
        }

        try await Self.waitUntil("the peer to be reported gone", within: .seconds(2)) {
            table.guest.presence(of: Self.hostID) == .gone
        }
        #expect(table.guest.isMatchOver)
    }

    @Test("A peer gone across a lock still finishes the transport's streams")
    func theTransportStillClosesOnAPeerThatNeverReturns() async throws {
        let table = try await Self.table()

        table.guestActivity.send(.away)
        table.bus.leave(table.hostChannel)
        table.guestChannel.deliverPresence(joined: [], left: [Self.hostID])
        try await Task.sleep(for: Self.lockDuration)
        table.guestActivity.send(.active)

        // The banked window resumes on resume and runs out on its own.
        try await Task.sleep(for: Self.grace + .milliseconds(200))
        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await table.guestTransport.send(Self.carrier, delivery: .reliable)
        }
    }

    /// The other half of "still gone": a window that was already *running*
    /// when the phone locked is banked at its remainder, not topped back up.
    /// Only this ordering exercises the pause path — a peer that vanishes after
    /// the lock arms a window that was never started.
    @Test("A window already running when the phone locks resumes at its remainder")
    func aRunningWindowResumesAtItsRemainder() async throws {
        let table = try await Self.table()

        // The peer drops on screen: the window starts counting for real.
        table.bus.leave(table.hostChannel)
        table.guestChannel.deliverPresence(joined: [], left: [Self.hostID])
        try await Task.sleep(for: Self.grace / 4)

        // ...and the phone locks with most of it still to go.
        table.guestActivity.send(.away)
        try await Task.sleep(for: Self.lockDuration)
        table.guestActivity.send(.active)

        // The peer never comes back, so the remainder runs out and the streams
        // finish — well inside one whole window, never mind an hour.
        try await Self.waitUntil("the transport to give up on the peer", within: .seconds(3)) {
            table.guestTransport.isFinishedForTesting
        }
    }

    // MARK: - The numbers the scaled cases stand in for

    /// Ties the scaled windows above back to the criterion: a 60-second lock is
    /// longer than either real window, so both really do expire mid-lock.
    @Test("A 60-second lock outlasts both real grace windows")
    func theRealWindowsAreShorterThanALock() {
        #expect(RealtimeMatchTransport.defaultPeerGrace < .seconds(60))
        #expect(Duration.seconds(MatchSession.reconnectGraceSeconds) < .seconds(60))
    }

    // MARK: - Isolation

    /// `appActivityChanged(to:)` is delivered from a `NotificationCenter`
    /// callback, which carries no actor. A conformance that inherited
    /// `@MainActor` would trap in `dispatch_assert_queue` the first time UIKit
    /// posted off the main queue — the same fault as the iPad launch crash.
    /// Calling it from a detached task is the compile-time proof.
    @Test("Both listeners can be told off the main actor")
    func listenersAreCallableOffTheMainActor() async throws {
        let table = try await Self.table()
        let session = table.guest
        let transport = table.guestTransport

        let ran = await Task.detached { () -> Bool in
            session.appActivityChanged(to: .away)
            transport.appActivityChanged(to: .active)
            return true
        }.value
        #expect(ran)
    }

    // MARK: - Wiring

    /// A dropped `activity:` argument compiles, runs, and ships a build where
    /// locking the phone still kills the match, because nothing is listening.
    ///
    /// Pinned by **value**, not by reading the source. The previous version of
    /// this case asserted that the strings `activity?.add(listening)` and
    /// `activity?.add(session)` appeared in `OnlineMatch.swift` — which says
    /// nothing about whether either line is *reached*, and a mutation that put
    /// both behind a predicate that is never true left both literals byte-intact
    /// and scored zero. Here the façade builds the transport and the session
    /// itself, through `host`/`join`/`awaitStart`, and the only thing asserted is
    /// what the two registrations are *for*.
    @Test("The façade's own wiring — not a hand-wired one — survives a lock")
    func theShippedWiringSurvivesALock() async throws {
        let backend = FakeBackend()
        let creator = try await backend.signInWithApple(idToken: "A", nonce: "n").playerID
        let joiner = try await backend.signInWithApple(idToken: "B", nonce: "n").playerID

        let bus = StubBus()
        let creatorChannel = bus.channel()
        let joinerChannel = bus.channel()
        let creatorTransport = try await RealtimeMatchTransport.connect(
            localPlayerID: creator, channel: creatorChannel, peerGrace: Self.grace,
            gapGrace: .seconds(60))
        let joinerTransport = try await RealtimeMatchTransport.connect(
            localPlayerID: joiner, channel: joinerChannel, peerGrace: Self.grace, gapGrace: .seconds(60))
        await backend.setTransportFactory { _, player in
            player == creator ? creatorTransport : joinerTransport
        }

        // Only the joining device gets an observer: one phone locks, the other
        // stays on screen. Exactly what `JoinModel` does with
        // `shell.services.activity`.
        let activity = AppActivity(center: nil)
        _ = try await backend.signInWithApple(idToken: "A", nonce: "n")
        let hosted = try await OnlineMatch.host(
            options: .standard, backend: backend, dictionary: EveryWordIsReal(), sleepFor: { _ in })
        _ = try await backend.signInWithApple(idToken: "B", nonce: "n")
        let joined = try await OnlineMatch.join(
            code: hosted.inviteCode, backend: backend, dictionary: EveryWordIsReal(),
            activity: activity,
            sleepFor: { _ in try await Task.sleep(for: .milliseconds(40)) })

        // The façade builds this session and registers it; nothing in this case
        // touches `AppActivity.add` itself.
        let session = try await joined.awaitStart()

        // Both registrations, and their ORDER, by value. `activity: nil` at
        // either façade call site leaves this list empty; swapping the two
        // `add` calls resumes the session's window over a socket that is not
        // back yet, which is the ordering the item mandates.
        #expect(
            activity.listenerIdentitiesForTesting
                == [ObjectIdentifier(joinerTransport), ObjectIdentifier(session)])

        activity.send(.away)
        joinerChannel.deliverPresence(joined: [], left: [creator])
        try await Task.sleep(for: Self.lockDuration)
        activity.send(.active)

        // The transport registration: without it the 200ms peer grace ran out
        // mid-lock and finished `inbound`/`states` for good.
        #expect(!joinerTransport.isFinishedForTesting)
        // The session registration: without it the 40ms stand-in for the 30s
        // reconnect window ran out mid-lock and `awayPeersAreGone()` is one-way.
        #expect(session.presence(of: creator) != .gone)
        #expect(!session.isMatchOver)

        withExtendedLifetime(hosted) {}
        withExtendedLifetime(creatorTransport) {}
    }

    /// The belt on both lobby call sites. The braces are `ShellTests`, which
    /// drives `JoinModel.join()` and `HostLobbyModel.start()` over a real
    /// `OnlineMatch` and asserts the shell's own observer came back with the
    /// session registered on it — by value, which is the real cover.
    ///
    /// What is left here is a literal, so it is ONE contiguous match against
    /// NORMALISED source: every line trimmed, every `//` line dropped, rejoined.
    /// Independent `contains` calls are what let a mutation keep the string
    /// alive in a comment while the call itself passed `nil`, and normalising
    /// deletes that hiding place.
    @Test("Both lobbies hand the shell's own observer to the façade")
    func theLobbiesPassTheShellsObserver() throws {
        let call = """
            backend: backend,
            dictionary: dictionary,
            activity: shell.services.activity,
            sleepFor: sleepFor
            """
        for lobby in ["Willagrams/Shell/HostLobbyModel.swift", "Willagrams/Shell/JoinModel.swift"] {
            #expect(try Self.normalised(of: lobby).contains(call), "\(lobby)")
        }
    }

    /// Source with every line trimmed and every whole-line comment removed. A
    /// literal pinned against this cannot be satisfied by a `//` line that
    /// merely mentions it.
    private static func normalised(of path: String) throws -> String {
        try source(of: path)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - The budget may only shrink

    /// The bound that actually holds, and it is a comparison rather than a
    /// number: across any number of locks the banked window may only get
    /// smaller. A top-up of *any* size — an hour, a second, a millisecond —
    /// breaks it, where a timing bound only catches a top-up big enough to
    /// overrun whatever number the bound happened to pick.
    @Test("Locking repeatedly never grows the transport's banked grace")
    func theTransportsBankedGraceOnlyShrinks() async throws {
        let table = try await Self.table()

        // The peer goes for good while the app is on screen, so a window is
        // really running when the first lock lands.
        table.bus.leave(table.hostChannel)
        table.guestChannel.deliverPresence(joined: [], left: [Self.hostID])
        let firstDrop = ContinuousClock.now

        // STRICTLY smaller, and seeded ABOVE the window rather than at it.
        // `banked <= Self.grace` is satisfied forever by a `pauseGrace` that
        // banks the whole original window instead of the remainder — the peer
        // window then restarts in full on every resume, so a lock/unlock loop
        // defers the peer-gone latch indefinitely, and every wall-clock ceiling
        // in this file still holds because the window never exceeds its
        // original length. Only a strict comparison sees it.
        var previous = Self.grace + .seconds(1)
        for _ in 0 ..< 5 {
            table.guestActivity.send(.away)
            let banked = try #require(table.guestTransport.bankedGraceForTesting)
            #expect(banked < previous, "banked \(banked), was \(previous)")
            previous = banked
            table.guestActivity.send(.active)
            // A non-zero stretch on screen: time the peer really is reachable
            // for, and really does owe.
            try await Task.sleep(for: .milliseconds(20))
        }

        try await Self.waitUntil("the transport to give up on the peer", within: .seconds(3)) {
            table.guestTransport.isFinishedForTesting
        }
        // ...and a hard ceiling on the wall time from the first drop, so a
        // window that grew slowly still fails rather than merely taking longer.
        #expect(firstDrop.duration(to: .now) < Self.grace * 4)
    }

    /// STRICTLY smaller, not merely no larger. A budget that never shrinks is
    /// monotone too, and that is precisely the shape a re-armed full window
    /// takes: `owed <= previous` holds at thirty forever. Each cycle spends a
    /// real stretch on screen — twenty milliseconds, two session-seconds on the
    /// one clock — so honest bookkeeping has to show it, and any top-up at all
    /// puts the next reading back where the last one was or above it.
    @Test("Locking repeatedly never grows the session's reconnect budget")
    func theSessionsReconnectBudgetOnlyShrinks() async throws {
        let table = try await Self.table(clock: ScaledClock(factor: 100))

        table.bus.leave(table.hostChannel)
        table.guestChannel.deliverPresence(joined: [], left: [Self.hostID])
        try await Self.waitUntil("the reconnect window to arm") {
            table.guest.reconnectSecondsOwedForTesting != nil
        }
        let firstDrop = ContinuousClock.now

        var previous = MatchSession.reconnectGraceSeconds + 1
        for cycle in 0 ..< 5 {
            // On screen, with the peer unreachable: time that really is owed.
            try await Task.sleep(for: .milliseconds(20))
            table.guestActivity.send(.away)
            await Self.settle()
            let owed = try #require(table.guest.reconnectSecondsOwedForTesting)
            #expect(owed < previous, "cycle \(cycle): \(owed) owed, was \(previous)")
            previous = owed
            // Off screen for five times as long, and none of it charged.
            try await Task.sleep(for: .milliseconds(100))
            table.guestActivity.send(.active)
            await Self.settle()
        }

        try await Self.waitUntil("the peer to be reported gone", within: .seconds(3)) {
            table.guest.presence(of: Self.hostID) == .gone
        }
        #expect(firstDrop.duration(to: .now) < .seconds(2))
    }

    // MARK: - The order the fan-out runs in

    /// `done when:` 1's mechanism, and the item's own wording: on resume the
    /// transport re-subscribes *before* any window resumes counting. That is
    /// two facts, and both are pinned by value rather than by comment.
    ///
    /// This half is `AppActivity`'s: a phase reaches listeners in the order they
    /// registered. Reverse the fan-out and the session's window resumes over a
    /// socket that is not back yet — a window spent on nothing, which is the
    /// bug this whole item is about.
    @Test("A phase reaches listeners in registration order")
    func theFanOutRunsInRegistrationOrder() {
        let activity = AppActivity(center: nil)
        let log = Recorder.Log()
        let first = Recorder(name: "first", log: log)
        let second = Recorder(name: "second", log: log)
        activity.add(first)
        activity.add(second)

        activity.send(.away)
        activity.send(.active)

        #expect(log.entries == ["first:away", "second:away", "first:active", "second:active"])
        withExtendedLifetime(first) {}
        withExtendedLifetime(second) {}
    }

    private final class Recorder: AppActivityListener, @unchecked Sendable {
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [String] = []
            var entries: [String] { lock.withLock { seen } }
            func append(_ entry: String) { lock.withLock { seen.append(entry) } }
        }

        private let name: String
        private let log: Log
        init(name: String, log: Log) {
            self.name = name
            self.log = log
        }
        func appActivityChanged(to phase: AppActivity.Phase) {
            log.append("\(name):\(phase == .away ? "away" : "active")")
        }
    }

    // MARK: - A lock that lands before the deal

    /// Every other case here locks during `.playing`. A lock during the pre-deal
    /// countdown takes a different path — `peerDropped` cancels `countdownTask`
    /// and banks `heldCountdownSeconds`, and only `peerReturned` resumes it — so
    /// a fix that left the reconnect window running would strand the match on
    /// the countdown screen with two empty racks.
    @Test("A lock during the pre-deal countdown still reaches the board")
    func aLockDuringTheCountdownStillDeals() async throws {
        let table = try await Self.table(
            countdownSeconds: 10,
            sessionSleep: { _ in try await Task.sleep(for: .milliseconds(100)) })

        try await Self.lock(table)
        try await Self.peerReappears(to: table)

        try await Self.waitUntil("the held countdown to finish and the hands to deal") {
            table.guest.state.status == .playing && !table.guest.state.hand.isEmpty
        }
        let before = table.guest.state.hand.count
        #expect(table.guest.draw())
        try await Self.waitUntil("the draw to be granted after a countdown lock") {
            table.guest.state.hand.count + table.guest.pendingDrawTiles.count > before
        }
    }

    // MARK: - Review findings

    /// The shape `theSessionsReconnectBudgetOnlyShrinks` cannot see: an on-screen
    /// stretch shorter than ONE SESSION-SECOND. That case runs 20ms at ×100, so
    /// every cycle spends two whole seconds and a ceiling still rounds them down
    /// to a drop. A real lock/unlock is a fraction of a second on the real clock,
    /// and `.rounded(.up)` refunds a fraction entirely: the budget sticks at 30
    /// for ever while the transport's own 35s still finishes the streams, which
    /// is a frozen board behind a banner counting to a deadline nothing reaches.
    /// One session-second per ten real milliseconds here, and one real
    /// millisecond on screen per cycle — a tenth of a second, which a ceiling
    /// gives straight back.
    @Test("A sub-second stretch on screen is still charged, and still ends the match")
    func aSubSecondStretchOnScreenIsStillCharged() async throws {
        let table = try await Self.table(clock: ScaledClock(factor: 100))

        table.bus.leave(table.hostChannel)
        table.guestChannel.deliverPresence(joined: [], left: [Self.hostID])
        try await Self.waitUntil("the reconnect window to arm") {
            table.guest.reconnectSecondsOwedForTesting != nil
        }

        var previous = MatchSession.reconnectGraceSeconds + 1
        for cycle in 0 ..< (MatchSession.reconnectGraceSeconds + 5) {
            // A tenth of a session-second on screen: under one second, which is
            // exactly the interval a ceiling rounds away to nothing.
            try await Task.sleep(for: .milliseconds(1))
            table.guestActivity.send(.away)
            await Self.settle()
            guard let owed = table.guest.reconnectSecondsOwedForTesting else { break }
            #expect(owed < previous, "cycle \(cycle): \(owed) owed, was \(previous)")
            previous = owed
            try await Task.sleep(for: .milliseconds(1))
            table.guestActivity.send(.active)
            await Self.settle()
            // Spent. Nothing is left to shrink, so a sixth reading of zero is
            // not a top-up and must not be read as one.
            if owed == 0 { break }
        }

        // ...and the point of charging it: the match actually ends.
        try await Self.waitUntil("the peer to be reported gone", within: .seconds(3)) {
            table.guest.presence(of: Self.hostID) == .gone
        }
    }

    /// A hop is a queued block, and the suspension a lock causes can land before
    /// it runs. The bank has to be taken inside the notification, not after it:
    /// a `Task { @MainActor }` that only runs on resume reads a deadline already
    /// in the past, banks zero, and ends the match the moment the screen comes
    /// back. Told on the main thread — where UIKit posts from — the budget must
    /// have moved before `appActivityChanged(to:)` returns, with nothing awaited
    /// in between.
    @Test("Told on the main thread, the away bank is taken synchronously")
    func theAwayBankIsTakenWithoutAHop() async throws {
        let table = try await Self.table(clock: ScaledClock(factor: 100))

        table.bus.leave(table.hostChannel)
        table.guestChannel.deliverPresence(joined: [], left: [Self.hostID])
        try await Self.waitUntil("the reconnect window to arm") {
            table.guest.reconnectSecondsOwedForTesting != nil
        }
        // Two session-seconds on screen, so an honest bank is visibly below 30.
        try await Task.sleep(for: .milliseconds(20))

        table.guest.appActivityChanged(to: .away)
        // No `await` between the call and the read: a hop has not run yet.
        let owed = try #require(table.guest.reconnectSecondsOwedForTesting)
        #expect(owed < MatchSession.reconnectGraceSeconds, "\(owed) owed")
    }

    /// `makeSession` is the only path that ships a session, so a `now:` the
    /// façade never takes leaves every shipped match stamping its banner
    /// deadline on the wall clock while waiting the window out on the injected
    /// one — `done when:` 2 defeated in production with every unit test green.
    ///
    /// Two pins, and between them the whole path. The unapplied method
    /// references are the COMPILER's: drop `now:` from either entry point and
    /// this file stops building. The literal is one contiguous match against
    /// NORMALISED source — every line trimmed, every `//` line dropped — so a
    /// `now: now` surviving only in a comment cannot satisfy it; it covers the
    /// remaining span, `makeSession`'s own call into `MatchSession`.
    ///
    /// Not pinned end-to-end by value, and that is not for want of trying: no
    /// façade-built session can observe a peer drop at all today. `watchLobby`
    /// consumes `transport.peerConnectionStates` and `makeSession` cancels that
    /// task — and cancelling an `AsyncStream`'s consumer TERMINATES the stream,
    /// so the session's own `for await` over the same stream receives nothing,
    /// ever. See the Engineer Report; it is a live defect, not a test limitation.
    @Test("The façade hands its session the injected clock, not just the sleeper")
    func theFacadeThreadsItsClockIntoTheSession() throws {
        _ = OnlineMatch.host(
            options:backend:dictionary:dictionaryHash:outcomeStore:activity:sleepFor:now:)
        _ = OnlineMatch.join(
            code:backend:dictionary:dictionaryHash:outcomeStore:activity:sleepFor:now:)

        let source = try Self.normalised(of: "Willagrams/Online/OnlineMatch.swift")

        // Link 1 — `host` and `join` each forward it into `make`. Both, hence
        // the count: one entry point left on the wall clock is half the bug.
        let intoMake = """
            outcomeStore: outcomeStore,
            activity: activity,
            sleepFor: sleepFor,
            now: now
            """
        #expect(source.components(separatedBy: intoMake).count - 1 == 2, "host and join")

        // Link 2 — `make` forwards it into the initialiser.
        let intoInit = """
            outcomeStore: store,
            activity: activity,
            sleepFor: sleepFor,
            now: now
            """
        #expect(source.contains(intoInit), "make -> init")

        // Link 3 — the initialiser stores the one it was given. `self.now =
        // Date.init` compiles, ships the wall clock, and is invisible to every
        // other pin here.
        #expect(source.contains("self.now = now"), "init stores it")

        // Link 4 — `makeSession`'s own call into `MatchSession`.
        let call = """
            dictionary: dictionary,
            dictionaryHash: dictionaryHash,
            sleepFor: sleepFor,
            now: now
            """
        #expect(source.contains(call), "makeSession -> MatchSession")
    }

    /// A transport that has already finished has no match left to re-join.
    /// Without the closed check every foreground re-opens the Realtime socket
    /// for a match that is over — and the app is foregrounded rather a lot.
    @Test("A transport that has already left does not re-open its socket")
    func aFinishedTransportDoesNotReconnect() async throws {
        let bus = StubBus()
        let channel = bus.channel()
        let transport = try await RealtimeMatchTransport.connect(
            localPlayerID: Self.guestID, channel: channel, peerGrace: Self.grace,
            gapGrace: .seconds(60))

        transport.leave()
        let before = channel.reconnects

        transport.appActivityChanged(to: .away)
        transport.appActivityChanged(to: .active)

        #expect(channel.reconnects == before, "\(channel.reconnects) reconnects, was \(before)")
    }

    private static func source(of path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Cases
                .deletingLastPathComponent()  // OnlineTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repo root
                .appendingPathComponent(path),
            encoding: .utf8)
    }
}
