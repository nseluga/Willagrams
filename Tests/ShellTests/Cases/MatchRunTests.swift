import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell

/// One test per acceptance criterion for the match run: the one thing that owns
/// a match across the countdown, match and results routes. Every assertion here
/// is about *instance identity* — the same session throughout, and no second one
/// alive at any point.
@MainActor
@Suite("Match run")
struct MatchRunTests {

    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal

    /// A shell whose seeds are a known increasing sequence and whose countdown
    /// clock returns immediately.
    static func shell(from first: UInt64 = 500) -> ShellModel {
        let counter = RematchTests.Counter(first &- 1)
        return ShellModel(
            dictionary: { EveryWordIsReal() },
            sleepFor: { _ in },
            seedSource: { counter.next() }
        )
    }

    // MARK: - Criterion 1: one session, read by all three routes

    @Test("Starting solo practice builds one run, and every route reads its session")
    func oneSessionAcrossEveryRoute() async throws {
        let shell = Self.shell()
        #expect(shell.run == nil, "a run existed before anything started it")
        #expect(shell.startSoloPractice())

        let run = try #require(shell.run)
        let session = run.session

        // The three things a route renders are all built over that one session.
        #expect(run.match.session === session)
        // The board mirrors the session rather than holding a second copy: the
        // opening deal lands on both or on neither.
        try await SoloMatchTests.waitUntil("the opening deal to be laid") {
            run.board.board.placementList.count == ShellModel.soloHandSize
        }
        #expect(session.state.board.placementList.count == ShellModel.soloHandSize)

        // Countdown → match → results, and the run is the same object at each.
        #expect(shell.route == .countdown(
            MatchSetup(
                seed: run.seed,
                startingHandSize: ShellModel.soloHandSize,
                countdownSeconds: ShellModel.soloCountdownSeconds
            )
        ))
        shell.countdownFinished()
        #expect(shell.run === run, "the match route rebuilt the run")
        #expect(shell.run?.session === session)

        shell.matchEnded(winner: nil)
        #expect(shell.run === run, "the results route rebuilt the run")
        #expect(shell.run?.session === session)
        // The end screen the results route renders is built over that session
        // too, not over a fresh one.
        #expect(run.results().outcome == .noWinner)

        shell.returnToMenu()
    }

    @Test("A second start replaces the run rather than adding one")
    func aSecondStartReplacesTheRun() async throws {
        let shell = Self.shell()
        #expect(shell.startSoloPractice())
        let first = try #require(shell.run)

        #expect(shell.startSoloPractice())
        let second = try #require(shell.run)

        #expect(second !== first, "a second start handed back the live run")
        #expect(second.session !== first.session)
        #expect(first.session.isMatchOver, "the previous run was left running")

        shell.returnToMenu()
    }

    // MARK: - Criterion 2: returning to the menu tears the run down

    @Test("Returning to the menu leaves the transport, and the dead wire reaches nothing")
    func returningToTheMenuTearsTheRunDown() async throws {
        let shell = Self.shell()
        #expect(shell.startSoloPractice())
        // Held strongly on purpose: a wire that refuses only because its owner
        // deallocated would prove nothing about the teardown.
        let finished = try #require(shell.run)
        try await SoloMatchTests.waitUntil("play to begin") {
            finished.session.state.status == .playing
        }

        shell.returnToMenu()

        #expect(shell.route == .menu)
        #expect(shell.run == nil, "the menu was shown over a live run")
        #expect(finished.session.isMatchOver, "the finished session was never left")

        // The far end's pump is cancelled and its transport left, so a send
        // afterwards is refused outright.
        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await finished.match.peerTransport.send(
                .resign(player: SoloMatch.peerPlayerID), delivery: .reliable
            )
        }

        // And it changes nothing on the session that replaces it. The live send
        // is second and waited on, so the negative is read on a provably later
        // turn than the dead one.
        #expect(shell.startSoloPractice())
        let live = try #require(shell.run)
        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await finished.match.peerTransport.send(
                .win(player: SoloMatch.peerPlayerID, placements: []), delivery: .reliable
            )
        }
        try await live.match.peerTransport.send(
            .resign(player: SoloMatch.peerPlayerID), delivery: .reliable
        )
        try await SoloMatchTests.waitUntil("the live session to take its own peer's message") {
            live.session.winner != nil
        }
        #expect(
            live.session.winner == SoloMatch.localPlayerID,
            "the finished run's wire reached the live session"
        )
        #expect(live.session.winningPlacements == nil)

        shell.returnToMenu()
    }

    // MARK: - Criterion 3: rematch

    @Test("Rematch builds a new session on a new seed, unreachable from the old wire")
    func rematchRebuildsEverything() async throws {
        let shell = Self.shell()
        #expect(shell.startSoloPractice())
        let old = try #require(shell.run)
        let oldSeed = try #require(shell.seed)
        try await SoloMatchTests.waitUntil("play to begin") {
            old.session.state.status == .playing
        }

        let results = old.results()
        #expect(results.isRematchEnabled)
        #expect(results.rematch())

        let new = try #require(shell.run)
        #expect(new !== old, "rematch reused the finished run")
        #expect(new.session !== old.session, "rematch reused the finished session")
        #expect(new.board !== old.board, "rematch reused the finished board")
        #expect(new.hud !== old.hud, "rematch reused the finished HUD")
        #expect(shell.seed != oldSeed, "rematch replayed the previous deal")
        #expect(new.seed == shell.seed)
        #expect(old.session.isMatchOver, "the finished run was left running")

        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await old.match.peerTransport.send(
                .resign(player: SoloMatch.peerPlayerID), delivery: .reliable
            )
        }
        #expect(new.session.winner == nil, "the finished run's wire reached the new session")

        shell.returnToMenu()
    }

    /// The ordering guardrail, asserted by execution: at the moment the new run
    /// exists, the finished one is already shut. Two live sessions never overlap.
    @Test("A rematch tears the old run down before it builds the new one")
    func rematchTearsDownBeforeBuilding() async throws {
        let shell = Self.shell()
        #expect(shell.startSoloPractice())
        let old = try #require(shell.run)
        try await SoloMatchTests.waitUntil("play to begin") {
            old.session.state.status == .playing
        }

        // Read at the instant the replacement is published — `run` is observed,
        // so the new value is what a screen would see.
        #expect(old.results().rematch())
        let new = try #require(shell.run)
        #expect(new !== old)
        #expect(old.session.isMatchOver, "the new run was built over a live one")

        shell.returnToMenu()
    }

    // MARK: - What a rematch must not rebuild

    /// The word list is a ~172k-entry `Set` read off disk. Rebuilding one per
    /// rematch is a main-actor stall between the end screen and the next deal,
    /// so it is loaded once per launch and reused.
    @Test("The word list is built once per launch, not once per match")
    func theWordListIsBuiltOnce() async throws {
        let builds = Builds()
        let shell = ShellModel(
            dictionary: { builds.count += 1; return EveryWordIsReal() },
            sleepFor: { _ in },
            seedSource: { 700 }
        )
        #expect(builds.count == 0, "a word list was built before any match")

        #expect(shell.startSoloPractice())
        #expect(builds.count == 1)
        let run = try #require(shell.run)
        #expect(run.results().rematch())
        #expect(shell.run !== run, "the rematch built no new run")
        #expect(builds.count == 1, "a rematch rebuilt the word list")

        shell.returnToMenu()
    }

    /// A box, so the closure and the test share one tally.
    final class Builds { var count = 0 }

    /// A missing bundled list degrades to a list that accepts no word. Memoizing
    /// that would make every match of the process unwinnable off one bad read,
    /// so the degraded list is never cached and the next match retries.
    @Test("A degraded word list is retried on the next match, not cached")
    func aDegradedWordListIsNotCached() async throws {
        let builds = Builds()
        let shell = ShellModel(
            dictionary: {
                builds.count += 1
                // The first read fails the way a missing bundle does; the second
                // succeeds, as a transient read failure would.
                return builds.count == 1
                    ? EnableWordList(words: [])
                    : EnableWordList(words: ["cat"])
            },
            sleepFor: { _ in },
            seedSource: { 800 }
        )

        #expect(shell.startSoloPractice())
        #expect(builds.count == 1)
        shell.returnToMenu()

        #expect(shell.startSoloPractice())
        #expect(builds.count == 2, "the degraded list was cached instead of retried")
        shell.returnToMenu()

        // The recovered list is cached like any other.
        #expect(shell.startSoloPractice())
        #expect(builds.count == 2, "the recovered list was rebuilt")
        shell.returnToMenu()
    }

    // MARK: - No cycle back to the shell

    /// A shell dropped mid-match must take itself, its run, that run's session,
    /// board and HUD with it. A strong reference from either the run or the HUD
    /// back to the shell closes a cycle that leaks all five.
    @Test("A shell dropped mid-match leaks neither itself nor its run")
    func aDroppedShellLeaksNothing() async throws {
        weak var weakShell: ShellModel?
        weak var weakRun: MatchRun?
        weak var weakSession: MatchSession?
        weak var weakHUD: MatchHUDModel?
        try await {
            let shell = Self.shell()
            #expect(shell.startSoloPractice())
            let run = try #require(shell.run)
            try await SoloMatchTests.waitUntil("play to begin") {
                run.session.state.status == .playing
            }
            weakShell = shell
            weakRun = run
            weakSession = run.session
            weakHUD = run.hud
        }()

        // Nothing is torn down first: the shell is simply dropped, which is the
        // case a cycle survives.
        try await SoloMatchTests.waitUntil("the dropped shell and its run to be released") {
            weakShell == nil && weakRun == nil && weakSession == nil && weakHUD == nil
        }
    }

    // MARK: - The run is released, not merely unreferenced

    @Test("A torn-down run is released, along with its session, board and HUD")
    func aTornDownRunIsReleased() async throws {
        let shell = Self.shell()
        #expect(shell.startSoloPractice())

        weak var weakRun: MatchRun?
        weak var weakSession: MatchSession?
        weak var weakBoard: MatchBoard?
        weak var weakHUD: MatchHUDModel?
        try await {
            let run = try #require(shell.run)
            try await SoloMatchTests.waitUntil("play to begin") {
                run.session.state.status == .playing
            }
            weakRun = run
            weakSession = run.session
            weakBoard = run.board
            weakHUD = run.hud
        }()

        shell.returnToMenu()
        // Read on a later turn: a session's own tasks need a turn to finish on,
        // and a same-turn read proves nothing.
        try await SoloMatchTests.waitUntil("the run to be released") {
            weakRun == nil && weakSession == nil && weakBoard == nil && weakHUD == nil
        }
    }
}
