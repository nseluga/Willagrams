import Testing
import WillagramsRules
@testable import Shell

private let setup = MatchSetup(seed: 20260817, startingHandSize: 21, countdownSeconds: 3)

@MainActor
@Suite("Shell routing")
struct ShellModelTests {

    @Test("Menu → countdown → match, asserting the route after every transition")
    func fullPathToMatch() {
        let shell = ShellModel()
        #expect(shell.route == .menu)

        shell.startMatch(setup)
        #expect(shell.route == .countdown(setup))

        shell.countdownFinished()
        #expect(shell.route == .match(setup))
    }

    /// The menu's one action, asserted on the model — no view is instantiated.
    @Test("Solo Practice moves the route off .menu")
    func soloPracticeLeavesMenu() {
        let shell = ShellModel()
        shell.startSoloPractice(seed: 7)

        #expect(shell.route != .menu)
        #expect(
            shell.route == .countdown(
                MatchSetup(
                    seed: 7,
                    startingHandSize: ShellModel.soloHandSize,
                    countdownSeconds: ShellModel.soloCountdownSeconds
                )
            )
        )
    }

    /// Solo practice is two players' rules with one seat filled; the setup it
    /// starts must still be a legal one.
    @Test("Solo Practice deals a real hand and a real countdown")
    func soloPracticeSetupIsSane() {
        #expect(ShellModel.soloHandSize > 0)
        #expect(ShellModel.soloCountdownSeconds > 0)
    }

    @Test("The setup survives the countdown unchanged")
    func setupCarriesForward() {
        let shell = ShellModel()
        shell.startMatch(setup)
        shell.countdownFinished()

        guard case .match(let carried) = shell.route else {
            Issue.record("expected .match, got \(shell.route)")
            return
        }
        #expect(carried == setup)
    }

    @Test("A match ends at results carrying its winner")
    func matchToResults() {
        let shell = ShellModel(route: .match(setup))
        shell.matchEnded(winner: PlayerID(rawValue: "local"))
        #expect(shell.route == .results(winner: PlayerID(rawValue: "local")))
    }

    @Test("A match with no winner still reaches results")
    func matchToResultsWithoutWinner() {
        let shell = ShellModel(route: .match(setup))
        shell.matchEnded(winner: nil)
        #expect(shell.route == .results(winner: nil))
    }

    @Test("Return to menu is legal from every route")
    func returnToMenuFromAnywhere() {
        for start: AppRoute in [.menu, .countdown(setup), .match(setup), .results(winner: nil)] {
            let shell = ShellModel(route: start)
            shell.returnToMenu()
            #expect(shell.route == .menu, "returnToMenu failed from \(start)")
        }
    }

    /// The guards are the reason a route and its state cannot drift apart: an
    /// out-of-order call is a no-op, not a half-applied transition.
    @Test("Out-of-order transitions leave the route alone")
    func illegalTransitionsAreNoOps() {
        let onMenu = ShellModel()
        onMenu.countdownFinished()
        onMenu.matchEnded(winner: nil)
        #expect(onMenu.route == .menu)

        let inMatch = ShellModel(route: .match(setup))
        inMatch.startMatch(MatchSetup(seed: 1, startingHandSize: 1, countdownSeconds: 1))
        inMatch.countdownFinished()
        #expect(inMatch.route == .match(setup))

        let onResults = ShellModel(route: .results(winner: nil))
        onResults.matchEnded(winner: PlayerID(rawValue: "late"))
        #expect(onResults.route == .results(winner: nil))
    }

    /// The opponent's ending, which nothing used to handle.
    ///
    /// `MatchHUDModel` calls `matchEnded` on this player's own Win and Resign
    /// only. When the bot won, the session knew and the route did not move: every
    /// control was disabled by `isMatchOver` and Resign was refused by a locked
    /// session, so the match screen had no way out of it at all.
    @Test("An opponent's win ends the match on this device too")
    func anOpponentWinReachesTheResults() async throws {
        let shell = ShellModel(
            dictionary: { SoloMatchTests.EveryWordIsReal() },
            sleepFor: { _ in },
            seedSource: { 99 }
        )
        #expect(shell.startSoloPractice())
        let run = try #require(shell.run)
        try await SoloMatchTests.waitUntil("the match route") {
            if case .match = shell.route { return true }
            return false
        }

        run.match.bot.session.claimWin()

        try await SoloMatchTests.waitUntil("the results route") {
            shell.route == .results(winner: SoloMatch.peerPlayerID)
        }
        shell.returnToMenu()
    }
}
