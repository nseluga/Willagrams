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
