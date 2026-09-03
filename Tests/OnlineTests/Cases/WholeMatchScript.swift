//
//  WholeMatchScript.swift
//  OnlineTests
//
//  Item 7's call site, written once.
//
//  `LiveMatchTests` plays a whole match through two real `SupabaseBackend`s on
//  the real project; the suite at the bottom of this file plays the same match
//  through `FakeBackend` and a recording transport. The two differ only in what
//  they are wired to — every rule they check comes from ``WholeMatchScript``
//  above, so a façade, a session or a recorder that stopped agreeing turns both
//  of them red rather than only the one that needs a network to run.
//
//  The live half cannot run without a key. That is exactly why the offline half
//  exists: with the gate unset it is the only thing standing between a broken
//  client and a green suite.
//

import Foundation
import Testing
import WillagramsRules
@testable import Online

// MARK: - The script both halves play

/// What a whole match has to do, independent of what it is playing over.
@MainActor
enum WholeMatchScript {

    /// How a caller waits. Live waits on wall-clock time it derives from
    /// `MatchSession.reconnectGraceSeconds`; offline waits on scheduler turns,
    /// because every clock there is injected as a no-op. Neither meaning
    /// belongs in here.
    typealias Waiter = (String, @MainActor () -> Bool) async -> Void

    /// Draw rounds this script asks for, split between the two devices.
    ///
    /// Alternating on purpose: a grant that only ever travelled from the pool
    /// host to itself would satisfy a script where one device does all the
    /// asking.
    static let drawRounds = 4

    /// Tiles each side lays before the match ends. Different counts, so a
    /// recorder that wrote one device's board to the other player's row is a
    /// failure rather than a coincidence.
    static let creatorPlacements = 3
    static let guestPlacements = 2

    // MARK: The ledger

    /// Tiles this device has been granted — in the rack, or still waiting to be
    /// taken. Taking a waiting tile moves it between the two and must not read
    /// as a tile arriving.
    static func tilesHeld(_ session: MatchSession) -> Int {
        session.state.hand.count + session.pendingDrawTiles.count
    }

    /// One draw round, asked for by `requester`.
    ///
    /// `HostPool.handle` deals a round to *every* player or to none — one tile
    /// each, or the pool is untouched. So "every draw granted on one side was
    /// observed on the other" is decidable from the two tile counts alone: they
    /// move together, by one, whichever device pressed the button.
    static func drawRound(
        by requester: MatchSession,
        peer: MatchSession,
        expecting held: Int,
        until: Waiter
    ) async {
        // Accepting a waiting tile is not a request. The rack has to be clear
        // before a press reaches the pool at all, or this round never happens
        // and the count that follows is asserting the previous round twice.
        while requester.hasPendingDraw { requester.draw() }
        guard requester.draw() else {
            Issue.record("the draw press did nothing")
            return
        }
        await until("both devices hold \(held) tiles") {
            tilesHeld(requester) == held && tilesHeld(peer) == held
        }
    }

    /// Takes every waiting tile into the rack. `place` refuses while one is
    /// outstanding, which is the obligation working, not a failure.
    static func drainPendingDraws(_ session: MatchSession) {
        while session.hasPendingDraw { session.draw() }
    }

    /// Lays `count` tiles in a row. Nothing here is a word: placement is not
    /// where the dictionary bites, and what the recorder reads off the board is
    /// a count.
    static func placeTiles(_ count: Int, on session: MatchSession) throws {
        for col in 0 ..< count {
            // An empty rack means the deal never reached this device. Record it
            // and leave: subscripting here traps, and a trap takes down the whole
            // test process, hiding every case that would have run after it.
            guard let tile = session.state.hand.first else {
                Issue.record("the rack was empty after \(col) of \(count) placements")
                return
            }
            try session.place(tileID: tile.id, at: Coord(row: 0, col: col))
        }
        #expect(session.state.board.placements.count == count)
    }

    /// The whole match, from two sessions that have already reached `.playing`.
    ///
    /// - Returns: the winner both devices must name.
    static func play(
        creator: MatchSession,
        guest: MatchSession,
        until: Waiter
    ) async throws -> PlayerID {
        await until("the creator is dealt in") {
            tilesHeld(creator) == OnlineMatch.startingHandSize
        }
        await until("the guest is dealt in") {
            tilesHeld(guest) == OnlineMatch.startingHandSize
        }

        var held = OnlineMatch.startingHandSize
        for round in 0 ..< drawRounds {
            held += 1
            let creatorAsks = round.isMultiple(of: 2)
            await drawRound(
                by: creatorAsks ? creator : guest,
                peer: creatorAsks ? guest : creator,
                expecting: held,
                until: until
            )
        }
        // Criterion 1's second half, stated once rather than per round: the two
        // devices came out of `drawRounds` rounds holding the same tally.
        #expect(tilesHeld(creator) == held)
        #expect(tilesHeld(guest) == held)
        #expect(held == OnlineMatch.startingHandSize + drawRounds)

        drainPendingDraws(creator)
        drainPendingDraws(guest)
        try placeTiles(creatorPlacements, on: creator)
        try placeTiles(guestPlacements, on: guest)

        #expect(guest.claimWin(), "the guest could not claim the win")
        await until("the creator hears the win") { creator.winner != nil }
        return guest.localPlayerID
    }

    // MARK: The assertions

    /// Criterion 1: both sessions finished, naming the same winner.
    static func expectBothFinished(
        creator: MatchSession, guest: MatchSession, winner: PlayerID
    ) {
        #expect(guest.winner == winner)
        #expect(creator.winner == winner, "the two devices disagree about who won")
        #expect(creator.isMatchOver)
        #expect(guest.isMatchOver)
    }

    /// Criterion 2, first half: the `matches` row the creator closed out.
    static func expectFinishedRow(_ row: MatchRecord, winner: UUID) {
        #expect(row.status == .finished)
        #expect(row.winnerID == winner)
        #expect(row.startedAt != nil, "the row never went through playing")
        #expect(row.finishedAt != nil)
    }

    /// Criterion 2, second half: the four counters item 5 specifies, as a delta
    /// on the row the player already had.
    ///
    /// Deltas rather than literals so this reads the same against a fresh
    /// anonymous profile live and against a seeded row offline — and so the
    /// offline half is not asserting `0 + 0 == 0`.
    static func expectStats(
        _ label: String,
        before: Profile,
        after: Profile,
        won: Bool,
        tilesPlaced: Int
    ) {
        #expect(after.id == before.id)
        #expect(after.matchesPlayed == before.matchesPlayed + 1, "\(label): matches_played")
        #expect(after.matchesWon == before.matchesWon + (won ? 1 : 0), "\(label): matches_won")
        #expect(after.tilesPlaced == before.tilesPlaced + tilesPlaced, "\(label): tiles_placed")

        guard won else {
            // A loss never touches it, whatever this match's elapsed time was.
            #expect(after.fastestWinSeconds == before.fastestWinSeconds, "\(label): a loss moved fastest_win_seconds")
            return
        }
        guard let fastest = after.fastestWinSeconds else {
            Issue.record("\(label): a win left fastest_win_seconds null")
            return
        }
        // The database's floor, not a preference: the column is `null or > 0`.
        #expect(fastest >= 1, "\(label): fastest_win_seconds below the row's floor")
        #expect(fastest <= (before.fastestWinSeconds ?? Int.max), "\(label): fastest_win_seconds got worse")
    }
}

// MARK: - The offline database

/// A `MatchOutcomeStore` that applies what it is given.
///
/// `SpyOutcomeStore` next door records the calls and drops their content, which
/// can say a write happened but not what it wrote. This one stands in for the
/// two rows the live case reads back out of Postgres, and applies exactly the
/// columns `SupabaseOutcomeQueries` sends — so "the row reads finished with that
/// winner" is the same sentence on both sides of the gate.
///
/// One instance for both devices: there is one database in the live case, and a
/// store per side would let a bug where the guest writes the `matches` row pass
/// unseen.
final class MemoryOutcomeStore: MatchOutcomeStore, @unchecked Sendable {

    private let lock = NSLock()
    private var storedMatch: MatchRecord?
    private var rows: [UUID: Profile]
    private var strayUpdates = 0

    init(profiles: [Profile]) {
        rows = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    /// Holds the row the façade drew. `OnlineMatch.host` creates the `matches`
    /// row itself, so there is nothing to hold until it returns — and the store
    /// has to be handed to `host` before that.
    func adopt(_ record: MatchRecord) { lock.withLock { storedMatch = record } }

    var match: MatchRecord? { lock.withLock { storedMatch } }
    func row(_ id: UUID) -> Profile? { lock.withLock { rows[id] } }

    /// Updates that named a row this store never adopted. Asserted zero: a
    /// mis-seeded store would otherwise swallow every write and read as a match
    /// that recorded nothing.
    var strayMatchUpdates: Int { lock.withLock { strayUpdates } }

    func updateMatch(_ id: UUID, _ update: MatchOutcomeUpdate) async throws {
        lock.withLock {
            guard storedMatch?.id == id else {
                strayUpdates += 1
                return
            }
            switch update {
            case let .playing(startedAt):
                storedMatch?.status = .playing
                storedMatch?.startedAt = startedAt
            case let .finished(finishedAt, winnerID):
                storedMatch?.status = .finished
                storedMatch?.finishedAt = finishedAt
                storedMatch?.winnerID = winnerID
            }
        }
    }

    func profile(_ id: UUID) async throws -> Profile {
        guard let row = lock.withLock({ rows[id] }) else { throw BackendError.notFound }
        return row
    }

    func updateProfile(_ id: UUID, _ stats: ProfileStats) async throws {
        lock.withLock {
            guard var row = rows[id] else { return }
            row.matchesPlayed = stats.matchesPlayed
            row.matchesWon = stats.matchesWon
            row.tilesPlaced = stats.tilesPlaced
            row.fastestWinSeconds = stats.fastestWinSeconds
            rows[id] = row
        }
    }
}

// MARK: - The offline half

/// The whole of item 7, minus the network.
///
/// Everything here is decided by ``WholeMatchScript``, which is what makes this
/// an analogue of `LiveMatchTests` rather than a second test that happens to
/// look similar.
@MainActor
@Suite("A whole match, offline")
struct WholeMatchOfflineTests {

    /// Non-zero priors, deliberately. A monotonicity or delta check against a
    /// row of zeroes proves nothing: every wrong answer is also zero.
    static func priorProfile(_ id: UUID, played: Int, won: Int, tiles: Int, fastest: Int?) -> Profile {
        Profile(
            id: id,
            displayName: "prior",
            friendCode: "AAAAAAAA",
            createdAt: Date(timeIntervalSince1970: 0),
            matchesPlayed: played,
            matchesWon: won,
            tilesPlaced: tiles,
            fastestWinSeconds: fastest
        )
    }

    struct Fixture {
        let creatorPlayer: PlayerID
        let guestPlayer: PlayerID
        let creatorWire: SpyTransport
        let guestWire: SpyTransport
        let store: MemoryOutcomeStore
        let creatorBefore: Profile
        let guestBefore: Profile
        let creator: OnlineMatch
        let guest: OnlineMatch
    }

    /// Two façades over one fake backend, one paired recording wire and one
    /// in-memory database.
    ///
    /// `"A"` and `"B"` pick the two ids: `FakeBackend` derives a stable UUID
    /// from the token bytes, so the creator is `roster[0]` and opens the match.
    static func fixture() async throws -> Fixture {
        let backend = FakeBackend()
        let creatorPlayer = try await backend.signInWithApple(idToken: "A", nonce: "n").playerID
        let guestPlayer = try await backend.signInWithApple(idToken: "B", nonce: "n").playerID
        #expect(creatorPlayer.rawValue < guestPlayer.rawValue)

        let (creatorWire, guestWire) = SpyTransport.pair(creatorPlayer, guestPlayer)
        await backend.setTransportFactory { _, player in
            player == creatorPlayer ? creatorWire : guestWire
        }

        // The creator loses, and holds a prior best time a loss must not touch.
        let creatorBefore = priorProfile(
            UUID(uuidString: creatorPlayer.rawValue)!, played: 5, won: 2, tiles: 77, fastest: 120)
        // The guest wins in about no time at all, so its prior best is the thing
        // the new time has to beat.
        let guestBefore = priorProfile(
            UUID(uuidString: guestPlayer.rawValue)!, played: 3, won: 1, tiles: 40, fastest: 90)

        let store = MemoryOutcomeStore(profiles: [creatorBefore, guestBefore])

        _ = try await backend.signInWithApple(idToken: "A", nonce: "n")
        let creator = try await OnlineMatch.host(
            options: .standard,
            backend: backend,
            dictionary: EveryWordIsReal(),
            outcomeStore: store,
            sleepFor: { _ in }
        )
        _ = try await backend.signInWithApple(idToken: "B", nonce: "n")
        let guest = try await OnlineMatch.join(
            code: creator.inviteCode,
            backend: backend,
            dictionary: EveryWordIsReal(),
            outcomeStore: store,
            sleepFor: { _ in }
        )
        // `host` drew the row; nothing records until `start()`, which is well
        // after this.
        store.adopt(creator.record)
        return Fixture(
            creatorPlayer: creatorPlayer,
            guestPlayer: guestPlayer,
            creatorWire: creatorWire,
            guestWire: guestWire,
            store: store,
            creatorBefore: creatorBefore,
            guestBefore: guestBefore,
            creator: creator,
            guest: guest
        )
    }

    /// Yields until `condition` holds. A count of scheduler turns, not a clock:
    /// every clock in this suite is injected as a no-op.
    static func until(_ label: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 20_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("timed out waiting for: \(label)")
    }

    @Test("Two façades play a whole match, and both rows land")
    func aWholeMatchLandsBothRows() async throws {
        let f = try await Self.fixture()

        f.creatorWire.announce(.connected(f.guestPlayer))
        f.guestWire.announce(.connected(f.creatorPlayer))
        await Self.until("two in the creator's lobby") { f.creator.lobby.count == 2 }
        await Self.until("two in the guest's lobby") { f.guest.lobby.count == 2 }

        let guestSession = try await f.guest.awaitStart()
        let creatorSession = try await f.creator.start()
        // Same guardrail as the live case: a throw below must not walk out
        // leaving two sessions subscribed.
        defer {
            creatorSession.leave()
            guestSession.leave()
        }
        await Self.until("the creator is playing") { creatorSession.state.status == .playing }
        await Self.until("the guest is playing") { guestSession.state.status == .playing }

        let winner = try await WholeMatchScript.play(
            creator: creatorSession, guest: guestSession, until: Self.until
        )

        // Criterion 1.
        WholeMatchScript.expectBothFinished(
            creator: creatorSession, guest: guestSession, winner: winner)
        #expect(winner == f.guestPlayer)

        // Criterion 1, on the wire rather than in the tally: the pool host
        // served the guest too, and the guest saw every one of those grants.
        let grantsToGuest = f.guestWire.received.filter {
            if case let .grant(player, _) = $0 { player == f.guestPlayer } else { false }
        }
        #expect(
            grantsToGuest.count == 1 + WholeMatchScript.drawRounds,
            "the guest saw \(grantsToGuest.count) grants, not the opening deal plus every round")
        // And the guest asked for exactly the rounds the script gave it.
        let guestRequests = f.guestWire.sent.filter {
            if case .drawRequest = $0 { true } else { false }
        }
        #expect(guestRequests.count == WholeMatchScript.drawRounds / 2)

        // Criterion 2, first half.
        await Self.until("the matches row is finished") { f.store.match?.status == .finished }
        #expect(f.store.strayMatchUpdates == 0, "a matches update named a row this store never held")
        WholeMatchScript.expectFinishedRow(
            try #require(f.store.match), winner: UUID(uuidString: f.guestPlayer.rawValue)!)

        // Criterion 2, second half.
        let creatorID = f.creatorBefore.id
        let guestID = f.guestBefore.id
        await Self.until("both stats rows are written") {
            f.store.row(creatorID)?.matchesPlayed == f.creatorBefore.matchesPlayed + 1
                && f.store.row(guestID)?.matchesPlayed == f.guestBefore.matchesPlayed + 1
        }
        WholeMatchScript.expectStats(
            "creator",
            before: f.creatorBefore,
            after: try #require(f.store.row(creatorID)),
            won: false,
            tilesPlaced: WholeMatchScript.creatorPlacements
        )
        WholeMatchScript.expectStats(
            "guest",
            before: f.guestBefore,
            after: try #require(f.store.row(guestID)),
            won: true,
            tilesPlaced: WholeMatchScript.guestPlacements
        )

        #expect(f.creator.recorder?.lastError == nil)
        #expect(f.guest.recorder?.lastError == nil)
    }

    /// A rack can be empty when the deal never reached this device — a live
    /// failure, never an offline one. `placeTiles` has to name it and return:
    /// subscripting an empty rack traps, and a trap ends the whole test
    /// process, taking every case that would have run after it.
    @Test("Placing from an empty rack records an issue instead of trapping")
    func emptyRackIsRecordedNotTrapped() async throws {
        let pair = try await MatchOutcomeRecorderTests.playingPair(handSize: 0)
        #expect(WholeMatchScript.tilesHeld(pair.host) == 0)

        withKnownIssue("the rack is empty by construction") {
            try WholeMatchScript.placeTiles(2, on: pair.host)
        }
    }

}
