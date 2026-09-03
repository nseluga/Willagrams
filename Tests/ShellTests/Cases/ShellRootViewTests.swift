import Foundation
import Testing
@testable import Shell

/// `ShellRootView` is SwiftUI and cannot be constructed on macOS, so what it
/// composes is checked against the bytes on disk — the same approach
/// `MatchViewTests` takes. What is executable here is the reachability claim
/// the Release fence rests on, and that is asserted against `ShellModel`.
@Suite("Shell root composition")
struct ShellRootViewTests {

    private static var source: String {
        get throws {
            try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("ShellSrc/ShellRootView.swift")
                    .resolvingSymlinksInPath(),
                encoding: .utf8
            )
        }
    }

    /// The lines that are code, so a comment describing a rule cannot satisfy
    /// or violate it.
    private static var code: [String] {
        get throws {
            try source
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.isEmpty }
        }
    }

    @Test("Every route renders its real screen")
    func routesRenderRealScreens() throws {
        let code = try Self.code
        for screen in ["MenuView(", "CountdownView(", "MatchView(", "ResultsView("] {
            #expect(code.contains { $0.contains(screen) }, "no \(screen) in ShellRootView")
        }
    }

    @Test("The placeholder helper and its labels are gone")
    func placeholderIsGone() throws {
        let source = try Self.source
        for banned in ["placeholder(", "matchLabel", "resultsLabel"] {
            #expect(!source.contains(banned), "ShellRootView still has \(banned)")
        }
    }

    /// The four cases and nothing else: no `if` on the route, no state, no
    /// second stored path to `ShellModel`.
    @Test("The root is a switch over the route with no state of its own")
    func holdsNoState() throws {
        let code = try Self.code
        #expect(code.contains { $0.contains("switch shell.route") })
        // Navigation containers are `AppRootTests`' guardrail; these are the
        // state wrappers that would put a decision in the view instead.
        for banned in ["@State", "@StateObject", "@ObservedObject", "@Environment"] {
            #expect(!code.contains { $0.contains(banned) }, "ShellRootView uses \(banned)")
        }
    }

    /// The absent-run branch, which is what keeps a route with no `MatchRun`
    /// from crashing.
    @Test("Each match screen is guarded on the run being present")
    func guardsOnRunPresence() throws {
        let code = try Self.code
        #expect(code.filter { $0.contains("if let run = shell.run") }.count == 3)
    }

    /// The board goes down as bindings so the deal the countdown shows lands in
    /// the very board the match screen goes on to draw.
    @Test("The countdown gets bindings into the run's board, not copies")
    func countdownPassesBindings() throws {
        let code = try Self.code
        #expect(code.contains { $0.contains("board: $matchBoard.board") })
        #expect(code.contains { $0.contains("model: $matchBoard.model") })
    }

    /// The wire that was missing: `MatchSession` flips its own status to
    /// `.playing` when the count runs out, and until this landed nothing told
    /// the route. Every `countdownFinished()` call site was a test, so the
    /// suite stayed green over an app that dealt a rack and then sat there with
    /// no HUD. A source check, because the transition lives in a `View`.
    @Test("The countdown ending is carried to the route")
    func countdownAdvancesTheRoute() throws {
        let code = try Self.code
        #expect(code.contains { $0.contains("shell.countdownFinished()") },
                "nothing in ShellRootView leaves the countdown route")
    }

    /// What the Release fence rests on: the route cannot leave `.menu` when no
    /// run can be built, so the empty branches are unreachable rather than
    /// blank screens a player can land on. Executable in Debug only in the
    /// negative — here we assert the coupling, that the route advances exactly
    /// when a run was built.
    @MainActor
    @Test("The route advances only when startSoloPractice reports it did")
    func routeFollowsTheReturnValue() {
        let shell = ShellModel()
        let started = shell.startSoloPractice(seed: 7)
        #expect(started == (shell.route != .menu))
    }
}
