import XCTest
import Foundation

/// `BoardView` imports SwiftUI and touches the asset catalog, so it cannot be
/// compiled — let alone rendered — by this headless package. What is left to
/// check about it is structural, and these read it as text.
///
/// Paths are explicit and anchored off `#filePath`: this repo has sibling
/// worktrees under `/Users/nateseluga/willagrams-wt/` and `.claude/worktrees/`,
/// and any test that walks the repo root reads those full checkouts too.
private enum BoardSource {

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Cases
        .deletingLastPathComponent()   // BoardTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    static let boardDir = root.appendingPathComponent("Willagrams/Board")

    static func text(_ name: String) throws -> String {
        try String(contentsOf: boardDir.appendingPathComponent(name), encoding: .utf8)
    }

    /// Every `.swift` in `Willagrams/Board` — one known directory, never a walk
    /// from the repo root.
    static func all() throws -> [(name: String, text: String)] {
        try FileManager.default.contentsOfDirectory(atPath: boardDir.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { (name: $0, text: try text($0)) }
    }

    /// Strips `//` and `/* */` comments so a value or a word documented in prose
    /// is not read as code.
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

    /// All matches of `pattern`, returning capture group `group`.
    static func matches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            let r = $0.range(at: group)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }
}

final class BoardSourceTests: XCTestCase {

    private func view() throws -> String {
        BoardSource.strippingComments(try BoardSource.text("BoardView.swift"))
    }

    // MARK: - Guardrail: the draw is never driven by iterating placements

    func testNeitherFileIteratesPlacements() throws {
        for name in ["BoardView.swift", "BoardRender.swift"] {
            let text = BoardSource.strippingComments(try BoardSource.text(name))
            XCTAssertFalse(text.contains(".placements"), "\(name) reaches into Board.placements")
            XCTAssertFalse(text.contains("placementList"), "\(name) iterates placementList")
        }
    }

    // MARK: - Guardrail: no literal color, radius or spacing value in the view

    func testViewHardcodesNoLiteralValue() throws {
        let text = try view()

        let radii = BoardSource.matches(#"cornerRadius:\s*([0-9.]+)"#, in: text)
        XCTAssertTrue(radii.isEmpty, "BoardView hardcodes cornerRadius \(radii)")

        let padding = BoardSource.matches(#"padding\(\s*([0-9.]+)"#, in: text)
        XCTAssertTrue(padding.isEmpty, "BoardView hardcodes padding \(padding)")

        let spacing = BoardSource.matches(#"spacing:\s*([0-9.]+)"#, in: text)
        XCTAssertTrue(spacing.isEmpty, "BoardView hardcodes spacing \(spacing)")

        let durations = BoardSource.matches(#"duration:\s*([0-9.]+)"#, in: text)
        XCTAssertTrue(durations.isEmpty, "BoardView hardcodes duration \(durations)")

        let widths = BoardSource.matches(#"lineWidth:\s*([0-9.]+)"#, in: text)
        XCTAssertTrue(widths.isEmpty, "BoardView hardcodes lineWidth \(widths)")

        let hex = BoardSource.matches(#"(#[0-9A-Fa-f]{6}|0x[0-9A-Fa-f]{6})"#, in: text)
        XCTAssertTrue(hex.isEmpty, "BoardView hardcodes a hex color \(hex)")

        let channels = BoardSource.matches(#"Color\(\s*(red|white|hue):"#, in: text)
        XCTAssertTrue(channels.isEmpty, "BoardView builds a Color from channels \(channels)")
    }

    func testViewNamesNoSystemColor() throws {
        let text = try view()
        // `.clear` is the absence of a color, not a choice of one, so it is not
        // in this list.
        for color in ["Color.black", "Color.white", "Color.gray", "Color.red", "Color.blue",
                      "Color.green", "Color.primary", "Color.secondary",
                      ".foregroundStyle(.black", ".foregroundStyle(.white", ".fill(.black", ".fill(.white"] {
            XCTAssertFalse(text.contains(color), "BoardView uses \(color)")
        }
    }

    // MARK: - The tokens the task names, and no re-implemented tile art

    func testViewReadsTheSurfaceTokens() throws {
        let text = try view()
        for token in ["Palette.boardSurface", "Palette.cellEmpty", "Radius.cell"] {
            XCTAssertTrue(text.contains(token), "BoardView does not use DesignTokens.\(token)")
        }
    }

    func testViewRendersTileArtThroughBrandTileOnly() throws {
        let text = try view()
        XCTAssertTrue(text.contains("BrandTile("), "BoardView does not render tiles through BrandTile")

        // BrandTile owns the face, bevel, ring and lift. Any of these here is a
        // second implementation of the tile.
        for reimplementation in ["Shadow.tile", "brandShadow", ".shadow(", "Stroke.bevel",
                                 "Stroke.selectedRing", "Radius.tile", "Palette.tileFace",
                                 "Palette.tileEdge", "Palette.tileLetter", "Typography.tileLetter"] {
            XCTAssertFalse(text.contains(reimplementation), "BoardView re-implements tile art via \(reimplementation)")
        }
    }

    // MARK: - Light and dark come from the catalog, not from a Swift branch

    func testNoBoardSourceBranchesOnColorScheme() throws {
        // This is the honest headless check for the light/dark criterion: both
        // themes resolve out of the asset catalog, and a Swift branch on
        // colorScheme would mean a value that exists in only one of them.
        for file in try BoardSource.all() {
            let text = BoardSource.strippingComments(file.text)
            XCTAssertFalse(text.contains("colorScheme =="), "\(file.name) branches on colorScheme")
            XCTAssertFalse(text.contains("@Environment(\\.colorScheme)"), "\(file.name) reads colorScheme")
        }
    }

    // MARK: - The pure file must stay pure, or the execution tests evaporate

    func testRenderImportsNoUIFramework() throws {
        let text = BoardSource.strippingComments(try BoardSource.text("BoardRender.swift"))
        let uiImports = BoardSource.matches(#"import\s+(SwiftUI|UIKit|AppKit)"#, in: text)
        XCTAssertTrue(uiImports.isEmpty, "BoardRender imports \(uiImports) and is no longer host-compilable")
    }

    // MARK: - Lane vocabulary guardrails

    func testNoBoardSourceUsesBannedVocabulary() throws {
        // Comments are deliberately NOT stripped: the guardrail covers prose.
        for file in try BoardSource.all() {
            for word in ["bunch", "split", "peel", "dump", "banana", "rotten"] {
                let hits = BoardSource.matches("(?i)\\b(\(word))", in: file.text)
                XCTAssertTrue(hits.isEmpty, "\(file.name) uses banned vocabulary: \(hits)")
            }
        }
    }

    func testNoBoardSourceReachesForTheNetworkingLayer() throws {
        for file in try BoardSource.all() {
            for word in ["GameKit", "match", "peer", "message"] {
                let hits = BoardSource.matches("(?i)\\b(\(word))", in: file.text)
                XCTAssertTrue(hits.isEmpty, "\(file.name) references \(hits)")
            }
        }
    }

    // MARK: - The checks above have teeth

    func testLiteralChecksHaveTeeth() {
        XCTAssertEqual(BoardSource.matches(#"cornerRadius:\s*([0-9.]+)"#, in: "cornerRadius: 12"), ["12"])
        XCTAssertTrue(BoardSource.matches(#"cornerRadius:\s*([0-9.]+)"#, in: "cornerRadius: DesignTokens.Radius.cell").isEmpty)

        XCTAssertEqual(BoardSource.matches(#"lineWidth:\s*([0-9.]+)"#, in: "lineWidth: 0.5"), ["0.5"])
        XCTAssertTrue(BoardSource.matches(#"lineWidth:\s*([0-9.]+)"#, in: "lineWidth: DesignTokens.Stroke.hairline").isEmpty)

        XCTAssertEqual(BoardSource.matches(#"padding\(\s*([0-9.]+)"#, in: "padding(8)"), ["8"])
        XCTAssertTrue(BoardSource.matches(#"padding\(\s*([0-9.]+)"#, in: "padding(DesignTokens.Space.m)").isEmpty)

        XCTAssertEqual(BoardSource.matches(#"(#[0-9A-Fa-f]{6}|0x[0-9A-Fa-f]{6})"#, in: "\"#FF8800\""), ["#FF8800"])
        XCTAssertTrue(BoardSource.matches(#"(#[0-9A-Fa-f]{6}|0x[0-9A-Fa-f]{6})"#, in: "#Preview(\"Light\")").isEmpty)

        XCTAssertEqual(BoardSource.matches(#"import\s+(SwiftUI|UIKit|AppKit)"#, in: "import SwiftUI"), ["SwiftUI"])
        XCTAssertTrue(BoardSource.matches(#"import\s+(SwiftUI|UIKit|AppKit)"#, in: "import CoreGraphics").isEmpty)

        XCTAssertEqual(BoardSource.matches("(?i)\\b(peel)", in: "let peeled = 1"), ["peel"])
        XCTAssertTrue(BoardSource.matches("(?i)\\b(peel)", in: "let repealed = 1").isEmpty)

        // The comment stripper is what keeps a documented value out of the
        // literal checks — and what stops it hiding a real one.
        XCTAssertFalse(BoardSource.strippingComments("// cornerRadius: 12\nlet a = 1").contains("cornerRadius"))
        XCTAssertTrue(BoardSource.strippingComments("let r = 12 // fine").contains("let r = 12"))
    }
}
