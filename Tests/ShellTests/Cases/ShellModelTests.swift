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
}
