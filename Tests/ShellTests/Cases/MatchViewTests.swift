import Foundation
import Testing

/// `MatchView` is SwiftUI and cannot be constructed on macOS, so what it
/// composes is checked against the bytes on disk. These are the four properties
/// that make it safe: real bindings, no mutation during body evaluation, no
/// geometry of its own, and no routing.
@Suite("Match view composition")
struct MatchViewTests {

    private static var source: String {
        get throws {
            try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("ShellSrc/MatchView.swift")
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

    @Test("Board and model go down as bindings, not copies")
    func passesBindings() throws {
        let code = try Self.code
        #expect(code.contains { $0.contains("board: $matchBoard.board") })
        #expect(code.contains { $0.contains("model: $matchBoard.model") })
    }

    @Test("It composes both halves of the screen")
    func composesBoardAndHUD() throws {
        let code = try Self.code
        #expect(code.contains { $0.contains("BoardView(") })
        #expect(code.contains { $0.contains("MatchHUD(hud: hud)") })
    }

    @Test("The viewport is measured, and written outside body evaluation")
    func viewportWrittenFromOnChange() throws {
        let code = try Self.code
        // Measured, not a literal: the size comes off the geometry proxy.
        #expect(code.contains { $0.contains("CGRect(origin: .zero, size: proxy.size)") })
        // Every write to `viewport` sits inside an `.onChange` closure. The
        // marker is the line, so a write moved back up into the body fails.
        let writes = code.filter { $0.contains("matchBoard.viewport =") }
        #expect(!writes.isEmpty)
        guard let onChange = code.firstIndex(where: { $0.hasPrefix(".onChange(") }) else {
            Issue.record("No .onChange — the viewport write has nowhere safe to live")
            return
        }
        for write in writes {
            let index = code.firstIndex(of: write)
            #expect(index.map { $0 > onChange } == true)
        }
    }

    @Test("It computes no coordinate and takes no routing decision")
    func noGeometryAndNoRouting() throws {
        let source = try Self.source
        for banned in ["BoardLayout", "BoardGesture", "BoardCamera(", "shell.", "ShellModel", "route"] {
            #expect(!Self.usesIdentifier(banned, in: source), "MatchView must not reference \(banned)")
        }
    }

    /// Identifier use, not a mention in prose: the header comments name several
    /// of these while explaining why the file does not use them.
    private static func usesIdentifier(_ identifier: String, in text: String) -> Bool {
        text.components(separatedBy: "\n").contains { line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//") else { return false }
            return code.contains(identifier)
        }
    }
}
