import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell

/// Independent QA verification of the match-run criteria and guardrails.
/// Written against the stated criteria, not against the implementation: each
/// test names the criterion it gates and proves it by execution.
@MainActor
@Suite("QA: match run")
struct QAMatchRunTests {

    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal

    static func shell(from first: UInt64 = 9000) -> ShellModel {
        let counter = RematchTests.Counter(first &- 1)
        return ShellModel(
            dictionary: { EveryWordIsReal() },
            sleepFor: { _ in },
            seedSource: { counter.next() }
        )
    }

    // MARK: - Guardrail: never two live sessions at once

    /// The ordering guardrail proved through the *real* path, not a synthetic
    /// `ResultsModel`. `seedSource` is called by `startSoloPractice` after the
    /// teardown and before the replacement is built, so it is a window onto the
    /// exact instant between down and up: `run` must already be nil there, and
    /// the previous session must already be over.
    @Test("The old run is torn down before the replacement is constructed")
    func teardownStrictlyPrecedesConstruction() async throws {
        var observedRunAtBuildTime: [Bool] = []
        var previousSessionOverAtBuildTime: [Bool] = []
        var previous: MatchSession?
        var shellBox: ShellModel?

        let counter = RematchTests.Counter(4999)
        let shell = ShellModel(
            dictionary: { EveryWordIsReal() },
            sleepFor: { _ in },
            seedSource: {
                observedRunAtBuildTime.append(shellBox?.run != nil)
                previousSessionOverAtBuildTime.append(previous?.isMatchOver ?? true)
                return counter.next()
            }
        )
        shellBox = shell

        #expect(shell.startSoloPractice())
        let first = try #require(shell.run)
        try await SoloMatchTests.waitUntil("play to begin") {
            first.session.state.status == .playing
        }
        previous = first.session

        // Rematch through the real end-screen closures.
        #expect(first.results()?.rematch() == true)
        let second = try #require(shell.run)
        #expect(second.session !== first.session)

        #expect(
            observedRunAtBuildTime == [false, false],
            "a run was still held when the replacement was being built: \(observedRunAtBuildTime)"
        )
        #expect(
            previousSessionOverAtBuildTime == [true, true],
            "the previous session was still live when the replacement was built"
        )

        shell.returnToMenu()
    }

    // MARK: - Criterion 1: one session, read by countdown, match and results

    @Test("Countdown, match and results all read the one session built at start")
    func oneSessionAcrossAllThreeRoutes() async throws {
        let shell = Self.shell()
        #expect(shell.run == nil)
        #expect(shell.startSoloPractice())

        let run = try #require(shell.run)
        let session = run.session

        // Countdown route.
        guard case .countdown = shell.route else {
            Issue.record("start did not route to countdown: \(shell.route)")
            return
        }
        #expect(shell.run?.session === session)
        #expect(run.match.session === session)

        // The board the countdown/match route draws is fed by that session:
        // the opening deal lands on both or on neither.
        try await SoloMatchTests.waitUntil("the opening deal to be laid") {
            run.board.board.placementList.count == ShellModel.soloHandSize
        }
        #expect(session.state.board.placementList.count == ShellModel.soloHandSize)

        // Match route.
        shell.countdownFinished()
        #expect(shell.run === run, "the match route rebuilt the run")
        #expect(shell.run?.session === session)
        try await SoloMatchTests.waitUntil("play to begin") {
            session.state.status == .playing
        }

        // The HUD acts on that same session — a resign through it ends this
        // session and is what carries the shell to the results route.
        run.hud.armResign()
        #expect(run.hud.confirmResign())
        #expect(session.isMatchOver, "the HUD resigned some other session")
        #expect(session.winner == SoloMatch.peerPlayerID)
        #expect(shell.route == .results(winner: SoloMatch.peerPlayerID))

        // Results route — same run, and the end screen reads that session's
        // outcome rather than a fresh one's.
        #expect(shell.run === run, "the results route rebuilt the run")
        #expect(shell.run?.session === session)
        #expect(run.results()?.outcome == .peerWin)

        shell.returnToMenu()
    }

    // MARK: - Criterion 2: returning to the menu

    /// A `.win` from the finished run's transport would set `winner` and
    /// `winningPlacements` on any session that received it. After a return to
    /// the menu the send is refused, and the session that replaces it is
    /// untouched — read on a later turn than a live send that *does* land.
    @Test("A finished run's transport changes no state on the session that replaces it")
    func deadWireChangesNothingOnTheLiveSession() async throws {
        let shell = Self.shell()
        #expect(shell.startSoloPractice())
        let finished = try #require(shell.run)
        try await SoloMatchTests.waitUntil("play to begin") {
            finished.session.state.status == .playing
        }

        shell.returnToMenu()
        #expect(shell.route == .menu)
        #expect(shell.run == nil, "the menu was shown over a live run")
        #expect(finished.session.isMatchOver, "the transport was never left")

        #expect(shell.startSoloPractice())
        let live = try #require(shell.run)
        try await SoloMatchTests.waitUntil("the new run to begin play") {
            live.session.state.status == .playing
        }

        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await finished.match.peerTransport.send(
                .win(player: SoloMatch.peerPlayerID, placements: []), delivery: .reliable
            )
        }

        // Order the read after a message that provably does land, so "nothing
        // arrived" is not merely "nothing has arrived yet".
        try await live.match.peerTransport.send(
            .resign(player: SoloMatch.peerPlayerID), delivery: .reliable
        )
        try await SoloMatchTests.waitUntil("the live session's own peer message") {
            live.session.winner != nil
        }
        #expect(
            live.session.winner == SoloMatch.localPlayerID,
            "the finished run's wire reached the live session"
        )
        #expect(live.session.winningPlacements == nil)
        #expect(live.session !== finished.session)

        shell.returnToMenu()
    }

    // MARK: - Criterion 3: rematch

    @Test("Rematch yields a new session on a new seed the old wire cannot reach")
    func rematchIsANewSessionOnANewSeed() async throws {
        let shell = Self.shell()
        #expect(shell.startSoloPractice())
        let old = try #require(shell.run)
        let oldSeed = try #require(shell.seed)
        #expect(old.seed == oldSeed)
        try await SoloMatchTests.waitUntil("play to begin") {
            old.session.state.status == .playing
        }

        #expect(old.results()?.rematch() == true)
        let new = try #require(shell.run)

        #expect(new.session !== old.session, "rematch reused the finished session")
        #expect(new.seed != oldSeed, "rematch replayed the previous deal")
        #expect(shell.seed == new.seed)
        #expect(old.session.isMatchOver)

        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await old.match.peerTransport.send(
                .win(player: SoloMatch.peerPlayerID, placements: []), delivery: .reliable
            )
        }
        try await SoloMatchTests.waitUntil("the new run to begin play") {
            new.session.state.status == .playing
        }
        #expect(new.session.winner == nil, "the finished run's wire reached the new session")
        #expect(new.session.isMatchOver == false)

        shell.returnToMenu()
    }

    // MARK: - Guardrail: MatchRun makes no routing decision

    /// Building an end screen and leaving a run are `MatchRun`'s own operations
    /// and neither moves the route — only `ShellModel` does that.
    @Test("MatchRun makes no routing decision of its own")
    func matchRunDoesNotRoute() async throws {
        let shell = Self.shell()
        #expect(shell.startSoloPractice())
        shell.countdownFinished()
        let run = try #require(shell.run)
        let routeBefore = shell.route

        _ = run.results()
        #expect(shell.route == routeBefore, "building the end screen moved the route")

        run.leave()
        #expect(shell.route == routeBefore, "leaving the run moved the route")
        #expect(run.session.isMatchOver)

        shell.returnToMenu()
    }
}
