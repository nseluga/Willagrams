import Foundation
import Testing
@testable import Shell

/// The launch path, asserted where it can be: the route a fresh `ShellModel`
/// reports, plus source-text guardrails over the two directories the app root
/// lives in. `ShellRootView` itself is a `switch` over that route with no
/// branch of its own, so the route is the whole decision.
@MainActor
@Suite("App root")
struct AppRootTests {

    @Test("A freshly constructed ShellModel launches on the menu")
    func launchRouteIsMenu() {
        #expect(ShellModel().route == .menu)
    }

    /// `ShellSrc` resolves to `Willagrams/Shell`, so its parent's parent is the
    /// repository root.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ShellSrc")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func swiftSources(under relativePath: String) throws -> [(name: String, text: String)] {
        let root = repoRoot.appendingPathComponent(relativePath)
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return try walk.compactMap { entry in
            guard let name = entry as? String, name.hasSuffix(".swift") else { return nil }
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            return (name, text)
        }
    }

    /// Full-bleed modes, not a drill-down hierarchy: a nav container here would
    /// be hidden on every screen and would put routing state inside a View.
    @Test("No navigation container under Shell or App")
    func noNavigationContainers() throws {
        let files = try Self.swiftSources(under: "Willagrams/Shell")
            + Self.swiftSources(under: "Willagrams/App")
        #expect(files.count >= 3, "expected the shell and app sources at \(Self.repoRoot.path)")

        for banned in ["Navigation" + "Stack", "Navigation" + "View"] {
            for file in files {
                #expect(!file.text.contains(banned), "\(file.name) uses \(banned)")
            }
        }
    }

    /// The throwaway board harness that used to be the app root, with its fixed
    /// seed and its hard-coded 1366x1024 viewport, is gone for good.
    @Test("The board harness appears nowhere in the app sources")
    func harnessIsGone() throws {
        let files = try Self.swiftSources(under: "Willagrams")
        #expect(files.count >= 10, "expected the app sources at \(Self.repoRoot.path)")
        let banned = "Board" + "Harness"
        for file in files {
            #expect(!file.text.contains(banned), "\(file.name) still references \(banned)")
        }
    }
}
