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

    /// Short enough that a window left running really fires inside the case.
    private static let grace: Duration = .milliseconds(200)

    /// Comfortably past ``grace``: the stand-in for a 60-second lock.
    private static let lockDuration: Duration = .milliseconds(600)

    // MARK: - Setup

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
    private static func table(
        countdownSeconds: Int = 0,
        sessionSleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { _ in
            try await Task.sleep(for: .seconds(3_600))
        }
    ) async throws -> Table {
        let bus = StubBus()
        let hostChannel = bus.channel()
        let hostTransport = try await RealtimeMatchTransport.connect(
            localPlayerID: hostID, channel: hostChannel, peerGrace: grace, gapGrace: .seconds(60))
        let guestChannel = bus.channel()
        let guestTransport = try await RealtimeMatchTransport.connect(
            localPlayerID: guestID, channel: guestChannel, peerGrace: grace, gapGrace: .seconds(60))

        let host = MatchSession(
            transport: hostTransport, peerPlayerID: guestID,
            dictionary: EveryWordIsReal(), sleepFor: sessionSleep)
        let guest = MatchSession(
            transport: guestTransport, peerPlayerID: hostID,
            dictionary: EveryWordIsReal(), sleepFor: sessionSleep)

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
        try await table.guestTransport.send(.poolExhausted, delivery: .reliable)
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

    /// The deadline the UI renders and the sleep the session actually waits on
    /// are derived in one call from one instant, so they cannot disagree by a
    /// suspend duration. Pinned on the source: two clocks agreeing is a
    /// property of how the wait is armed, not of any one observable value.
    @Test("The session's reconnect deadline and its sleep are armed from one call")
    func oneClockArmsBothTheDeadlineAndTheSleep() throws {
        let source = try Self.source(of: "Willagrams/Match/MatchSession.swift")
        #expect(source.contains("private func armReconnectWait(seconds: Int)"))
        // The only two places the wait is set up, and both go through it.
        #expect(source.contains("armReconnectWait(seconds: Self.reconnectGraceSeconds)"))
        #expect(source.contains("armReconnectWait(seconds: owed)"))
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
            try await table.guestTransport.send(.poolExhausted, delivery: .reliable)
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

    /// The lobbies are the only two call sites, and neither is reachable from
    /// this target — a `@MainActor` shell model over SwiftUI screens. A literal
    /// is the only cover a private, unreachable call site takes.
    @Test("Both lobbies hand the shell's own observer to the façade")
    func theLobbiesPassTheShellsObserver() throws {
        for lobby in ["Willagrams/Shell/HostLobbyModel.swift", "Willagrams/Shell/JoinModel.swift"] {
            #expect(try Self.source(of: lobby).contains("activity: shell.services.activity"))
        }
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

        var previous = Self.grace
        for _ in 0 ..< 5 {
            table.guestActivity.send(.away)
            let banked = try #require(table.guestTransport.bankedGraceForTesting)
            #expect(banked <= previous)
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

    @Test("Locking repeatedly never grows the session's reconnect budget")
    func theSessionsReconnectBudgetOnlyShrinks() async throws {
        // One session-second is 10ms here, so the real 30-second window is
        // 300ms and is decidable inside the case.
        let table = try await Self.table(sessionSleep: { duration in
            try await Task.sleep(for: .milliseconds(max(1, duration.components.seconds * 10)))
        })

        table.bus.leave(table.hostChannel)
        table.guestChannel.deliverPresence(joined: [], left: [Self.hostID])
        try await Self.waitUntil("the reconnect window to arm") {
            table.guest.reconnectSecondsOwedForTesting != nil
        }
        let firstDrop = ContinuousClock.now

        var previous = MatchSession.reconnectGraceSeconds
        for _ in 0 ..< 5 {
            table.guestActivity.send(.away)
            try await Self.waitUntil("the budget to be banked") {
                table.guest.reconnectSecondsOwedForTesting != nil
            }
            let owed = try #require(table.guest.reconnectSecondsOwedForTesting)
            #expect(owed <= previous)
            previous = owed
            table.guestActivity.send(.active)
            try await Task.sleep(for: .milliseconds(20))
        }

        try await Self.waitUntil("the peer to be reported gone", within: .seconds(3)) {
            table.guest.presence(of: Self.hostID) == .gone
        }
        #expect(firstDrop.duration(to: .now) < .seconds(2))
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
