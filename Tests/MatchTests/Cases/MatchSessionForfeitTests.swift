import Foundation
import Testing
import WillagramsRules
@testable import Match

/// Two rules about time.
///
/// **A drop is a forfeit.** A player out of touch for
/// ``MatchSession/reconnectGraceSeconds`` loses, paused or not, and the player
/// who stayed wins. A device cannot tell "my link died" from "they left" by
/// presence alone, so it also watches its own link and its own time off screen,
/// and never awards itself a match it was the one to leave.
///
/// **A pause runs out.** An agreed pause lasts
/// ``MatchSession/pauseLimitSeconds``. Still paused then, the match is voided:
/// over, with no winner, and nothing for anybody's record.
@MainActor
@Suite("Match session forfeit and pause limit")
struct MatchSessionForfeitTests {

    typealias Terminal = MatchSessionTerminalTests
    typealias Flow = MatchSessionMatchFlowTests
    typealias Pause = MatchSessionPauseTests
    typealias Table = MatchSessionMatchFlowTests.Table

    static let alice = Terminal.alice
    static let bob = Terminal.bob
    static let window = Duration.seconds(MatchSession.reconnectGraceSeconds)
    static let limit = Duration.seconds(MatchSession.pauseLimitSeconds)

    /// A wall clock the test moves by hand. Only ever touched on the main actor.
    final class Wall: @unchecked Sendable {
        var date = Date(timeIntervalSinceReferenceDate: 1_000)
        func advance(_ seconds: TimeInterval) { date += seconds }
    }

    /// `Terminal.playingGuest`, on a wall clock the test owns.
    static func timedGuest(
        clock: Terminal.HandCrankedClock, wall: Wall
    ) async throws -> (guest: MatchSession, wire: Terminal.PresenceTransport) {
        let wire = Terminal.PresenceTransport(localPlayerID: bob, peer: alice)
        let guest = MatchSession(
            transport: wire, peerPlayerID: alice, dictionary: Terminal.EveryWordIsReal(),
            sleepFor: { await clock.tick($0) },
            now: { wall.date }
        )
        wire.deliver(
            .start(
                version: WireFormat.current, seed: 1, startingHandSize: 0, countdownSeconds: 0,
                options: .standard, roster: [alice, bob])
        )
        try await Terminal.waitUntil("the guest to be playing") { guest.state.status == .playing }
        return (guest, wire)
    }

    // MARK: - A1a, A1b: thirty seconds, and not one less

    @Test("A peer gone for the whole window forfeits, and the player who stayed wins")
    func aThirtySecondDropIsAForfeit() async throws {
        #expect(MatchSession.reconnectGraceSeconds == 30)
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)

        wire.drop(Self.alice)
        try await Terminal.waitUntil("the window to ask for its time") { clock.parkedCount == 1 }
        // One wait, for exactly the window. Until it is handed out the match is live.
        #expect(clock.requested == [Self.window])
        #expect(guest.isMatchOver == false)
        #expect(guest.winner == nil)

        clock.release(Self.window)
        try await Terminal.waitUntil("the forfeit") { guest.isMatchOver }

        #expect(guest.winner == Self.bob)
        #expect(guest.state.status == .finished(winner: Self.bob))
        // No board won it, so there is no time to put on a leaderboard.
        #expect(guest.winningPlacements == nil)
        #expect(guest.endedByDisconnect)
        #expect(guest.isVoided == false)
        guest.leave()
    }

    @Test("A peer back inside the window changes nothing")
    func aReturnInsideTheWindowChangesNothing() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        try await Terminal.stock(guest, wire)
        let before = Terminal.snapshot(guest)

        wire.drop(Self.alice)
        try await Terminal.waitUntil("the freeze") { guest.peerPresence != .present }
        wire.restore(Self.alice)
        try await Terminal.waitUntil("the return") { guest.peerPresence == .present }
        try await Terminal.resume(guest, on: clock)
        // The window's own sleeper, woken late: it was cancelled, and says nothing.
        clock.release(Self.window)
        try await Terminal.settle()

        #expect(guest.isMatchOver == false)
        #expect(guest.endedByDisconnect == false)
        #expect(Terminal.snapshot(guest) == before)
        guest.leave()
        clock.releaseAll()
    }

    // MARK: - A1c: a pause is no shelter

    @Test("A paused match forfeits the same way")
    func aPausedMatchForfeitsTheSame() async throws {
        let table = try await Pause.pausedTable()

        table.hostWire.drop(Self.bob)
        try await Terminal.waitUntil("the host's window") {
            table.hostClock.requested.contains(Self.window)
        }
        #expect(table.host.isMatchOver == false)
        table.hostClock.release(Self.window)
        try await Terminal.waitUntil("the forfeit") { table.host.isMatchOver }

        #expect(table.host.winner == Self.alice)
        #expect(table.host.endedByDisconnect)
        #expect(table.host.isVoided == false)
        await table.leave()
    }

    // MARK: - A1d: nobody wins by losing their own connection

    @Test("A device whose own link is down when the window closes takes the loss")
    func aDeadLinkOfOnesOwnIsALoss() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)

        // What a dead socket looks like from inside: this device's link, then
        // everybody else "leaving".
        wire.drop(Self.bob)
        wire.drop(Self.alice)
        try await Terminal.waitUntil("the window to ask for its time") { clock.parkedCount == 1 }
        clock.release(Self.window)
        try await Terminal.waitUntil("the forfeit") { guest.isMatchOver }

        #expect(guest.winner == Self.alice)
        #expect(guest.endedByDisconnect)

        // Nobody could hear it then. It is said at the next contact.
        #expect(await wire.wire.contains(.resign(player: Self.bob)) == false)
        wire.restore(Self.bob)
        wire.restore(Self.alice)
        try await Terminal.waitUntil("the loss to be said") {
            await wire.wire.contains(.resign(player: Self.bob))
        }
        guest.leave()
    }

    @Test("A link of one's own that comes back in time costs nothing")
    func ownLinkBackInTimeResumes() async throws {
        let clock = Terminal.HandCrankedClock()
        let wall = Wall()
        let (guest, wire) = try await Self.timedGuest(clock: clock, wall: wall)

        wire.drop(Self.bob)
        wire.drop(Self.alice)
        try await Terminal.waitUntil("the freeze") { guest.peerPresence != .present }
        wall.advance(29)
        wire.restore(Self.bob)
        wire.restore(Self.alice)
        try await Terminal.waitUntil("the return") { guest.peerPresence == .present }
        try await Terminal.resume(guest, on: clock)

        #expect(guest.isMatchOver == false)
        #expect(guest.winner == nil)
        guest.leave()
        clock.releaseAll()
    }

    @Test("A link of one's own that comes back too late is a loss on the spot")
    func ownLinkBackTooLateIsALoss() async throws {
        let clock = Terminal.HandCrankedClock()
        let wall = Wall()
        let (guest, wire) = try await Self.timedGuest(clock: clock, wall: wall)

        // Off screen, so the window is not counting: the wall clock is the
        // only witness.
        guest.appWentAway()
        wire.drop(Self.bob)
        wire.drop(Self.alice)
        try await Terminal.waitUntil("the freeze") { guest.peerPresence != .present }
        wall.advance(25)
        guest.appCameBack()
        #expect(guest.isMatchOver == false)
        wall.advance(25)
        wire.restore(Self.bob)
        try await Terminal.waitUntil("the forfeit") { guest.isMatchOver }

        #expect(guest.winner == Self.alice)
        #expect(guest.endedByDisconnect)
        guest.leave()
        clock.releaseAll()
    }

    /// The socket that died off screen and is only found dead a heartbeat
    /// later. The time off screen still counts.
    @Test("Time off screen and the dead link found after it add up")
    func awayThenASlowReconnectAddUp() async throws {
        let clock = Terminal.HandCrankedClock()
        let wall = Wall()
        let (guest, wire) = try await Self.timedGuest(clock: clock, wall: wall)

        guest.appWentAway()
        wall.advance(25)
        guest.appCameBack()
        #expect(guest.isMatchOver == false)

        wall.advance(10)
        wire.drop(Self.bob)
        wire.drop(Self.alice)
        try await Terminal.waitUntil("the freeze") { guest.peerPresence != .present }
        wall.advance(15)
        wire.restore(Self.bob)
        try await Terminal.waitUntil("the forfeit") { guest.isMatchOver }

        #expect(guest.winner == Self.alice)
        guest.leave()
        clock.releaseAll()
    }

    // MARK: - A1e: the player who dropped lands on a result

    @Test("Back after thirty seconds off screen: a loss, said to the peer, never a stuck board")
    func backAfterThirtySecondsAwayIsALoss() async throws {
        let clock = Terminal.HandCrankedClock()
        let wall = Wall()
        let (guest, wire) = try await Self.timedGuest(clock: clock, wall: wall)

        guest.appWentAway()
        wall.advance(29)
        guest.appCameBack()
        #expect(guest.isMatchOver == false)

        guest.appWentAway()
        wall.advance(1)
        guest.appCameBack()

        #expect(guest.isMatchOver)
        #expect(guest.winner == Self.alice)
        #expect(guest.endedByDisconnect)
        try await Terminal.waitUntil("the loss to be said") {
            await wire.wire.contains(.resign(player: Self.bob))
        }

        // Said again at the next contact: the first went into a socket that may
        // have been dead without anybody knowing yet.
        wire.drop(Self.alice)
        wire.restore(Self.alice)
        try await Terminal.waitUntil("the loss to be said again") {
            await wire.wire.filter { $0 == .resign(player: Self.bob) }.count == 2
        }
        guest.leave()
    }

    @Test("A short trip off screen with the peer already gone does not cost the win")
    func aShortSwitchWithAGonePeerStillWins() async throws {
        let clock = Terminal.HandCrankedClock()
        let wall = Wall()
        let (guest, wire) = try await Self.timedGuest(clock: clock, wall: wall)

        wire.drop(Self.alice)
        try await Terminal.waitUntil("the window") { clock.parkedCount == 1 }
        wall.advance(5)
        guest.appWentAway()
        wall.advance(5)
        guest.appCameBack()
        // Twenty-five seconds were left on screen, and that is what it waits.
        try await Terminal.waitUntil("the rest of the window") {
            clock.requested.contains(.seconds(25))
        }
        clock.release(.seconds(25))
        try await Terminal.waitUntil("the forfeit") { guest.isMatchOver }

        #expect(guest.winner == Self.bob)
        guest.leave()
        clock.releaseAll()
    }

    @Test("Two short trips off screen, far apart, are two short trips")
    func twoShortSwitchesFarApartDoNotAddUp() async throws {
        let clock = Terminal.HandCrankedClock()
        let wall = Wall()
        let (guest, _) = try await Self.timedGuest(clock: clock, wall: wall)

        guest.appWentAway()
        wall.advance(5)
        guest.appCameBack()
        // Long enough on screen, with no word of a dead link, to know it lived.
        wall.advance(40)
        guest.appWentAway()
        wall.advance(5)
        guest.appCameBack()

        #expect(guest.isMatchOver == false)
        #expect(guest.winner == nil)
        guest.leave()
    }

    @Test(
        "One link dies: whichever window closes first, both devices name the same winner",
        arguments: [true, false])
    func bothDevicesNameTheSameWinner(hostFirst: Bool) async throws {
        let table = try await Flow.dealtTable()

        // The guest's link is the one that died.
        table.hostWire.drop(Self.bob)
        table.guestWire.drop(Self.bob)
        table.guestWire.drop(Self.alice)
        try await Terminal.waitUntil("both windows") {
            table.hostClock.requested.contains(Self.window)
                && table.guestClock.requested.contains(Self.window)
        }
        let order = hostFirst ? [table.hostClock, table.guestClock] : [table.guestClock, table.hostClock]
        for clock in order {
            clock.release(Self.window)
            try await Terminal.settle()
        }

        #expect(table.host.winner == Self.alice)
        #expect(table.guest.winner == Self.alice)
        await table.leave()
    }

    @Test("A player back after the other side's window closed is told they lost")
    func aLateReturnIsToldTheResult() async throws {
        var table = try await Flow.dealtTable()

        table.hostWire.drop(Self.bob)
        try await Terminal.waitUntil("the host's window") {
            table.hostClock.requested.contains(Self.window)
        }
        table.hostClock.release(Self.window)
        try await Terminal.waitUntil("the host's win") { table.host.winner == Self.alice }
        let saidBefore = await table.hostWire.count

        // The guest thinks it was never gone. The host tells it otherwise.
        table.hostWire.restore(Self.bob)
        try await Terminal.waitUntil("the result to be said") {
            await table.hostWire.count > saidBefore
        }
        await table.hostToGuest()
        try await Terminal.waitUntil("the guest to hear it") { table.guest.isMatchOver }

        #expect(table.guest.winner == Self.alice)
        #expect(table.guest.endedByDisconnect)
        #expect(table.guest.winningPlacements == nil)
        await table.leave()
    }

    // MARK: - A2a: five minutes, then void

    @Test("A pause that runs its whole limit voids the match on both devices")
    func theLimitVoidsThePausedMatch() async throws {
        #expect(MatchSession.pauseLimitSeconds == 300)
        let wall = Wall()
        var table = try await Pause.pausedTable(now: { wall.date })

        try await Terminal.waitUntil("the host's limit") {
            table.hostClock.requested.contains(Self.limit)
        }
        // Until that one wait is handed out, the match is paused and alive.
        #expect(table.host.isPaused)
        #expect(table.host.isMatchOver == false)
        #expect(table.guest.isMatchOver == false)

        wall.advance(TimeInterval(MatchSession.pauseLimitSeconds))
        table.hostClock.release(Self.limit)
        try await Terminal.waitUntil("the host to void") { table.host.isVoided }
        await table.hostToGuest()
        try await Terminal.waitUntil("the guest to void") { table.guest.isVoided }

        for session in [table.host, table.guest] {
            #expect(session.isMatchOver)
            #expect(session.winner == nil)
            #expect(session.endedByDisconnect == false)
        }
        #expect(await table.hostWire.wire.contains(.matchVoided))

        // Both boards still cross, so both players can look.
        await table.guestToHost()
        try await Terminal.waitUntil("the boards to cross") {
            table.host.peerFinalBoards[Self.bob] != nil
                && table.guest.peerFinalBoards[Self.alice] != nil
        }
        await table.leave()
    }

    @Test("A guest that never hears the void reaches it by its own clock")
    func theGuestVoidsByItsOwnClock() async throws {
        let wall = Wall()
        let table = try await Pause.pausedTable(now: { wall.date })
        let fallback = Duration.seconds(
            MatchSession.pauseLimitSeconds + MatchSession.pauseVoidMarginSeconds)

        try await Terminal.waitUntil("the guest's own limit") {
            table.guestClock.requested.contains(fallback)
        }
        wall.advance(TimeInterval(MatchSession.pauseLimitSeconds + MatchSession.pauseVoidMarginSeconds))
        table.guestClock.release(fallback)
        try await Terminal.waitUntil("the guest to void") { table.guest.isVoided }

        #expect(table.guest.winner == nil)
        // Only the device that runs the pool says so on the wire.
        #expect(await table.guestWire.wire.contains(.matchVoided) == false)
        await table.leave()
    }

    @Test("A void from the device that runs the pool is believed only while paused")
    func aVoidOutsideAPauseIsDropped() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)

        wire.deliver(.matchVoided)
        try await Terminal.settle()

        #expect(guest.isVoided == false)
        #expect(guest.isMatchOver == false)
        guest.leave()
    }

    @Test("The limit running out while a player is gone leaves it to the drop")
    func theLimitWaitsOnADrop() async throws {
        let wall = Wall()
        let table = try await Pause.pausedTable(now: { wall.date })

        table.hostWire.drop(Self.bob)
        try await Terminal.waitUntil("the host's window") {
            table.hostClock.requested.contains(Self.window)
        }
        wall.advance(TimeInterval(MatchSession.pauseLimitSeconds))
        table.hostClock.release(Self.limit)
        try await Terminal.settle()
        #expect(table.host.isVoided == false)
        #expect(table.host.isMatchOver == false)

        table.hostClock.release(Self.window)
        try await Terminal.waitUntil("the forfeit") { table.host.isMatchOver }
        #expect(table.host.winner == Self.alice)
        #expect(table.host.isVoided == false)
        await table.leave()
    }

    // MARK: - A2b: resume stops the clock

    @Test("Resuming stops the clock, and the next pause gets a whole new one")
    func resumeStopsTheClock() async throws {
        let wall = Wall()
        var table = try await Pause.pausedTable(now: { wall.date })
        var decisions = 2
        var guestVotes = 1
        try await Pause.vote(Self.bob, false, at: &table, decisions: &decisions, guestVotes: &guestVotes)
        try await Pause.vote(Self.alice, false, at: &table, decisions: &decisions, guestVotes: &guestVotes)
        #expect(table.host.isPaused == false)
        #expect(table.host.pauseDeadline == nil)
        #expect(table.guest.pauseDeadline == nil)

        // The first pause's sleepers, woken late, with a whole limit gone by.
        wall.advance(TimeInterval(MatchSession.pauseLimitSeconds))
        table.hostClock.release(Self.limit)
        table.guestClock.releaseAll()
        try await Terminal.settle()
        #expect(table.host.isVoided == false)
        #expect(table.guest.isVoided == false)
        #expect(table.host.isMatchOver == false)

        try await Pause.vote(Self.bob, true, at: &table, decisions: &decisions, guestVotes: &guestVotes)
        try await Pause.vote(Self.alice, true, at: &table, decisions: &decisions, guestVotes: &guestVotes)
        try await Terminal.waitUntil("a second whole limit") {
            table.hostClock.requested.filter { $0 == Self.limit }.count == 2
        }
        #expect(table.host.isVoided == false)
        await table.leave()
    }

    // MARK: - A2c: two clocks, one time

    @Test("Both devices count down to the same moment, and a reconnect does not move it")
    func bothClocksAgree() async throws {
        var table = try await Pause.pausedTable()
        let host = try #require(table.host.pauseDeadline)
        let guest = try #require(table.guest.pauseDeadline)
        #expect(abs(host.timeIntervalSince(guest)) <= 2)

        table.hostWire.drop(Self.bob)
        table.guestWire.drop(Self.alice)
        try await Terminal.waitUntil("both to freeze") {
            table.host.peerPresence != .present && table.guest.peerPresence != .present
        }
        table.hostWire.restore(Self.bob)
        table.guestWire.restore(Self.alice)
        try await Terminal.waitUntil("both to return") {
            table.host.peerPresence == .present && table.guest.peerPresence == .present
        }
        await table.hostToGuest()
        await table.guestToHost()
        try await Terminal.settle()

        #expect(table.host.isPaused)
        #expect(table.guest.isPaused)
        #expect(table.host.pauseDeadline == host)
        #expect(table.guest.pauseDeadline == guest)
        await table.leave()
    }

    // MARK: - A2e: solo has no limit

    @Test("A local pause, the solo kind, has no limit")
    func aLocalPauseHasNoLimit() async throws {
        let table = try await Flow.dealtTable()

        table.host.setPausedLocally(true)
        try await Terminal.settle()

        #expect(table.host.isPaused)
        #expect(table.host.pauseDeadline == nil)
        #expect(table.hostClock.requested.contains(Self.limit) == false)
        await table.leave()
    }
}
