import Foundation
import Testing

/// Guardrails checked against the bytes on disk rather than against a comment
/// claiming them. `ShellSrc` is a whole-directory symlink, so a single SwiftUI
/// file dropped into `Willagrams/Shell` stops this suite building for macOS —
/// this test fails first and says why.
@Suite("Shell source guardrails")
struct SourceGuardrailTests {

    /// Built at runtime so the scanner does not match its own source.
    private static let bannedFramework = "Swift" + "UI"

    private static var casesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    /// `ShellSrc`, the committed symlink to `Willagrams/Shell`.
    private static var shellSourceDirectory: URL {
        casesDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("ShellSrc")
            .resolvingSymlinksInPath()
    }

    private static func swiftFiles(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    /// True when `text` has an actual import statement, not merely a comment
    /// saying it must not have one — both source files carry that warning in
    /// their headers. Gated on the line being an import rather than on the exact
    /// spelling, so the submodule and attributed forms are caught too.
    private static func imports(_ framework: String, in text: String) -> Bool {
        text.components(separatedBy: "\n").contains { line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//") else { return false }
            guard code.hasPrefix("import ") || code.contains(" import ") else { return false }
            return code.contains(framework)
        }
    }

    @Test("No shell source or test pulls in SwiftUI")
    func noSwiftUIAnywhere() throws {
        let sources = try Self.swiftFiles(in: Self.shellSourceDirectory)
        let tests = try Self.swiftFiles(in: Self.casesDirectory)

        // A scan that finds nothing because it looked nowhere proves nothing.
        #expect(sources.count >= 2, "expected the shell sources at \(Self.shellSourceDirectory.path)")
        #expect(tests.count >= 2, "expected the test sources at \(Self.casesDirectory.path)")

        for file in sources + tests {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !Self.imports(Self.bannedFramework, in: text),
                "\(file.lastPathComponent) imports \(Self.bannedFramework)"
            )
        }
    }

    /// The route setter must stay private, or a view could assign a route
    /// instead of calling a transition.
    @Test("Only ShellModel may write the route")
    func routeSetterStaysPrivate() throws {
        let text = try String(
            contentsOf: Self.shellSourceDirectory.appendingPathComponent("ShellModel.swift"),
            encoding: .utf8
        )
        #expect(text.contains("public private(set) var route"))
    }
}
