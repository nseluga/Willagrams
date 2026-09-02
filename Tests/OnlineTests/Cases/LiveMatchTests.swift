//
//  LiveMatchTests.swift
//  OnlineTests
//
//  Item 7: the call site every other item in this lane is a fragment of.
//
//  Two `SupabaseBackend`s, two fresh anonymous users, `OnlineMatch.host` and
//  `OnlineMatch.join`, a real realtime channel between them, two real
//  `MatchSession`s, and the real `MatchOutcomeRecorder` writing through
//  PostgREST. Nothing in this file is faked; if the adapter, the façade and the
//  session disagree anywhere, this is where it shows.
//
//  Guardrails this file holds to:
//  - No row is seeded by hand. Every `matches`, `match_players` and `profiles`
//    row read back here was written by the client under test.
//  - Both sessions `leave()` on the way out, so no channel subscription is left
//    dangling when the case finishes.
//  - Gated on `LiveProject.isEnabled`, so with `WILLAGRAMS_LIVE_TESTS` unset it
//    is reported as skipped and never as passed.
//
//  What it asserts is not written here: it is `WholeMatchScript`, which the
//  offline suite in that same file plays too. That is deliberate — with the gate
//  unset the offline half is the only thing checking these rules, and it must be
//  checking the same ones.
//

import Foundation
import PostgREST
import Testing
import WillagramsRules
@testable import Online

@Suite("A whole match, live project")
struct LiveMatchTests {

    /// Two devices, two anonymous users, one project.
    ///
    /// A backend per side: the two halves are different signed-in users and one
    /// client holds one session.
    @MainActor
    static func twoDevices() async throws -> (
        creatorBackend: SupabaseBackend, creatorProfile: Profile, creator: OnlineMatch,
        guestBackend: SupabaseBackend, guestProfile: Profile, guest: OnlineMatch
    ) {
        let creatorBackend = LiveProject.fresh()
        let creatorProfile = try await creatorBackend.signInAnonymously()
        let guestBackend = LiveProject.fresh()
        let guestProfile = try await guestBackend.signInAnonymously()

        // `EveryWordIsReal` rather than the bundle: a SwiftPM run has no bundle
        // to load the real list from, and nothing this script does is a word.
        let creator = try await OnlineMatch.host(
            options: .standard,
            backend: creatorBackend,
            dictionary: EveryWordIsReal(),
            sleepFor: { _ in }
        )
        let guest = try await OnlineMatch.join(
            code: creator.inviteCode,
            backend: guestBackend,
            dictionary: EveryWordIsReal(),
            sleepFor: { _ in }
        )
        return (creatorBackend, creatorProfile, creator, guestBackend, guestProfile, guest)
    }

    /// Waits for `condition`, bounded by how long a match already tolerates a
    /// silent peer.
    ///
    /// Derived, not a literal: `MatchSession.reconnectGraceSeconds` is the window
    /// the game itself gives a peer to be heard from, so anything that has not
    /// happened inside it is something the match would already have given up on.
    @MainActor
    static func until(_ label: String, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(TimeInterval(MatchSession.reconnectGraceSeconds))
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out waiting for: \(label)")
    }

    /// The same window, for a condition that has to go and read a row to answer.
    /// The recorder's writes are fire-and-forget from the session's point of
    /// view, so the row is what says they landed.
    @MainActor
    static func untilRow(_ label: String, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(MatchSession.reconnectGraceSeconds))
        while Date() < deadline {
            if try await condition() { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        Issue.record("timed out waiting for: \(label)")
    }

    /// The `matches` row as the database now holds it. By id — the invite code
    /// is deliberately never queried from the client.
    static func matchRow(_ id: UUID, as backend: SupabaseBackend) async throws -> MatchRecord {
        let rows = try await backend.rest.from("matches")
            .select()
            .eq("id", value: id.uuidString)
            .limit(1)
            .execute()
            .data
        guard let record = try SupabaseBackend.matchRecord(fromRows: rows) else {
            throw BackendError.notFound
        }
        return record
    }

    /// `done when:` #1 and #2, over the wire.
    @Test(
        "Two devices play a whole match end to end, and the rows land",
        .enabled(if: LiveProject.isEnabled)
    )
    @MainActor
    func aWholeMatchOverTheWire() async throws {
        let devices = try await Self.twoDevices()
        let creator = devices.creator
        let guest = devices.guest

        // Fresh anonymous rows, read before anything records: the deltas the
        // script asserts are against these, not against literals.
        let creatorBefore = try await devices.creatorBackend.profile(id: devices.creatorProfile.id)
        let guestBefore = try await devices.guestBackend.profile(id: devices.guestProfile.id)

        // Presence, not the membership row, is what fills a lobby.
        await Self.until("two in the creator's lobby") { creator.lobby.count == 2 }
        await Self.until("two in the guest's lobby") { guest.lobby.count == 2 }
        #expect(Set(creator.lobby) == Set(guest.lobby))

        let guestSession = try await guest.awaitStart()
        let creatorSession = try await creator.start()
        // `defer`, not a trailing pair of calls: a `try` below that throws would
        // otherwise walk out of this case leaving two channels subscribed, which
        // is the guardrail this file holds to.
        defer {
            creatorSession.leave()
            guestSession.leave()
        }
        await Self.until("the creator is playing") { creatorSession.state.status == .playing }
        await Self.until("the guest is playing") { guestSession.state.status == .playing }
        #expect(creatorSession.roster == guestSession.roster)

        let winner = try await WholeMatchScript.play(
            creator: creatorSession, guest: guestSession, until: Self.until
        )

        // Criterion 1.
        WholeMatchScript.expectBothFinished(
            creator: creatorSession, guest: guestSession, winner: winner)
        #expect(winner == guest.localPlayer)

        // Criterion 2, first half. Read as the creator, which is the only device
        // `matches_update_host` lets write it.
        try await Self.untilRow("the matches row is finished") {
            try await Self.matchRow(creator.record.id, as: devices.creatorBackend).status == .finished
        }
        WholeMatchScript.expectFinishedRow(
            try await Self.matchRow(creator.record.id, as: devices.creatorBackend),
            winner: devices.guestProfile.id
        )

        // Criterion 2, second half.
        try await Self.untilRow("both stats rows are written") {
            let creatorNow = try await devices.creatorBackend.profile(id: devices.creatorProfile.id)
            let guestNow = try await devices.guestBackend.profile(id: devices.guestProfile.id)
            return creatorNow.matchesPlayed == creatorBefore.matchesPlayed + 1
                && guestNow.matchesPlayed == guestBefore.matchesPlayed + 1
        }
        WholeMatchScript.expectStats(
            "creator",
            before: creatorBefore,
            after: try await devices.creatorBackend.profile(id: devices.creatorProfile.id),
            won: false,
            tilesPlaced: WholeMatchScript.creatorPlacements
        )
        WholeMatchScript.expectStats(
            "guest",
            before: guestBefore,
            after: try await devices.guestBackend.profile(id: devices.guestProfile.id),
            won: true,
            tilesPlaced: WholeMatchScript.guestPlacements
        )

        #expect(creator.recorder?.lastError == nil)
        #expect(guest.recorder?.lastError == nil)
    }
}
