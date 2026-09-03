import Foundation
import PostgREST
import Testing
import WillagramsRules
@testable import Online

/// The outcome recorder against the real project — the half of this item that
/// no double can answer: whether `matches_update_host` and `profiles_update_self`
/// actually let these writes through, and whether the row constraints accept
/// what the recorder sends.
///
/// Gated by `LiveProject.isEnabled`, so with the flag or the key missing every
/// case reports as skipped, never as passed. Each case signs in its own fresh
/// anonymous users and depends on no row another case left behind.
@Suite("Match outcome recorder, live project")
struct MatchOutcomeRecorderLiveTests {

    private static func signedIn() async throws -> (SupabaseBackend, Profile) {
        let backend = LiveProject.fresh()
        return (backend, try await backend.signInAnonymously())
    }

    /// The `matches` row as the database now holds it. By id — never by invite
    /// code, which `SupabaseMatchesTests.inviteCodeIsNeverQueriedFromTheClient`
    /// keeps out of the client for good reason.
    private static func matchRow(_ id: UUID, as backend: SupabaseBackend) async throws -> MatchRecord {
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

    /// Two live sessions on one in-memory wire, already `.playing`.
    ///
    /// The transport is fake on purpose: what is under test here is the writes,
    /// and a realtime channel between two anonymous users is item 6's subject,
    /// not this one's.
    @MainActor
    private static func playingPair(
        creator: PlayerID, guest: PlayerID
    ) async throws -> (creator: MatchSession, guest: MatchSession) {
        let (first, second) = FakeTransport.pair(creator, guest)
        let creatorSession = MatchSession(
            transport: first, peerPlayerID: guest, dictionary: EveryWordIsReal(), sleepFor: { _ in }
        )
        let guestSession = MatchSession(
            transport: second, peerPlayerID: creator, dictionary: EveryWordIsReal(), sleepFor: { _ in }
        )
        // Whoever the roster elects opens the match; that election is by id and
        // has nothing to do with who created the row.
        let opener = HostPool.host(of: creatorSession.roster) == creator ? creatorSession : guestSession
        opener.startMatch(seed: 77, startingHandSize: 0, countdownSeconds: 0)
        try await MatchOutcomeRecorderTests.waitUntil("both sessions playing") {
            creatorSession.state.status == .playing && guestSession.state.status == .playing
        }
        return (creatorSession, guestSession)
    }

    /// `done when:` #1 and #2, end to end on the real rows.
    @Test(
        "A creator-started match the guest wins lands as finished with both timestamps",
        .enabled(if: LiveProject.isEnabled)
    )
    func creatorStartedMatchTheGuestWins() async throws {
        let (creatorBackend, creatorProfile) = try await Self.signedIn()
        let (guestBackend, guestProfile) = try await Self.signedIn()

        let record = try await creatorBackend.createMatchRow(options: .standard, seed: 77)
        _ = try await guestBackend.joinMatchRow(inviteCode: record.inviteCode)

        let (creatorSession, guestSession) = try await Self.playingPair(
            creator: creatorProfile.playerID, guest: guestProfile.playerID
        )

        let creatorRecorder = await MatchOutcomeRecorder(
            record: record, localPlayer: creatorProfile.playerID, session: creatorSession,
            store: creatorBackend.outcomeStore()
        )
        let guestRecorder = await MatchOutcomeRecorder(
            record: record, localPlayer: guestProfile.playerID, session: guestSession,
            store: guestBackend.outcomeStore()
        )
        await creatorRecorder.sync()
        await guestRecorder.sync()

        // Giving up hands the win to the only other player.
        await MainActor.run { _ = creatorSession.resign() }
        try await MatchOutcomeRecorderTests.waitUntil("the guest has won") {
            await guestSession.winner == guestProfile.playerID
                && creatorSession.winner == guestProfile.playerID
        }
        await creatorRecorder.sync()
        await guestRecorder.sync()

        #expect(await creatorRecorder.lastError.map { String(describing: $0) } == nil)
        #expect(await guestRecorder.lastError.map { String(describing: $0) } == nil)

        let stored = try await Self.matchRow(record.id, as: creatorBackend)
        #expect(stored.status == .finished)
        #expect(stored.winnerID == guestProfile.id)
        #expect(stored.startedAt != nil)
        #expect(stored.finishedAt != nil)

        let creatorAfter = try await creatorBackend.profile(id: creatorProfile.id)
        #expect(creatorAfter.matchesPlayed == 1)
        #expect(creatorAfter.matchesWon == 0)
        #expect(creatorAfter.fastestWinSeconds == nil)

        let guestAfter = try await guestBackend.profile(id: guestProfile.id)
        #expect(guestAfter.matchesPlayed == 1)
        #expect(guestAfter.matchesWon == 1)
        #expect((guestAfter.fastestWinSeconds ?? 0) > 0)
    }

    /// `done when:` #3, and the RLS half of the guardrail: the guest above got
    /// its `matches` row written by the *creator*, not by itself.
    @Test(
        "A match whose session never plays stays in lobby with both stats untouched",
        .enabled(if: LiveProject.isEnabled)
    )
    func aMatchThatNeverStartsIsUntouched() async throws {
        let (creatorBackend, creatorProfile) = try await Self.signedIn()
        let (guestBackend, guestProfile) = try await Self.signedIn()

        let record = try await creatorBackend.createMatchRow(options: .standard, seed: 9)
        _ = try await guestBackend.joinMatchRow(inviteCode: record.inviteCode)

        // Built, never started. The sessions sit in `.countdown`.
        let (first, second) = await MainActor.run {
            FakeTransport.pair(creatorProfile.playerID, guestProfile.playerID)
        }
        let creatorSession = await MatchSession(
            transport: first, peerPlayerID: guestProfile.playerID,
            dictionary: EveryWordIsReal(), sleepFor: { _ in }
        )
        let guestSession = await MatchSession(
            transport: second, peerPlayerID: creatorProfile.playerID,
            dictionary: EveryWordIsReal(), sleepFor: { _ in }
        )

        let creatorRecorder = await MatchOutcomeRecorder(
            record: record, localPlayer: creatorProfile.playerID, session: creatorSession,
            store: creatorBackend.outcomeStore()
        )
        let guestRecorder = await MatchOutcomeRecorder(
            record: record, localPlayer: guestProfile.playerID, session: guestSession,
            store: guestBackend.outcomeStore()
        )
        for _ in 0 ..< 3 {
            await creatorRecorder.sync()
            await guestRecorder.sync()
        }

        let stored = try await Self.matchRow(record.id, as: creatorBackend)
        #expect(stored.status == .lobby)
        #expect(stored.startedAt == nil)
        #expect(stored.finishedAt == nil)
        #expect(stored.winnerID == nil)

        for backend in [creatorBackend, guestBackend] {
            let id = backend === creatorBackend ? creatorProfile.id : guestProfile.id
            let after = try await backend.profile(id: id)
            #expect(after.matchesPlayed == 0)
            #expect(after.matchesWon == 0)
            #expect(after.tilesPlaced == 0)
            #expect(after.fastestWinSeconds == nil)
        }
    }

    /// The refusal the client gate exists because of: `matches_update_host`
    /// hides the row from a guest, and PostgREST reports that as *zero rows
    /// patched* rather than as an error. A guest that skipped the gate would
    /// read success and write nothing — which is why the recorder never gets
    /// here, and why this case pins the behaviour rather than assuming it.
    @Test(
        "A guest's own matches update is silently refused, not an error",
        .enabled(if: LiveProject.isEnabled)
    )
    func rlsRefusesAGuestSilently() async throws {
        let (creatorBackend, _) = try await Self.signedIn()
        let (guestBackend, guestProfile) = try await Self.signedIn()

        let record = try await creatorBackend.createMatchRow(options: .standard, seed: 11)
        _ = try await guestBackend.joinMatchRow(inviteCode: record.inviteCode)

        let store = await guestBackend.outcomeStore()
        try await store.updateMatch(
            record.id, .finished(finishedAt: Date(), winnerID: guestProfile.id))

        let stored = try await Self.matchRow(record.id, as: creatorBackend)
        #expect(stored.status == .lobby)
        #expect(stored.winnerID == nil)
    }
}
