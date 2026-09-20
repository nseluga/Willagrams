import Foundation
import Testing
import WillagramsRules
@testable import Online

/// The half of the façade that only two real clients on a real channel can
/// decide: that presence actually arrives, that a `.start` crosses the wire, and
/// that a refused start leaves the `matches` row where the offline suite says it
/// does.
///
/// Same gate as every other live case — `LiveProject.isEnabled`. Unset, these
/// report as skipped, and the offline suite is what still holds the rules.
@Suite("Online match façade, live project")
struct OnlineMatchLiveTests {

    /// Two devices, two anonymous users, one project.
    ///
    /// A `SupabaseBackend` per side rather than one shared: the two halves are
    /// different signed-in users, and a single client holds one session.
    @MainActor
    static func twoDevices() async throws -> (creator: OnlineMatch, guest: OnlineMatch) {
        let creatorBackend = LiveProject.fresh()
        _ = try await creatorBackend.signInAnonymously()
        let guestBackend = LiveProject.fresh()
        _ = try await guestBackend.signInAnonymously()

        let creator = try await OnlineMatch.host(
            options: .standard,
            backend: creatorBackend,
            dictionary: EnableWordList(words: []),
            sleepFor: { _ in }
        )
        let guest = try await OnlineMatch.join(
            code: creator.inviteCode,
            backend: guestBackend,
            dictionary: EnableWordList(words: []),
            sleepFor: { _ in }
        )
        return (creator, guest)
    }

    /// Waits for `condition`, bounded by how long a match will already tolerate a
    /// silent peer.
    ///
    /// Derived, not a literal: `MatchSession.reconnectGraceSeconds` is the window
    /// the game itself gives a peer to be heard from, so presence that has not
    /// arrived inside it is presence the match would already have given up on.
    @MainActor
    static func until(_ label: String, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(TimeInterval(MatchSession.reconnectGraceSeconds))
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out waiting for: \(label)")
    }

    @Test(
        "A refused start leaves the matches row joinable, so it is still in lobby",
        .enabled(if: LiveProject.isEnabled)
    )
    @MainActor
    func aRefusedStartLeavesTheRowInLobby() async throws {
        let creatorBackend = LiveProject.fresh()
        _ = try await creatorBackend.signInAnonymously()
        let creator = try await OnlineMatch.host(
            options: .standard,
            backend: creatorBackend,
            dictionary: EnableWordList(words: []),
            sleepFor: { _ in }
        )

        // Nobody has connected, so the lobby holds one player: this device.
        await #expect(throws: OnlineMatchError.lobbyNotReady(1)) {
            _ = try await creator.start()
        }

        // `joinMatch` refuses anything that is not `lobby`, so a join that still
        // succeeds is the row's status read back through the only door the
        // protocol has.
        let guestBackend = LiveProject.fresh()
        _ = try await guestBackend.signInAnonymously()
        let record = try await guestBackend.joinMatch(inviteCode: creator.inviteCode)
        #expect(record.status == .lobby)
        #expect(record.id == creator.record.id)
    }

    @Test(
        "Both devices see a full lobby, then both reach playing off one seed",
        .enabled(if: LiveProject.isEnabled)
    )
    @MainActor
    func bothDevicesReachPlaying() async throws {
        let (creator, guest) = try await Self.twoDevices()

        // Criterion 3: presence, not the membership row, is what fills a lobby.
        await Self.until("the guest sees two") { guest.lobby.count == 2 }
        await Self.until("the creator sees the guest") { creator.lobby.count == 2 }
        #expect(creator.lobby.contains(creator.localPlayer))
        #expect(guest.lobby.contains(guest.localPlayer))
        #expect(Set(creator.lobby) == Set(guest.lobby))

        let guestSession = try await guest.awaitStart()
        let creatorSession = try await creator.start()

        await Self.until("the creator is playing") { creatorSession.state.status == .playing }
        await Self.until("the guest is playing") { guestSession.state.status == .playing }

        #expect(creatorSession.roster == guestSession.roster)
        #expect(creatorSession.roster == creatorSession.roster.sorted { $0.rawValue < $1.rawValue })
        #expect(creatorSession.roster.count == 2)
        #expect(creatorSession.options == guestSession.options)
        #expect(creatorSession.options == MatchOptions.standard)
        #expect(creatorSession.startingHandSize == OnlineMatch.startingHandSize)
        #expect(guestSession.startingHandSize == OnlineMatch.startingHandSize)

        // One seed, one deal: both racks come off the host's pool, and a device
        // that had drawn its own seed would not be dealt from it at all.
        await Self.until("the guest is dealt in") { guestSession.state.hand.count == 21 }
        #expect(creatorSession.state.hand.count == 21)

        creatorSession.leave()
        guestSession.leave()
    }
}
