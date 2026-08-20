import Foundation
import Testing

/// Source-text guardrails the difficulty screen has to keep and no unit test of
/// behaviour can catch: every visual value on it resolves through
/// `DesignTokens`, and no player-facing string anywhere in the lane reaches for
/// Bananagrams' vocabulary.
@Suite("Bot difficulty source guardrails")
struct BotDifficultySourceTests {

    private static var casesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    /// `BotSrc`, the committed symlink to `Willagrams/Bot`.
    private static var botSourceDirectory: URL {
        casesDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("BotSrc")
            .resolvingSymlinksInPath()
    }

    private static func swiftFiles(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Non-comment lines only — every file in this lane names these rules in its
    /// header comment, so a naive search matches its own warning.
    private static func codeLines(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
    }

    /// The contents of every double-quoted literal on a code line. Only strings
    /// are checked for banned vocabulary: `split` is also a stdlib method, and a
    /// method name never reaches the screen.
    private static func stringLiterals(of file: URL) throws -> [String] {
        let pattern = try NSRegularExpression(pattern: "\"([^\"\\n]*)\"")
        return try codeLines(of: file).flatMap { line -> [String] in
            let range = NSRange(line.startIndex..., in: line)
            return pattern.matches(in: line, range: range).compactMap {
                Range($0.range(at: 1), in: line).map { String(line[$0]) }
            }
        }
    }

    private static var difficultyView: URL {
        botSourceDirectory.appendingPathComponent("BotDifficultyView.swift")
    }

    /// The frozen IP fence. `Willagrams/Style/Terminology.swift` holds the
    /// approved words; these are the ones that must never reach a screen.
    private static let bannedVocabulary = ["bunch", "split", "peel", "dump", "banana", "rotten"]

    @Test("No player-facing string in the bot lane uses Bananagrams vocabulary")
    func noBannedVocabulary() throws {
        for file in try Self.swiftFiles(in: Self.botSourceDirectory) {
            for literal in try Self.stringLiterals(of: file) {
                let lowered = literal.lowercased()
                let offenders = Self.bannedVocabulary.filter { lowered.contains($0) }
                #expect(offenders.isEmpty, "\(file.lastPathComponent) says \(offenders) in \"\(literal)\"")
            }
        }
    }

    /// Every spacing, size and duration on the screen comes from a token, so a
    /// bare number on a code line is a hardcoded visual value.
    @Test("The difficulty screen hardcodes no number")
    func noNumericLiteral() throws {
        let digits = CharacterSet.decimalDigits
        let offenders = try Self.codeLines(of: Self.difficultyView)
            .filter { $0.rangeOfCharacter(from: digits) != nil }
        #expect(offenders.isEmpty, "BotDifficultyView.swift hardcodes numbers: \(offenders)")
    }

    /// And no colour or font is built in place — both resolve through
    /// `DesignTokens.Palette` and `DesignTokens.Typography`.
    @Test("The difficulty screen builds no colour or font of its own")
    func noRawColourOrFont() throws {
        let banned = ["Color(", "Font.", ".system(", "UIColor", "Animation."]
        let offenders = try Self.codeLines(of: Self.difficultyView)
            .filter { line in banned.contains { line.contains($0) } }
        #expect(offenders.isEmpty, "BotDifficultyView.swift builds its own visuals: \(offenders)")
    }

    /// Every visual value it does use is named on `DesignTokens`.
    @Test("Every visual modifier on the difficulty screen reads a DesignTokens key")
    func visualsComeFromTokens() throws {
        let visualModifiers = ["spacing:", ".font(", ".foregroundStyle(", ".padding(", "colors:"]
        let offenders = try Self.codeLines(of: Self.difficultyView)
            .filter { line in visualModifiers.contains { line.contains($0) } }
            .filter { !$0.contains("DesignTokens") }
        #expect(offenders.isEmpty, "BotDifficultyView.swift sets visuals off-token: \(offenders)")
    }
}
