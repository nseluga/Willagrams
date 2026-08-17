import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell

/// One test per acceptance criterion for Rematch. A rematch is a rebuild, not a
/// reset: every assertion here is about a *new* transport pair, session and
/// pool, and about the previous one being gone before the new one exists.
@MainActor
@Suite("Rematch")
struct RematchTests {

    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal

    /// A practice owner whose seeds are a known increasing sequence, so "the
    /// seed changed" is an exact assertion rather than a probabilistic one.
    static func practice(from first: UInt64 = 100) -> SoloPractice {
        let counter = Counter(first &- 1)
        return SoloPractice(
            shell: ShellModel(),
            dictionary: EveryWordIsReal(),
            sleepFor: { _ in },
            seedSource: { counter.next() }
        )
    }

    /// A box, so the closure and the test share one counter.
    final class Counter {
        private var value: UInt64
        init(_ value: UInt64) { self.value = value }
        func next() -> UInt64 { value &+= 1; return value }
    }

    static func waitForPlay(_ practice: SoloPractice) async throws {
        try await SoloMatchTests.waitUntil("play to begin") {
            practice.match?.session.state.status == .playing
        }
    }

    // MARK: - Criterion 1

    @Test("A rematch is the same two players, still host, on a different seed")
    func rematchKeepsPlayersAndChangesSeed() async throws {
        let practice = Self.practice()
        #expect(practice.start())
        try await Self.waitForPlay(practice)

        let first = try #require(practice.match)
        let firstSeed = try #require(practice.seed)
        let firstSession = first.session

        let results = try #require(practice.results())
        #expect(results.isRematchEnabled)
        #expect(results.rematch())
        try await Self.waitForPlay(practice)

        let second = try #require(practice.match)
        let secondSeed = try #require(practice.seed)

        #expect(second !== first, "rematch reused the finished match")
        #expect(second.session !== firstSession, "rematch reused the finished session")
        #expect(secondSeed != firstSeed, "rematch replayed the previous deal")

        // Same two ids, in the same order, and the local end is still the one
        // the engine's own election names host.
        #expect(second.session.localPlayerID == firstSession.localPlayerID)
        #expect(second.session.peerPlayerID == firstSession.peerPlayerID)
        #expect(second.session.localPlayerID == SoloMatch.localPlayerID)
        #expect(
            HostPool.host(of: second.session.localPlayerID, second.session.peerPlayerID)
                == second.session.localPlayerID
        )
        // A non-host start is refused with a note; the new session has none, so
        // it really did open the match itself.
        #expect(second.session.lastNote == nil)

        practice.end()
    }

    /// The never-repeat rule is a guarantee, not a probability: even a seed
    /// source that keeps handing back the same number cannot deal the same pool
    /// twice running.
    @Test("A seed source that repeats itself still cannot repeat a deal")
    func aRepeatingSeedSourceStillChangesTheDeal() async throws {
        let practice = SoloPractice(
            shell: ShellModel(),
            dictionary: EveryWordIsReal(),
            sleepFor: { _ in },
            seedSource: { 42 }
        )
        #expect(practice.start())
        try await Self.waitForPlay(practice)
        #expect(practice.seed == 42)

        let results = try #require(practice.results())
        #expect(results.rematch())
        try await Self.waitForPlay(practice)
        #expect(practice.seed != 42)

        practice.end()
    }

    // MARK: - Criterion 2

    /// Ten rematches, every generation held weakly. Each one must be gone before
    /// the run ends, and only the live one may be alive at any point — which is
    /// what "no growth in live session count" means with no counter to read.
    ///
    /// The weak reads happen on a *later* main-actor turn, through the same
    /// yield helper the release test next door uses: a session's own tasks need
    /// a turn to finish on, and a same-turn read proves nothing.
    @Test("Ten rematches leave no generation alive but the current one")
    func tenRematchesStrandNothing() async throws {
        let practice = Self.practice()
        var weakMatches: [WeakBox<SoloMatch>] = []
        var weakSessions: [WeakBox<MatchSession>] = []

        #expect(practice.start())
        try await Self.waitForPlay(practice)
        weakMatches.append(WeakBox(practice.match))
        weakSessions.append(WeakBox(practice.match?.session))

        for round in 1...10 {
            let previousMatch = weakMatches[round - 1]
            let previousSession = weakSessions[round - 1]

            let results = try #require(practice.results())
            #expect(results.rematch(), "rematch \(round) did nothing")
            try await Self.waitForPlay(practice)

            weakMatches.append(WeakBox(practice.match))
            weakSessions.append(WeakBox(practice.match?.session))

            // The generation just replaced is released, read on a later turn.
            try await SoloMatchTests.waitUntil("generation \(round - 1) to be released") {
                previousMatch.value == nil && previousSession.value == nil
            }

            // Nothing but the live generation is alive, however many rounds in.
            let alive = weakMatches.filter { $0.value != nil }
            #expect(alive.count == 1, "\(alive.count) matches alive after rematch \(round)")
            #expect(weakSessions.filter { $0.value != nil }.count == 1)
        }

        // The far end of the live match still works — the ten teardowns did not
        // take the current generation's pump with them. Scoped, so no strong
        // reference to it outlives the check and fakes the release below.
        try await {
            let live = try #require(practice.match)
            let dealt = live.peerTileIDs.count
            #expect(dealt == ShellModel.soloHandSize, "the live far end never took its opening")
            #expect(live.session.draw())
            try await SoloMatchTests.waitUntil("the far end to take one more tile") {
                live.peerTileIDs.count == dealt + 1
            }
        }()

        practice.end()
        try await SoloMatchTests.waitUntil("the last generation to be released") {
            weakMatches.allSatisfy { $0.value == nil }
                && weakSessions.allSatisfy { $0.value == nil }
        }
    }

    /// A weak reference that can live in an array.
    final class WeakBox<T: AnyObject> {
        weak var value: T?
        init(_ value: T?) { self.value = value }
    }

    // MARK: - Criterion 3

    @Test("A message from the finished match's transport cannot reach the new session")
    func theOldTransportCannotReachTheNewSession() async throws {
        let practice = Self.practice()
        #expect(practice.start())
        try await Self.waitForPlay(practice)
        // Held strongly on purpose: a wire that refuses only because its owner
        // deallocated would prove nothing about the teardown.
        let old = try #require(practice.match)

        let results = try #require(practice.results())
        #expect(results.rematch())
        try await Self.waitForPlay(practice)
        let new = try #require(practice.match)

        #expect(old.session.isMatchOver, "the finished match was never torn down")

        // Sent after the rebuild, on the wire the finished match owned. It is
        // refused outright — and, refused or not, it changes nothing here.
        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await old.peerTransport.send(
                .resign(player: SoloMatch.peerPlayerID), delivery: .reliable
            )
        }
        for _ in 0..<5 { await Task.yield() }
        #expect(new.session.winner == nil, "the finished match's wire ended the new match")
        #expect(new.session.isMatchOver == false)
        #expect(new.session.state.status == .playing)

        // The control: the *new* match's own far end can do exactly what the old
        // one could not, so the assertions above are not passing because a
        // resignation is inert.
        try await new.peerTransport.send(
            .resign(player: SoloMatch.peerPlayerID), delivery: .reliable
        )
        try await SoloMatchTests.waitUntil("the new session to take its own peer's message") {
            new.session.winner != nil
        }
        #expect(new.session.winner == SoloMatch.localPlayerID)

        practice.end()
    }

    /// The end screen is not the only way in. A start called straight on the
    /// owner — the menu route, a second tap — must tear the live match down
    /// itself, or the one construction path leaks whenever the end screen is
    /// not the caller.
    @Test("Starting again without the end screen still tears the previous match down")
    func aDirectRestartStillTearsTheOldMatchDown() async throws {
        let practice = Self.practice()
        #expect(practice.start())
        try await Self.waitForPlay(practice)
        let old = try #require(practice.match)

        #expect(practice.start())
        try await Self.waitForPlay(practice)

        #expect(practice.match !== old, "a second start handed back the live match")
        #expect(old.session.isMatchOver, "the previous match was left running")
        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await old.peerTransport.send(
                .resign(player: SoloMatch.peerPlayerID), delivery: .reliable
            )
        }

        practice.end()
    }

    // MARK: - Criterion 4

    /// Nothing from the finished match is visible in the new one. The pool
    /// *count* is not asserted here because `MatchSession` publishes none —
    /// `state.pool` is a placeholder and the real pool is private inside the
    /// `HostPool` actor (recorded as needing an amendment to
    /// `Willagrams/Match/MatchSession.swift`). The pool's freshness is asserted
    /// the way it is observable: the new hand is made of tiles that did not
    /// exist in the finished match, which only a new `HostPool` can produce.
    @Test("No state from the finished match is visible in the new one")
    func theNewMatchStartsFresh() async throws {
        let practice = Self.practice()
        #expect(practice.start())
        try await SoloMatchTests.waitUntil("the opening hand") {
            practice.match?.session.state.hand.count == ShellModel.soloHandSize
        }
        let old = try #require(practice.match)

        // Play the finished match into a state a leak would be visible in: a
        // tile on the board, a drawn tile, and a win.
        let placed = try #require(old.session.state.hand.first)
        try old.session.place(tileID: placed.id, at: Coord(row: 8, col: 8))
        #expect(old.session.draw())
        // Both ends: `HostPool` grants to each player per draw, and the far
        // end's grant is a separate message that need not have landed yet.
        try await SoloMatchTests.waitUntil("the drawn tile at both ends") {
            old.session.state.hand.count == ShellModel.soloHandSize
                && old.peerTileIDs.count == ShellModel.soloHandSize + 1
        }
        #expect(old.session.state.board.placementList.isEmpty == false)
        let oldTileIDs = Set(old.session.state.hand.map(\.id))
            .union(old.session.state.board.placementList.map(\.tile.id))
            .union(old.peerTileIDs)
        let oldPeerTiles = old.peerTileIDs.count

        let results = try #require(practice.results())
        #expect(results.rematch())
        try await SoloMatchTests.waitUntil("the new opening hand") {
            practice.match?.session.state.hand.count == ShellModel.soloHandSize
        }
        let new = try #require(practice.match)

        #expect(new.session.state.board.placementList.isEmpty, "the finished board carried over")
        #expect(new.session.state.hand.count == ShellModel.soloHandSize)
        #expect(new.session.pendingDrawTiles.isEmpty)
        #expect(new.session.winner == nil)
        #expect(new.session.winningPlacements == nil)
        #expect(new.session.isMatchOver == false)
        #expect(new.session.poolIsExhausted == false)
        #expect(new.session.lastNote == nil)
        #expect(new.session.peerPresence == .present)
        try await Self.waitForPlay(practice)

        // A fresh `HostPool`, as far as it is observable: every tile in the new
        // match is a tile the finished one never held, at both ends.
        let newTileIDs = Set(new.session.state.hand.map(\.id)).union(new.peerTileIDs)
        #expect(newTileIDs.isDisjoint(with: oldTileIDs), "a tile survived the rematch")
        #expect(new.peerTileIDs.count == ShellModel.soloHandSize)
        // The finished match had spent more of its pool than an opening deal —
        // the far end took a tile on that draw too — so the disjointness above
        // is over a real difference and not two untouched pools.
        #expect(oldPeerTiles > ShellModel.soloHandSize)

        practice.end()
    }

    // MARK: - The ordering guardrail

    /// Down before up. Asserted by execution: at the moment the new match is
    /// built, the finished one is already shut.
    @Test("Rematch tears the old match down before it starts the new one")
    func rematchTearsDownBeforeStarting() async throws {
        let practice = Self.practice()
        #expect(practice.start())
        try await Self.waitForPlay(practice)
        let old = try #require(practice.match)

        var log: [String] = []
        let results = ResultsModel(
            shell: ShellModel(),
            session: old.session,
            teardown: { log.append("down"); practice.end() },
            rematch: {
                log.append(old.session.isMatchOver ? "up-after-down" : "up-too-early")
                practice.start()
            }
        )
        #expect(results.rematch())
        #expect(log == ["down", "up-after-down"], "the new match was built over a live one")

        practice.end()
    }
}
