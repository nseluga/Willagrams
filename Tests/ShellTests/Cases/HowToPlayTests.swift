import Foundation
import Testing
@testable import Shell
import Style

/// The rules screen is SwiftUI and cannot be constructed on macOS, so what is
/// asserted here is everything that is not the drawing: the copy, which lives in
/// `HowToPlay`, and the two transitions, which live on `ShellModel`.
@Suite("How to play")
struct HowToPlayTests {

    // MARK: - The copy

    @Test("Every game concept on the screen comes from Terminology")
    func namesConceptsFromTerminology() {
        let copy = HowToPlay.rules.map { $0.title + " " + $0.body }.joined(separator: "\n")
        for term in [Terminology.pool, Terminology.draw, Terminology.swap, Terminology.winCall] {
            #expect(copy.contains(term), "the rules never name \(term)")
        }
    }

    @Test("The rules explain the one-connected-group gate on Draw")
    func explainsTheDrawGate() {
        let copy = HowToPlay.rules.map(\.body).joined(separator: "\n").lowercased()
        #expect(copy.contains("connected"))
        #expect(copy.contains(Terminology.invalid.lowercased()))
    }

    /// The IP fence, over this screen specifically. `TerminologyFenceTests`
    /// scans every literal under `Willagrams/`; this one executes the assembled
    /// copy, so a term reaching the screen through interpolation is caught too.
    @Test("No Bananagrams term reaches the rules screen")
    func fenceHolds() {
        let copy = (HowToPlay.title + " " + HowToPlay.backLabel + " "
            + HowToPlay.rules.map { $0.title + " " + $0.body }.joined(separator: " ")).lowercased()
        for banned in ["bunch", "peel", "dump", "banana", "rotten", "spl" + "it"] {
            #expect(!copy.contains(banned), "the rules copy contains \"\(banned)\"")
        }
    }

    @Test("Every rule says something, and each heading is unique")
    func rulesAreWellFormed() {
        #expect(HowToPlay.rules.count >= 4)
        for rule in HowToPlay.rules {
            #expect(!rule.title.isEmpty)
            #expect(!rule.body.isEmpty)
        }
        #expect(Set(HowToPlay.rules.map(\.id)).count == HowToPlay.rules.count)
    }

    // MARK: - The route

    @MainActor
    @Test("The menu's action moves the route to the rules screen")
    func menuReachesTheRules() {
        let shell = ShellModel()
        shell.showHowToPlay()
        #expect(shell.route == .howToPlay)
    }

    @MainActor
    @Test("The screen's control goes back to the menu")
    func backReturnsToTheMenu() {
        let shell = ShellModel(route: .howToPlay)
        shell.returnToMenu()
        #expect(shell.route == .menu)
    }

    @MainActor
    @Test("The rules screen is unreachable from anywhere but the menu")
    func onlyReachableFromTheMenu() {
        let setup = MatchSetup(seed: 1, startingHandSize: 21, countdownSeconds: 3)
        for route in [AppRoute.countdown(setup), .match(setup), .results(winner: nil), .howToPlay] {
            let shell = ShellModel(route: route)
            shell.showHowToPlay()
            #expect(shell.route == route, "showHowToPlay moved the route away from \(route)")
        }
    }

    @MainActor
    @Test("A match cannot be started from the rules screen")
    func noMatchStartsFromTheRules() {
        let shell = ShellModel(route: .howToPlay)
        shell.startMatch(MatchSetup(seed: 1, startingHandSize: 21, countdownSeconds: 3))
        #expect(shell.route == .howToPlay)
    }

    /// The route carries no payload, so two visits to the screen are the same
    /// value and no match state can ride along.
    @Test("The route case carries nothing")
    func routeCarriesNothing() {
        #expect(AppRoute.howToPlay == AppRoute.howToPlay)
        #expect(AppRoute.howToPlay != AppRoute.menu)
    }
}
