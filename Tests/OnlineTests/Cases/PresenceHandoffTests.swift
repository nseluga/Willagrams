import Foundation
import Testing
import WillagramsRules
@testable import Online

/// Presence ownership across the lobby-to-session handoff.
///
/// `MatchTransport.peerConnectionStates` is a single-subscription stream: the
/// façade's lobby pump is its one consumer for the object's life. The session
/// is fed by forwarding, not by a second `for await` on the same stream — a
/// second subscription on a stream whose first consumer was cancelled opens on
/// an already-finished stream and never delivers anything.
///
/// Every case here drives the FAÇADE path — `OnlineMatch` builds the session,
/// as the app does. A hand-built `MatchSession` exercises the path that already
/// worked and proves nothing about the one that ships.
@MainActor
@Suite("Presence survives the lobby-to-session handoff")
struct PresenceHandoffTests {

    typealias Fixture = OnlineMatchOfflineTests.Fixture

    static func fixture() async throws -> Fixture {
        try await OnlineMatchOfflineTests.fixture(creatorToken: "A", guestToken: "B")
    }

    /// The same pair, on a clock that never comes back, so a reconnect window
    /// is still open when the test looks at it. `.gone` is terminal for a live
    /// match, so a return can only be observed inside the grace.
    static func fixtureWithAnOpenWindow() async throws -> Fixture {
        try await OnlineMatchOfflineTests.fixture(
            creatorToken: "A",
            guestToken: "B",
            sleepFor: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
    }

    static func until(_ label: String, _ condition: @MainActor () -> Bool) async {
        await OnlineMatchOfflineTests.until(label, condition)
    }

    /// Fills the lobby and hands back the session the creator's Start built.
    static func startedSession(_ f: Fixture) async throws -> MatchSession {
        f.creatorWire.announce(.connected(f.guestPlayer))
        await until("the creator sees the guest") { f.creator.lobby.count == 2 }
        return try await f.creator.start(options: OnlineMatchOfflineTests.options)
    }

    // MARK: - The criterion

    @Test("A peer that drops after the façade built the session is reported gone")
    func facadeBuiltSessionSeesThePeerDrop() async throws {
        let f = try await Self.fixture()
        let session = try await Self.startedSession(f)
        #expect(session.presence(of: f.guestPlayer) == .present)

        f.creatorWire.announce(.disconnected(f.guestPlayer))

        await Self.until("the session sees the drop") {
            session.presence(of: f.guestPlayer) != .present
        }
        // The grace runs on this suite's no-op `sleepFor`, so the window that a
        // device spends thirty seconds in resolves here in a few scheduler
        // turns. A peer that never comes back ends up `.gone` — fail-OPEN if it
        // regresses, which is why it is asserted by value rather than inferred
        // from "not present".
        await Self.until("the grace runs out") {
            session.presence(of: f.guestPlayer) == .gone
        }
        #expect(session.presence(of: f.guestPlayer) == .gone)
    }

    @Test("A peer that comes back after the handoff is present again")
    func facadeBuiltSessionSeesThePeerReturn() async throws {
        let f = try await Self.fixtureWithAnOpenWindow()
        let session = try await Self.startedSession(f)

        f.creatorWire.announce(.disconnected(f.guestPlayer))
        await Self.until("the session sees the drop") {
            if case .reconnecting = session.presence(of: f.guestPlayer) { return true }
            return false
        }
        f.creatorWire.announce(.connected(f.guestPlayer))
        await Self.until("the session sees the return") {
            session.presence(of: f.guestPlayer) == .present
        }
        #expect(session.presence(of: f.guestPlayer) == .present)
    }

    // MARK: - The join path's own window

    /// The guest's handover is not instantaneous: `awaitStart()` awaits
    /// `backend.players` before `makeSession` assigns the session, and the pump
    /// has been forwarding since `init`. A host that leaves in that window is
    /// seen by the pump and has nowhere to land, and a real transport dedupes
    /// presence, so it is never announced again.
    ///
    /// Fail-OPEN, and permanent when it hits: the guest would sit on a match
    /// against a host that had already gone, waiting for a `.start` nobody was
    /// left to send, with `presence(of:)` reading absent as present for ever.
    /// The host path cannot reach this — `start()` refuses a lobby that is not
    /// two — so it needs its own case.
    @Test("A host that leaves before the guest's session exists is still reported gone")
    func aLeaveObservedBeforeTheSessionExistsIsNotLost() async throws {
        let f = try await Self.fixture()

        f.guestWire.announce(.connected(f.creatorPlayer))
        await Self.until("the guest sees the host") { f.guest.lobby.count == 2 }
        f.guestWire.announce(.disconnected(f.creatorPlayer))
        await Self.until("the guest sees the host go") { f.guest.lobby.count == 1 }

        // Only now does the session exist. The leave happened before it did.
        let session = try await f.guest.awaitStart()
        await Self.until("the session is told what the pump already saw") {
            session.presence(of: f.creatorPlayer) == .gone
        }
        #expect(session.presence(of: f.creatorPlayer) == .gone)
    }

    /// The other side of that replay, and the reason it records only an
    /// observed leave: a peer whose presence has not synced yet is absent, not
    /// gone. Declaring it gone at handover would end every match that opened
    /// before presence caught up.
    @Test("A peer never seen leaving is not declared gone at the handover")
    func anUnseenPeerIsNotDeclaredGone() async throws {
        let f = try await Self.fixture()

        let session = try await f.guest.awaitStart()
        for _ in 0 ..< 200 { await Task.yield() }
        #expect(session.presence(of: f.creatorPlayer) == .present)
    }

    /// A peer that left and came back before the session existed is not gone
    /// either: the replay tracks the latest observed state, not every edge.
    @Test("A peer that returned before the handover is not replayed as gone")
    func aReturnBeforeTheHandoverClearsTheReplay() async throws {
        let f = try await Self.fixture()

        f.guestWire.announce(.connected(f.creatorPlayer))
        await Self.until("the guest sees the host") { f.guest.lobby.count == 2 }
        f.guestWire.announce(.disconnected(f.creatorPlayer))
        await Self.until("the guest sees the host go") { f.guest.lobby.count == 1 }
        f.guestWire.announce(.connected(f.creatorPlayer))
        await Self.until("the guest sees the host again") { f.guest.lobby.count == 2 }

        let session = try await f.guest.awaitStart()
        for _ in 0 ..< 200 { await Task.yield() }
        #expect(session.presence(of: f.creatorPlayer) == .present)
    }

    // MARK: - A session that has left takes no more presence

    /// `leave()` ends the match here, and a state forwarded afterwards must not
    /// move it. A self-subscribed session stops hearing when its own pump is
    /// cancelled; a forwarded one is fed by the façade's pump, which is still
    /// running for the one line between `session.leave()` and `match.leave()`
    /// in `OnlineOpponent.leave()`.
    ///
    /// Pinned as a property rather than left to the absorbing guards in
    /// `peerDropped` and `peerReturned` that also cover it: three independent
    /// things have to stay true for a left match not to come back to life, and
    /// none of them said so out loud before this case.
    @Test("A state forwarded after leave() cannot bring a left match back")
    func aLeftSessionIgnoresForwardedPresence() async throws {
        let f = try await Self.fixture()
        let session = try await Self.startedSession(f)

        f.creatorWire.announce(.disconnected(f.guestPlayer))
        await Self.until("the peer is gone") {
            session.presence(of: f.guestPlayer) == .gone
        }

        session.leave()
        #expect(session.presence(of: f.guestPlayer) == .gone)

        // Straight in, the way the still-live façade pump would deliver it.
        session.receive(peerConnection: .connected(f.guestPlayer))
        for _ in 0 ..< 200 { await Task.yield() }
        #expect(
            session.presence(of: f.guestPlayer) == .gone,
            "a left match was revived by a forwarded state")
    }

    // MARK: - The lobby keeps working across the same handoff

    @Test("The lobby roster still adds and removes players across the handoff")
    func lobbyRosterSurvivesTheHandoff() async throws {
        let f = try await Self.fixture()
        let session = try await Self.startedSession(f)
        #expect(f.creator.lobby.count == 2)

        f.creatorWire.announce(.disconnected(f.guestPlayer))
        await Self.until("the open seat empties after the handoff") {
            f.creator.lobby == [f.creatorPlayer]
        }

        f.creatorWire.announce(.connected(f.guestPlayer))
        await Self.until("the open seat fills again after the handoff") {
            f.creator.lobby.count == 2
        }
        #expect(Set(f.creator.lobby) == [f.creatorPlayer, f.guestPlayer])
        #expect(f.creator.lobby.first == f.creatorPlayer)

        // The local player is still not removable from their own lobby, and a
        // state naming this device never reaches the session's roster logic.
        f.creatorWire.announce(.disconnected(f.creatorPlayer))
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(f.creator.lobby.contains(f.creatorPlayer))
        #expect(session.presence(of: f.creatorPlayer) == .present)
    }
}
