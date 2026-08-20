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

    /// This package's manifest, the single list of shell files this target does
    /// not compile.
    private static var manifest: String {
        get throws {
            try String(
                contentsOf: casesDirectory
                    .deletingLastPathComponent()
                    .appendingPathComponent("Package.swift"),
                encoding: .utf8
            )
        }
    }

    @Test("No compiled shell source and no test pulls in SwiftUI")
    func noSwiftUIAnywhere() throws {
        let sources = try Self.swiftFiles(in: Self.shellSourceDirectory)
        let tests = try Self.swiftFiles(in: Self.casesDirectory)
        let manifest = try Self.manifest

        // A scan that finds nothing because it looked nowhere proves nothing.
        #expect(sources.count >= 2, "expected the shell sources at \(Self.shellSourceDirectory.path)")
        #expect(tests.count >= 2, "expected the test sources at \(Self.casesDirectory.path)")

        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard Self.imports(Self.bannedFramework, in: text) else { continue }
            // A view may live here, but only if the manifest excludes it — an
            // unexcluded one breaks the macOS build instead of failing a test.
            #expect(
                manifest.contains("\"\(file.lastPathComponent)\""),
                "\(file.lastPathComponent) imports \(Self.bannedFramework) but Package.swift does not exclude it"
            )
        }

        for file in tests {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !Self.imports(Self.bannedFramework, in: text),
                "\(file.lastPathComponent) imports \(Self.bannedFramework)"
            )
        }
    }

    /// Nothing may be excluded that does not need to be: an excluded pure source
    /// would silently drop out of the suite.
    @Test("Every excluded shell file exists and really is a view")
    func exclusionsAreViewsThatExist() throws {
        let manifest = try Self.manifest
        for file in try Self.swiftFiles(in: Self.shellSourceDirectory) {
            guard manifest.contains("\"\(file.lastPathComponent)\"") else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                Self.imports(Self.bannedFramework, in: text),
                "\(file.lastPathComponent) is excluded but does not import \(Self.bannedFramework)"
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
