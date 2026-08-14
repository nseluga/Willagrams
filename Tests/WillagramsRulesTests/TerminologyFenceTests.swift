import Foundation
import Testing

/// The IP fence, enforced as a test rather than a review habit.
///
/// Scans every Swift file under `Willagrams/` for Bananagrams' vocabulary in
/// **string literals** — the only place a word can reach a player. Comments
/// are stripped first, so the fence can be documented in prose, and code
/// identifiers are ignored so `text.split(separator:)` is not a violation.
@Suite("Terminology fence")
struct TerminologyFenceTests {

    static let banned = ["bunch", "peel", "dump", "banana", "rotten", "split"]

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WillagramsRulesTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    @Test("No Bananagrams term appears in any player-facing string")
    func noBannedTermsInLiterals() throws {
        let appRoot = Self.repoRoot.appendingPathComponent("Willagrams")
        let swiftFiles = try Self.swiftFiles(under: appRoot)

        #expect(!swiftFiles.isEmpty, "found no Swift files under \(appRoot.path)")

        var violations: [String] = []
        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in Self.stringLiterals(in: Self.strippingComments(source)) {
                let lowered = literal.lowercased()
                for term in Self.banned where lowered.contains(term) {
                    violations.append("\(file.lastPathComponent): \"\(literal)\" contains \"\(term)\"")
                }
            }
        }

        #expect(violations.isEmpty, "banned terminology reached a string literal:\n\(violations.joined(separator: "\n"))")
    }

    @Test("The fence detects a planted violation")
    func fenceCatchesAPlant() {
        let source = #"let label = "Peel to draw" // harmless comment"#
        let literals = Self.stringLiterals(in: Self.strippingComments(source))

        #expect(literals == ["Peel to draw"])
        #expect(Self.banned.contains { literals[0].lowercased().contains($0) })
    }

    @Test("A banned term inside a comment is not a violation")
    func commentsAreExempt() {
        let source = """
        // Bananagrams calls this a peel; we do not.
        let label = "Draw"
        """

        #expect(Self.stringLiterals(in: Self.strippingComments(source)) == ["Draw"])
    }

    // MARK: - Helpers

    static func swiftFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    static func strippingComments(_ source: String) -> String {
        var out = ""
        let chars = Array(source)
        var i = 0
        var inString = false

        while i < chars.count {
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : "\0"

            if inString {
                if c == "\\" { out.append(c); if i + 1 < chars.count { out.append(chars[i + 1]) }; i += 2; continue }
                if c == "\"" { inString = false }
                out.append(c); i += 1; continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/" && next == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && next == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            out.append(c); i += 1
        }
        return out
    }

    static func stringLiterals(in source: String) -> [String] {
        var literals: [String] = []
        var current = ""
        var inString = false
        let chars = Array(source)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { literals.append(current); current = ""; inString = false; i += 1; continue }
                current.append(c); i += 1; continue
            }
            if c == "\"" { inString = true; i += 1; continue }
            i += 1
        }
        return literals
    }
}
