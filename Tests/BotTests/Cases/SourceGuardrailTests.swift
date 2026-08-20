import Foundation
import Testing

/// Source-text guardrails over `Willagrams/Bot`. These are the lane rules that
/// no unit test of behaviour can catch: the bot's transport must be reachable
/// from a Release build, which means no `#if DEBUG` fence and no reference to
/// the debug-only `FakeTransport`.
@Suite("Bot source guardrails")
struct SourceGuardrailTests {

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
    }

    /// Non-comment lines only — every file in this lane carries these rules in
    /// its header comment, so a naive substring search matches its own warning.
    private static func codeLines(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
    }

    @Test("No bot source is fenced behind #if DEBUG")
    func noDebugFence() throws {
        for file in try Self.swiftFiles(in: Self.botSourceDirectory) {
            let offenders = try Self.codeLines(of: file).filter { $0.hasPrefix("#if") && $0.contains("DEBUG") }
            #expect(offenders.isEmpty, "\(file.lastPathComponent) fences code behind DEBUG: \(offenders)")
        }
    }

    @Test("No bot source references FakeTransport")
    func noFakeTransportReference() throws {
        for file in try Self.swiftFiles(in: Self.botSourceDirectory) {
            let offenders = try Self.codeLines(of: file).filter { $0.contains("FakeTransport") }
            #expect(offenders.isEmpty, "\(file.lastPathComponent) references FakeTransport: \(offenders)")
        }
    }

    @Test("No bot source imports GameKit")
    func noGameKit() throws {
        for file in try Self.swiftFiles(in: Self.botSourceDirectory) {
            let imports = try Self.codeLines(of: file).filter { $0.hasPrefix("import ") }
            #expect(!imports.contains { $0.contains("GameKit") }, "\(file.lastPathComponent) imports GameKit")
        }
    }

    /// This target builds for macOS, where SwiftUI is not available, so every
    /// view file must be named in the manifest's `exclude:`. Adding a view means
    /// adding one line there — this test is what says so.
    @Test("Every bot file that imports SwiftUI is excluded from the macOS target")
    func swiftUIFilesAreExcluded() throws {
        let manifest = try String(
            contentsOf: Self.casesDirectory.deletingLastPathComponent().appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        for file in try Self.swiftFiles(in: Self.botSourceDirectory) {
            let importsSwiftUI = try Self.codeLines(of: file)
                .contains { $0.hasPrefix("import ") && $0.contains("SwiftUI") }
            guard importsSwiftUI else { continue }
            #expect(
                manifest.contains("\"\(file.lastPathComponent)\""),
                "\(file.lastPathComponent) imports SwiftUI but is not in the Bot target's exclude: list"
            )
        }
    }
}
