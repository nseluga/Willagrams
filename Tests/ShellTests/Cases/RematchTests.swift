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
        #expect(second.session.roster == firstSession.roster)
        #expect(second.session.localPlayerID == SoloMatch.localPlayerID)
        #expect(HostPool.host(of: second.session.roster) == second.session.localPlayerID)
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
            // `.playing` says the match opened, not that the far end has taken
            // its opening tiles — those land on a later turn. Reading the count
            // straight after the status wait races that, and loses about one run
            // in six. Waiting for the hand is the assertion.
            try await SoloMatchTests.waitUntil("the live far end to take its opening") {
                live.peerTileIDs.count == ShellModel.soloHandSize
            }
            let dealt = live.peerTileIDs.count
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

        // Sent after the rebuild, on the wire the finished match owned, and
        // deliberately a *different* message from the control below: a `.win`
        // would name the peer as winner and carry placements, where the
        // control's `.resign` names the local player and carries none. Whichever
        // landed is therefore readable off the result rather than guessed at.
        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await old.peerTransport.send(
                .win(player: SoloMatch.peerPlayerID, placements: []), delivery: .reliable
            )
        }

        // The control: the *new* match's own far end does what the old one could
        // not. It is sent second and waited on, so the negative below is read on
        // a turn that is provably later than the send above — no guessed count
        // of yields, and no chance of reading "has not arrived yet" as "refused".
        try await new.peerTransport.send(
            .resign(player: SoloMatch.peerPlayerID), delivery: .reliable
        )
        try await SoloMatchTests.waitUntil("the new session to take its own peer's message") {
            new.session.winner != nil
        }
        #expect(
            new.session.winner == SoloMatch.localPlayerID,
            "the finished match's wire reached the new session"
        )
        #expect(new.session.winningPlacements == nil)

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
        // Wait for the far end's opening before reading it. `.playing` does not
        // mean the peer hand has landed, and a short read would make the
        // disjointness below true over fewer tiles than the match actually
        // holds — passing for the wrong reason.
        try await SoloMatchTests.waitUntil("the new far end to take its opening") {
            new.peerTileIDs.count == ShellModel.soloHandSize
        }

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

    // MARK: - A stale end screen

    /// `results()` is a factory, and SwiftUI calls a factory again on every
    /// re-render, so `ResultsModel`'s spend-once guard is per screen instance
    /// and cannot stop an older instance acting. The closures are bound to the
    /// generation that was live when they were built; each half is proved on its
    /// own below, because a guard on one closure only is the exact half-fix this
    /// run has been bitten by.
    @Test("A stale end screen's Main Menu cannot end the match that replaced it")
    func aStaleScreenCannotEndTheNewMatch() async throws {
        let practice = Self.practice()
        #expect(practice.start())
        try await Self.waitForPlay(practice)

        // Two screens over the same generation — exactly what a re-render gives.
        let stale = try #require(practice.results())
        let current = try #require(practice.results())
        #expect(current.rematch())
        try await Self.waitForPlay(practice)
        let new = try #require(practice.match)

        stale.mainMenu()

        #expect(practice.match === new, "a stale screen dropped the live match")
        #expect(new.session.isMatchOver == false, "a stale screen ended the live match")
        #expect(new.session.state.status == .playing)
        // The live end still delivers, so the stale screen did not take the
        // current generation's pump down either. The far end's opening grant is
        // its own message, so it is waited for rather than assumed landed.
        try await SoloMatchTests.waitUntil("the live far end's opening") {
            new.peerTileIDs.count == ShellModel.soloHandSize
        }
        let dealt = new.peerTileIDs.count
        #expect(new.session.draw())
        try await SoloMatchTests.waitUntil("the live far end to take another tile") {
            new.peerTileIDs.count == dealt + 1
        }

        practice.end()
    }

    /// The route change and the teardown are one decision. A stale press that
    /// declines to end the live match must not park the route on the menu
    /// either, or the app shows the menu over a match that is still pumping.
    @Test("A stale end screen's Main Menu leaves the live match's route alone")
    func aStaleScreenCannotSendTheNewMatchToTheMenu() async throws {
        let counter = Counter(99)
        let shell = ShellModel()
        let practice = SoloPractice(
            shell: shell,
            dictionary: EveryWordIsReal(),
            sleepFor: { _ in },
            seedSource: { counter.next() }
        )
        #expect(practice.start())
        try await Self.waitForPlay(practice)

        let stale = try #require(practice.results())
        let current = try #require(practice.results())
        #expect(current.rematch())
        try await Self.waitForPlay(practice)
        let new = try #require(practice.match)
        let liveRoute = shell.route

        stale.mainMenu()

        #expect(shell.route == liveRoute, "a stale screen sent the live match to the menu")
        #expect(shell.route != .menu)
        #expect(practice.match === new, "a stale screen dropped the live match")
        #expect(new.session.isMatchOver == false)
        #expect(new.session.state.status == .playing)

        // A live screen over the current generation still works: it both tears
        // down and navigates. (`current` spent its closures on the rematch.)
        let live = try #require(practice.results())
        live.mainMenu()
        #expect(shell.route == .menu)
        #expect(practice.match == nil)

        practice.end()
    }

    @Test("A stale end screen's Main Menu declines every press, not just the first")
    func aStaleScreenDeclinesRepeatedMainMenuPresses() async throws {
        let counter = Counter(99)
        let shell = ShellModel()
        let practice = SoloPractice(
            shell: shell,
            dictionary: EveryWordIsReal(),
            sleepFor: { _ in },
            seedSource: { counter.next() }
        )
        #expect(practice.start())
        try await Self.waitForPlay(practice)

        let stale = try #require(practice.results())
        let current = try #require(practice.results())
        #expect(current.rematch())
        try await Self.waitForPlay(practice)
        let new = try #require(practice.match)
        let liveRoute = shell.route

        // A decline must not spend the screen. If the first press drops the
        // teardown, the screen becomes a no-teardown screen — the one kind that
        // navigates unconditionally — and the second press goes through.
        for press in 1...3 {
            stale.mainMenu()
            #expect(shell.route == liveRoute, "press \(press) sent the live match to the menu")
            #expect(shell.route != .menu, "press \(press) reached the menu")
            #expect(practice.match === new, "press \(press) dropped the live match")
            #expect(new.session.isMatchOver == false, "press \(press) ended the live match")
        }

        // The other door into the same hole: a stale Rematch rebuilds nothing,
        // so it must not spend the teardown either — otherwise the Main Menu
        // after it reads as "nothing to tear down" and navigates.
        #expect(stale.rematch() == false, "a stale screen claimed it started a rematch")
        stale.mainMenu()
        #expect(shell.route == liveRoute, "Main Menu after a stale Rematch reached the menu")
        #expect(practice.match === new, "a stale Rematch dropped the live match")
        #expect(new.session.isMatchOver == false)

        // The live screen still works after all that.
        let live = try #require(practice.results())
        live.mainMenu()
        #expect(shell.route == .menu)
        #expect(practice.match == nil)

        practice.end()
    }

    @Test("A stale end screen's Rematch cannot rebuild over the match that replaced it")
    func aStaleScreenCannotRebuildOverTheNewMatch() async throws {
        let practice = Self.practice()
        #expect(practice.start())
        try await Self.waitForPlay(practice)

        let stale = try #require(practice.results())
        let current = try #require(practice.results())
        #expect(current.rematch())
        try await Self.waitForPlay(practice)
        let new = try #require(practice.match)
        let seedAfterRematch = practice.seed

        // The press is refused outright: a stale screen builds nothing, so
        // reporting it as taken would be a lie, and spending its teardown would
        // leave it able to navigate on the way out. Nothing built, nothing spent.
        #expect(stale.rematch() == false, "a stale screen claimed it started a rematch")

        #expect(practice.match === new, "a stale screen rebuilt over the live match")
        #expect(practice.seed == seedAfterRematch, "a stale screen redealt the live match")
        #expect(new.session.isMatchOver == false)
        #expect(new.session.state.status == .playing)

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
            teardown: { log.append("down"); practice.end(); return true },
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
