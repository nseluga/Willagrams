import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell

/// One test per acceptance criterion for solo practice, each driving the real
/// factory and the real engine — no stubs stand in for either end of the wire.
///
/// Nothing here iterates a transport stream: the session owns the local end's,
/// `SoloMatch` owns the far end's, and a second consumer would silently divide
/// the messages rather than fail.
@MainActor
@Suite("Solo practice")
struct SoloMatchTests {

    /// Accepts every word, so the letters the pool deals never decide whether a
    /// board is complete.
    struct EveryWordIsReal: WordList {
        func contains(_ word: String) -> Bool { true }
    }

    struct WaitExpired: Error, CustomStringConvertible {
        let label: String
        var description: String { "timed out waiting for \(label)" }
    }

    /// Polls `condition` until it holds, throwing rather than hanging.
    static func waitUntil(
        _ label: String,
        within deadline: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let limit = ContinuousClock.now + deadline
        while !condition() {
            guard ContinuousClock.now < limit else { throw WaitExpired(label: label) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    static let setup = MatchSetup(
        seed: 20260817,
        startingHandSize: ShellModel.soloHandSize,
        countdownSeconds: ShellModel.soloCountdownSeconds
    )

    /// A started solo match, past its countdown and holding its opening hand.
    /// The countdown clock returns immediately, so the three seconds cost none.
    static func started() async throws -> SoloMatch {
        let solo = SoloMatch(setup: setup, dictionary: EveryWordIsReal(), sleepFor: { _ in })
        solo.start()
        try await waitUntil("the opening hand") {
            solo.session.state.hand.count == setup.startingHandSize
        }
        return solo
    }

    /// Every tile the local end holds anywhere: rack, board, and the tiles it
    /// owes a press for.
    static func localTileIDs(_ solo: SoloMatch) -> Set<UUID> {
        var ids = Set(solo.session.state.hand.map(\.id))
        ids.formUnion(solo.session.pendingDrawTiles.map(\.id))
        ids.formUnion(solo.session.state.board.placementList.map(\.tile.id))
        return ids
    }

    // MARK: - Criterion 1

    @Test("A solo start reaches play and never hits the host rejection")
    func soloStartReachesPlayWithNoNote() async throws {
        let solo = SoloMatch(setup: Self.setup, dictionary: EveryWordIsReal(), sleepFor: { _ in })

        // The election the engine itself runs, not the order the ids were named.
        #expect(
            HostPool.host(of: [SoloMatch.localPlayerID, SoloMatch.peerPlayerID])
                == SoloMatch.localPlayerID
        )

        solo.start()
        try await Self.waitUntil("play to begin") { solo.session.state.status == .playing }
        #expect(solo.session.lastNote == nil)
        solo.leave()
    }

    /// The other half of the same criterion: the note this factory must never
    /// produce is a note the engine really does produce for a non-host, so the
    /// assertion above is not passing because the string was retired.
    @Test("The host rejection is real, and solo is on the right side of it")
    func hostRejectionExistsForANonHost() async throws {
        let low = PlayerID(rawValue: "aaa")
        let high = PlayerID(rawValue: "zzz")
        let (_, guestWire) = FakeTransport.pair(low, high)
        let guest = MatchSession(
            transport: guestWire,
            peerPlayerID: low,
            dictionary: EveryWordIsReal(),
            sleepFor: { _ in }
        )
        guest.startMatch(seed: 1, startingHandSize: 21, countdownSeconds: 0)
        #expect(guest.lastNote == "only the host opens the match")
        #expect(guest.state.status != .playing)
        guest.leave()
    }

    // MARK: - Criterion 2

    @Test("A solo match reaches a win claim with the pool spent exactly once, and not early")
    func soloPlaysToAWinClaimWithoutExhaustingEarly() async throws {
        let solo = try await Self.started()
        let rounds = SoloMatch.drawsAvailable(handSize: Self.setup.startingHandSize)
        #expect(rounds == 51)

        for round in 1...rounds {
            #expect(solo.session.poolIsExhausted == false, "pool ran out at round \(round)")
            #expect(solo.session.draw())
            try await Self.waitUntil("the tile from round \(round)") {
                solo.session.state.hand.count == Self.setup.startingHandSize + round
            }
        }

        // Counted, not assumed: the local end's share plus the tiles burned by
        // the silent end account for the whole pool, with nothing left over.
        let local = Self.localTileIDs(solo)
        #expect(local.count == Self.setup.startingHandSize + rounds)
        #expect(local.count + solo.peerTileIDs.count == LetterDistribution.totalTiles)
        #expect(solo.session.poolIsExhausted == false)

        // The pool is empty now, and only now.
        solo.session.draw()
        try await Self.waitUntil("the pool to run out") { solo.session.poolIsExhausted }

        #expect(solo.session.claimWin())
        #expect(solo.session.winner == SoloMatch.localPlayerID)
        solo.leave()
    }

    // MARK: - Criterion 3

    @Test("Repeated draws each yield one tile, and no tile is held by both ends")
    func repeatedDrawsYieldOneTileAndNeverShareOne() async throws {
        let solo = try await Self.started()
        let opening = Self.localTileIDs(solo)
        #expect(opening.count == Self.setup.startingHandSize)
        #expect(opening.isDisjoint(with: solo.peerTileIDs))
        // The silent end was dealt its own opening hand — that is the waste the
        // pool sizing has to cover, and it is real.
        #expect(solo.peerTileIDs.count == Self.setup.startingHandSize)

        var seen = opening
        for round in 1...12 {
            let before = solo.session.state.hand.count
            #expect(solo.session.draw())
            // Both ends, not just this one: the far end's grant is a separate
            // message, so a wait on the local hand alone can read the peer's
            // count one message early under load.
            try await Self.waitUntil("round \(round) at both ends") {
                solo.session.state.hand.count == before + 1
                    && solo.peerTileIDs.count == Self.setup.startingHandSize + round
            }
            let now = Self.localTileIDs(solo)
            #expect(now.count == seen.count + 1, "round \(round) moved more than one tile")
            #expect(now.isSuperset(of: seen))
            #expect(now.isDisjoint(with: solo.peerTileIDs), "a tile reached both ends")
            #expect(solo.peerTileIDs.count == Self.setup.startingHandSize + round)
            seen = now
        }
        solo.leave()
    }

    // MARK: - Criterion 4

    @Test("A difficulty makes the far end actually play")
    func aDifficultyPutsTilesOnTheFarEndsBoard() async throws {
        let solo = SoloMatch(
            setup: Self.setup,
            dictionary: EveryWordIsReal(),
            difficulty: ShellModel.soloDifficulty,
            sleepFor: { _ in }
        )
        solo.start()
        // Placements on the *bot's* board, not messages on the wire: a solo
        // player's opponent is a second real session playing its own tiles, and
        // the only proof of that is the tiles moving out of its rack.
        try await Self.waitUntil("the far end to place a tile") {
            solo.bot.session.state.board.placementList.isEmpty == false
        }
        solo.leave()
    }

    @Test("No difficulty leaves the far end silent")
    func noDifficultyLeavesTheFarEndSilent() async throws {
        let solo = try await Self.started()
        #expect(solo.difficulty == nil)
        #expect(solo.bot.session.state.board.placementList.isEmpty)
        solo.leave()
    }
}
