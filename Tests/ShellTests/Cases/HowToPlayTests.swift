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

    // MARK: - The view wiring (source scan — HowToPlayView imports SwiftUI and
    // is excluded from this target, so its claims are only checkable as text)

    @Test("The view pages through HowToPlay.rules with a HowToPlayPager, not a grid of all of them")
    func viewPagesRatherThanGrids() throws {
        let text = try HowToPlayTests.viewSource()
        let scope = try #require(
            HowToPlayTests.declaration("struct HowToPlayView", in: text),
            "HowToPlayView declaration not found"
        )
        #expect(scope.contains("HowToPlayPager"), "the view does not hold a HowToPlayPager")
        #expect(scope.contains("pager.pageLabel"), "the view does not show the pager's page label")
        #expect(scope.contains("pager.primaryLabel"), "the view does not show the pager's primary label")
        #expect(!scope.contains("LazyVGrid"), "the view still lays every rule out in a grid")
    }

    private static func viewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Cases
            .deletingLastPathComponent()   // ShellTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Willagrams/Shell/HowToPlayView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text from `header` to the file's end — good enough when the file
    /// holds exactly one declaration of interest, which both views here do.
    private static func declaration(_ header: String, in text: String) -> String? {
        guard let range = text.range(of: header) else { return nil }
        return String(text[range.lowerBound...])
    }
}

/// `HowToPlayPager` is a plain value, so its logic is reachable directly —
/// no view, no `ShellModel`, no `@MainActor`.
@Suite("How to play pager")
struct HowToPlayPagerTests {

    @Test("Starts on page 1 of however many rules there are")
    func startsOnPageOne() {
        let pager = HowToPlayPager(count: HowToPlay.rules.count)
        #expect(pager.page == 1)
        #expect(pager.pageLabel == "1 OF \(HowToPlay.rules.count)")
    }

    @Test("Next advances the page")
    func nextAdvances() {
        var pager = HowToPlayPager(count: HowToPlay.rules.count)
        pager.next()
        #expect(pager.page == 2)
    }

    @Test("Back at page 1 stays at page 1")
    func backClampsAtOne() {
        var pager = HowToPlayPager(count: HowToPlay.rules.count)
        pager.back()
        #expect(pager.page == 1)
    }

    @Test("The last page's primary label is Done")
    func lastPageReadsDone() {
        var pager = HowToPlayPager(count: HowToPlay.rules.count)
        for _ in 1..<HowToPlay.rules.count { pager.next() }
        #expect(pager.isLastPage)
        #expect(pager.primaryLabel == "Done")
    }

    @Test("A page short of the last reads Next")
    func midPageReadsNext() {
        var pager = HowToPlayPager(count: HowToPlay.rules.count)
        pager.next()
        #expect(pager.primaryLabel == "Next")
    }

    @Test("The page label reads N OF M, the comp's format")
    func pageLabelFormat() {
        var pager = HowToPlayPager(count: HowToPlay.rules.count)
        pager.next()
        #expect(pager.pageLabel == "2 OF \(HowToPlay.rules.count)")
    }

    @Test("Next never advances past the last page")
    func nextStopsAtTheLastPage() {
        var pager = HowToPlayPager(count: HowToPlay.rules.count)
        for _ in 0..<(HowToPlay.rules.count + 5) { pager.next() }
        #expect(pager.page == HowToPlay.rules.count)
    }
}
