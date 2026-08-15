import Foundation
import Testing

/// Guardrails checked against the bytes on disk rather than against a comment
/// claiming them. Only the adapter file may pull in the Game Center framework;
/// every file in this lane has to build and be testable without it.
@Suite("Match source guardrails")
struct SourceGuardrailTests {

    /// Built at runtime so this scanner does not match its own source, and so
    /// an attributed or access-qualified form of the import is still caught.
    private static let bannedImport = "import " + "GameKit"

    /// This file's own directory — the test sources.
    private static var casesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    /// `MatchSrc`, the committed symlink to `Willagrams/Match`.
    private static var matchSourceDirectory: URL {
        casesDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("MatchSrc")
            .resolvingSymlinksInPath()
    }

    private static func swiftFiles(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    /// True when `text` has an actual import statement, not merely a comment
    /// saying it must not have one — both source files carry that warning in
    /// their headers, and a scan for the bare words would flag them.
    private static func importsGameCenter(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//") else { return false }
            return code.contains(bannedImport)
        }
    }

    @Test("Neither the transport sources nor the tests reach for Game Center")
    func noGameCenterFrameworkAnywhere() throws {
        let sources = try Self.swiftFiles(in: Self.matchSourceDirectory)
        let tests = try Self.swiftFiles(in: Self.casesDirectory)

        // A scan that finds nothing because it looked nowhere proves nothing.
        #expect(sources.count >= 2, "expected the transport sources at \(Self.matchSourceDirectory.path)")
        #expect(tests.count >= 2, "expected the test sources at \(Self.casesDirectory.path)")

        for file in sources + tests {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !Self.importsGameCenter(text),
                "\(file.lastPathComponent) pulls in the Game Center framework"
            )
        }
    }
}
