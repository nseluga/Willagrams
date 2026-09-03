import Foundation
import Testing
import WillagramsRules
@testable import Online

/// Everything the outcome recorder decides on its own, against a real
/// `MatchSession` on a real `FakeTransport` and a recording database double.
///
/// The double is the point. Each rule here — "exactly once", "the guest writes
/// nothing", "no counter ever falls" — is invisible from outside a PostgREST
/// call, and looks exactly like a clean run once it stops firing. Recording the
/// calls is what makes the absent ones assertable.
@Suite("Match outcome recorder, offline")
@MainActor
struct MatchOutcomeRecorderTests {

    // MARK: - Fixtures

    static let aliceUUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let bobUUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let matchUUID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    /// `alice` sorts first, so `alice` is the host election's winner and the
    /// only device that opens the match.
    static var alice: PlayerID { PlayerID(rawValue: aliceUUID.uuidString) }
    static var bob: PlayerID { PlayerID(rawValue: bobUUID.uuidString) }

    /// A lobby row exactly as `createMatch` left it: `alice` created it, so
    /// `alice` is the one device `matches_update_host` will let write.
    static func lobby(hostID: UUID = aliceUUID) -> MatchRecord {
        MatchRecord(
            id: matchUUID,
            hostID: hostID,
            inviteCode: "ABC123",
            wireVersion: WireFormat.current,
            seed: 77,
            options: .standard,
            status: .lobby,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func profile(
        _ id: UUID,
        played: Int = 0,
        won: Int = 0,
        tiles: Int = 0,
        fastest: Int? = nil
    ) -> Profile {
        Profile(
            id: id,
            displayName: "Player",
            friendCode: "ABCDEFGH",
            createdAt: Date(timeIntervalSince1970: 0),
            matchesPlayed: played,
            matchesWon: won,
            tilesPlaced: tiles,
            fastestWinSeconds: fastest
        )
    }

    /// Two live sessions on one wire, both already `.playing`.
    ///
    /// `countdownSeconds: 0` flips straight to `.playing` inside `startMatch`,
    /// so no clock is involved in getting there and the recorder's own injected
    /// clock is the only time in these tests.
    static func playingPair(handSize: Int = 0) async throws -> (host: MatchSession, guest: MatchSession) {
        let (first, second) = FakeTransport.pair(alice, bob)
        let host = MatchSession(
            transport: first, peerPlayerID: bob, dictionary: EveryWordIsReal(), sleepFor: { _ in }
        )
        let guest = MatchSession(
            transport: second, peerPlayerID: alice, dictionary: EveryWordIsReal(), sleepFor: { _ in }
        )
        host.startMatch(seed: 77, startingHandSize: handSize, countdownSeconds: 0)
        try await waitUntil("both sessions playing") {
            host.state.status == .playing && guest.state.status == .playing
        }
        return (host, guest)
    }

    static func waitUntil(
        _ what: String,
        _ predicate: @MainActor () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0 ..< 400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    // MARK: - The creator's side of a match the guest wins

    /// `done when:` #1 and half of #2, as far as they can be proved with no
    /// project: the row the creator asks for is `finished`, names the guest,
    /// and carries both timestamps — `started_at` from the `.playing` write and
    /// `finished_at` from this one.
    @Test("The creator closes out the matches row and bumps only its own stats")
    func creatorRecordsTheMatch() async throws {
        let store = RecordingOutcomeStore(profiles: [
            Self.aliceUUID: Self.profile(Self.aliceUUID),
            Self.bobUUID: Self.profile(Self.bobUUID),
        ])
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
        let (host, _) = try await Self.playingPair()

        let recorder = MatchOutcomeRecorder(
            record: Self.lobby(), localPlayer: Self.alice, session: host,
            store: store, now: clock.now
        )
        #expect(recorder.isCreator)

        await recorder.sync()
        #expect(await store.matchUpdates == [.playing(startedAt: Date(timeIntervalSince1970: 1_000))])

        clock.advance(41)
        host.resign()                       // the guest is the last player standing
        try await Self.waitUntil("the host's session is finished") { host.winner == Self.bob }
        await recorder.sync()

        let updates = await store.matchUpdates
        #expect(updates.count == 2)
        #expect(
            updates.last
                == .finished(
                    finishedAt: Date(timeIntervalSince1970: 1_041), winnerID: Self.bobUUID))

        // Its own row, and only its own row.
        let stats = await store.profileUpdates
        #expect(stats.map(\.id) == [Self.aliceUUID])
        #expect(stats.first?.stats.matchesPlayed == 1)
        #expect(stats.first?.stats.matchesWon == 0)
        #expect(stats.first?.stats.fastestWinSeconds == nil)
        #expect(recorder.lastError.map { String(describing: $0) } == nil)
    }

    // MARK: - The guardrail the database cannot enforce for us

    /// `matches_update_host` refuses a guest, but PostgREST reports that
    /// refusal as *zero rows patched* — a 200. A guest that issued the update
    /// would read success, so the only place this is catchable is here, and the
    /// assertion is on the calls the guest's recorder never made.
    ///
    /// Driven through the same entry point the creator's recorder uses, on a
    /// real session that really finished: an inert fixture would prove nothing.
    @Test("A non-creator issues no matches update at all, but still records its own stats")
    func guestNeverWritesTheMatchesRow() async throws {
        let store = RecordingOutcomeStore(profiles: [Self.bobUUID: Self.profile(Self.bobUUID)])
        let clock = TestClock(start: Date(timeIntervalSince1970: 500))
        let (host, guest) = try await Self.playingPair()

        let recorder = MatchOutcomeRecorder(
            record: Self.lobby(), localPlayer: Self.bob, session: guest,
            store: store, now: clock.now
        )
        #expect(!recorder.isCreator)

        await recorder.sync()
        clock.advance(7)
        host.resign()
        try await Self.waitUntil("the guest has won") { guest.winner == Self.bob }
        await recorder.sync()

        #expect(await store.matchUpdates.isEmpty)

        let stats = await store.profileUpdates
        #expect(stats.map(\.id) == [Self.bobUUID])
        #expect(stats.first?.stats.matchesPlayed == 1)
        #expect(stats.first?.stats.matchesWon == 1)
        #expect(stats.first?.stats.fastestWinSeconds == 7)
    }

    // MARK: - Exactly once

    /// An `@Observable` fires as often as the state moves, and a finished match
    /// keeps moving — presence, notes, a late message. Every one of those is
    /// another `sync()`, and the second stats write would be a second match on
    /// the player's record.
    @Test("However often a finished match is observed, each row is written once")
    func writesHappenExactlyOnce() async throws {
        let store = RecordingOutcomeStore(profiles: [Self.aliceUUID: Self.profile(Self.aliceUUID)])
        let (host, _) = try await Self.playingPair()
        let recorder = MatchOutcomeRecorder(
            record: Self.lobby(), localPlayer: Self.alice, session: host,
            store: store, now: TestClock(start: Date(timeIntervalSince1970: 0)).now
        )

        await recorder.sync()
        host.claimWin()
        try await Self.waitUntil("finished") { host.winner == Self.alice }

        for _ in 0 ..< 5 { await recorder.sync() }

        #expect(await store.matchUpdates.filter(\.isFinished).count == 1)
        #expect(await store.profileUpdates.count == 1)
        #expect(await store.reads == 1)
    }

    // MARK: - A match that never started

    /// `done when:` #3. The session sits in `.countdown` and then the match is
    /// abandoned, which is `isMatchOver` with no winner — a shape that must not
    /// be mistaken for a result.
    @Test("A session that never reaches playing leaves the row and both stats untouched")
    func neverPlayingWritesNothing() async throws {
        let store = RecordingOutcomeStore(profiles: [Self.aliceUUID: Self.profile(Self.aliceUUID)])
        let (first, _) = FakeTransport.pair(Self.alice, Self.bob)
        let host = MatchSession(
            transport: first, peerPlayerID: Self.bob, dictionary: EveryWordIsReal(), sleepFor: { _ in }
        )
        #expect(host.state.status != .playing)

        let recorder = MatchOutcomeRecorder(
            record: Self.lobby(), localPlayer: Self.alice, session: host,
            store: store, now: TestClock(start: Date(timeIntervalSince1970: 0)).now
        )

        for _ in 0 ..< 3 { await recorder.sync() }
        host.leave()                       // the match ends with nobody named
        for _ in 0 ..< 3 { await recorder.sync() }
        await recorder.run()               // and the loop returns rather than hanging

        #expect(recorder.startedAt == nil)
        #expect(await store.matchUpdates.isEmpty)
        #expect(await store.profileUpdates.isEmpty)
        #expect(await store.reads == 0)
    }

    /// A peer that simply vanished mid-play hands nobody a win, so there is no
    /// result to record — but the match *did* start, which is the case the
    /// `startedAt` latch alone does not cover.
    @Test("A match that ends with no winner records no result")
    func endingWithoutAWinnerRecordsNothing() async throws {
        let store = RecordingOutcomeStore(profiles: [Self.aliceUUID: Self.profile(Self.aliceUUID)])
        let (host, _) = try await Self.playingPair()
        let recorder = MatchOutcomeRecorder(
            record: Self.lobby(), localPlayer: Self.alice, session: host,
            store: store, now: TestClock(start: Date(timeIntervalSince1970: 0)).now
        )
        await recorder.sync()
        host.leave()
        #expect(host.isMatchOver)
        #expect(host.winner == nil)
        await recorder.run()

        #expect(await store.matchUpdates == [.playing(startedAt: Date(timeIntervalSince1970: 0))])
        #expect(await store.profileUpdates.isEmpty)
    }

    // MARK: - Elapsed

    /// Measured from `.playing` to the finish, not from the recorder's birth
    /// and not from the lobby. The gap before the match opens is deliberately
    /// large: a recorder that started its stopwatch at `init` would report 190,
    /// not 40.
    @Test("Elapsed runs from playing to finished, on the injected clock")
    func elapsedIsMeasuredFromPlaying() async throws {
        let store = RecordingOutcomeStore(profiles: [Self.bobUUID: Self.profile(Self.bobUUID)])
        let clock = TestClock(start: Date(timeIntervalSince1970: 0))
        let (host, guest) = try await Self.playingPair()

        let recorder = MatchOutcomeRecorder(
            record: Self.lobby(), localPlayer: Self.bob, session: guest,
            store: store, now: clock.now
        )
        clock.advance(150)                 // lobby time, which belongs to nobody
        await recorder.sync()
        #expect(recorder.startedAt == Date(timeIntervalSince1970: 150))

        clock.advance(40)
        host.resign()
        try await Self.waitUntil("the guest has won") { guest.winner == Self.bob }
        await recorder.sync()

        #expect(await store.profileUpdates.first?.stats.fastestWinSeconds == 40)
    }

    // MARK: - fastest_win_seconds, all four branches

    @Test("A win lower than the record replaces it")
    func fastestWinLower() {
        #expect(ProfileStats.fastestWin(current: 90, won: true, elapsedSeconds: 30) == 30)
    }

    @Test("A win slower than the record leaves it alone")
    func fastestWinHigher() {
        #expect(ProfileStats.fastestWin(current: 30, won: true, elapsedSeconds: 90) == 30)
        // And equal is not lower: rewriting the same number is a write nobody
        // asked for.
        #expect(ProfileStats.fastestWin(current: 30, won: true, elapsedSeconds: 30) == 30)
    }

    @Test("A first win sets it")
    func fastestWinFromNil() {
        #expect(ProfileStats.fastestWin(current: nil, won: true, elapsedSeconds: 12) == 12)
    }

    @Test("A loss never touches it, however fast the match was")
    func fastestWinOnALoss() {
        #expect(ProfileStats.fastestWin(current: nil, won: false, elapsedSeconds: 3) == nil)
        #expect(ProfileStats.fastestWin(current: 90, won: false, elapsedSeconds: 3) == 90)
    }

    /// `fastest_win_seconds` is `null or > 0` in the database, so a match won
    /// inside a second must not round down into a rejected row.
    @Test("A sub-second win is stored as one second, not zero")
    func fastestWinIsPositive() {
        #expect(ProfileStats.fastestWin(current: nil, won: true, elapsedSeconds: 0) == 1)
        #expect(ProfileStats.fastestWin(current: nil, won: true, elapsedSeconds: -5) == 1)
    }

    // MARK: - Monotonicity

    /// The increment is computed from the row that was read. A blind write —
    /// `matches_played = 1` — is indistinguishable from this on a fresh
    /// profile, which is why the row this reads from is not a fresh one.
    @Test("Every counter is the read value plus this match, never a fresh number")
    func statsAreIncrementsOnTheReadRow() async throws {
        let before = Self.profile(Self.aliceUUID, played: 7, won: 4, tiles: 61, fastest: 25)
        let store = RecordingOutcomeStore(profiles: [Self.aliceUUID: before])
        let clock = TestClock(start: Date(timeIntervalSince1970: 0))
        let (host, _) = try await Self.playingPair()

        let recorder = MatchOutcomeRecorder(
            record: Self.lobby(), localPlayer: Self.alice, session: host,
            store: store, now: clock.now
        )
        await recorder.sync()
        clock.advance(300)                 // slower than the record it must not overwrite
        host.claimWin()
        try await Self.waitUntil("finished") { host.winner == Self.alice }
        await recorder.sync()

        let after = try #require(await store.profileUpdates.first?.stats)
        #expect(after.matchesPlayed == 8)
        #expect(after.matchesWon == 5)
        #expect(after.tilesPlaced == 61)
        #expect(after.fastestWinSeconds == 25)

        // Stated as the guardrail states it, so a regression that decrements
        // anything at all fails here whatever it decremented.
        #expect(after.matchesPlayed >= before.matchesPlayed)
        #expect(after.matchesWon >= before.matchesWon)
        #expect(after.tilesPlaced >= before.tilesPlaced)
        #expect((after.fastestWinSeconds ?? .max) <= (before.fastestWinSeconds ?? .max))
        #expect(after.matchesWon <= after.matchesPlayed)
    }

    /// A loser's `matches_won` stays where it was — the `+ 1` is conditional,
    /// and an unconditional one would still pass every test above on a winner.
    @Test("A loss adds a match played and no match won")
    func aLossDoesNotAddAWin() {
        let before = Self.profile(Self.aliceUUID, played: 3, won: 2, tiles: 10, fastest: 60)
        let after = ProfileStats.after(before, won: false, tilesPlaced: 4, elapsedSeconds: 9)
        #expect(after.matchesPlayed == 4)
        #expect(after.matchesWon == 2)
        #expect(after.tilesPlaced == 14)
        #expect(after.fastestWinSeconds == 60)
    }

    // MARK: - Tiles placed

    /// The count comes off this device's own board, which is its own private
    /// table — never the peer's.
    @Test("Tiles placed is this device's own board count")
    func tilesPlacedComesFromTheLocalBoard() async throws {
        let store = RecordingOutcomeStore(profiles: [Self.aliceUUID: Self.profile(Self.aliceUUID)])
        let (host, _) = try await Self.playingPair(handSize: 4)
        try await Self.waitUntil("the opening hand is dealt") { host.state.hand.count == 4 }

        try host.place(tileID: host.state.hand[0].id, at: Coord(row: 0, col: 0))
        try host.place(tileID: host.state.hand[0].id, at: Coord(row: 0, col: 1))
        try host.place(tileID: host.state.hand[0].id, at: Coord(row: 0, col: 2))
        #expect(host.state.board.placements.count == 3)

        let recorder = MatchOutcomeRecorder(
            record: Self.lobby(), localPlayer: Self.alice, session: host,
            store: store, now: TestClock(start: Date(timeIntervalSince1970: 0)).now
        )
        await recorder.sync()
        host.claimWin()
        try await Self.waitUntil("finished") { host.winner == Self.alice }
        await recorder.sync()

        #expect(await store.profileUpdates.first?.stats.tilesPlaced == 3)
    }

    // MARK: - The loop

    /// `sync()` is where every decision lives, but nothing calls it in
    /// production — `run()` does. This drives the real observation loop from
    /// `.playing` through a win with no manual `sync()` anywhere.
    @Test("run() observes the session through to a recorded result")
    func theLoopRecordsWithoutBeingPoked() async throws {
        let store = RecordingOutcomeStore(profiles: [Self.aliceUUID: Self.profile(Self.aliceUUID)])
        let clock = TestClock(start: Date(timeIntervalSince1970: 0))
        let (host, _) = try await Self.playingPair()

        let recorder = MatchOutcomeRecorder(
            record: Self.lobby(), localPlayer: Self.alice, session: host,
            store: store, now: clock.now
        )
        let loop = Task { @MainActor in await recorder.run() }
        try await Self.waitUntil("the playing write landed") { await store.matchUpdates.count == 1 }

        clock.advance(11)
        host.claimWin()
        await loop.value

        #expect(await store.matchUpdates.count == 2)
        #expect(await store.profileUpdates.first?.stats.matchesWon == 1)
        #expect(await store.profileUpdates.first?.stats.fastestWinSeconds == 11)
    }
}

// MARK: - Doubles

/// The database, as the calls it was asked to make.
///
/// Not a mock of PostgREST: it answers `profile(_:)` from a seeded row so the
/// increment has something real to be computed from, and remembers everything
/// else so the writes that must *not* happen are assertable.
actor RecordingOutcomeStore: MatchOutcomeStore {

    private(set) var matchUpdates: [MatchOutcomeUpdate] = []
    private(set) var profileUpdates: [(id: UUID, stats: ProfileStats)] = []
    private(set) var reads = 0

    private var profiles: [UUID: Profile]

    init(profiles: [UUID: Profile]) {
        self.profiles = profiles
    }

    func updateMatch(_ id: UUID, _ update: MatchOutcomeUpdate) async throws {
        matchUpdates.append(update)
    }

    func profile(_ id: UUID) async throws -> Profile {
        reads += 1
        guard let profile = profiles[id] else { throw BackendError.notFound }
        return profile
    }

    func updateProfile(_ id: UUID, _ stats: ProfileStats) async throws {
        profileUpdates.append((id, stats))
    }
}

extension MatchOutcomeUpdate {
    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
}

/// Time the test moves. Elapsed is measured on this, so nothing here depends on
/// how long the suite actually takes to run.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) { current = start }

    var now: @Sendable () -> Date {
        { [self] in lock.withLock { current } }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

/// Every word is a word. The recorder never asks the dictionary anything; the
/// session needs one to exist.
struct EveryWordIsReal: WordList {
    func contains(_ word: String) -> Bool { true }
}
