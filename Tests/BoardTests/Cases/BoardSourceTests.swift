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

    // MARK: - The pure files must stay pure, or the execution tests evaporate

    func testPureFilesImportNoUIFramework() throws {
        // Every file symlinked into this package. A SwiftUI import in any of
        // them stops the whole package compiling, so this is the early, legible
        // failure rather than a wall of build errors.
        for name in ["BoardCamera.swift", "BoardRender.swift", "BoardGesture.swift"] {
            let text = BoardSource.strippingComments(try BoardSource.text(name))
            let uiImports = BoardSource.matches(#"import\s+(SwiftUI|UIKit|AppKit)"#, in: text)
            XCTAssertTrue(uiImports.isEmpty, "\(name) imports \(uiImports) and is no longer host-compilable")
        }
    }

    // MARK: - Gestures: the view wires, the pure layer decides

    func testViewDecidesTheGrabOnceAtGestureStart() throws {
        let text = try view()

        // The touch-down point, not the live one: `value.location` would
        // re-hit-test wherever the finger has got to.
        XCTAssertTrue(text.contains("value.startLocation"), "BoardView does not hit test the touch-down point")
        XCTAssertFalse(
            text.contains("BoardGesture.Drag(at: value.location"),
            "BoardView hit tests the current point, so the decision can change mid-gesture"
        )

        // And only when nothing is in flight. A stored drag is carried over
        // rather than rebuilt — but only after proving it belongs to THIS
        // gesture. SwiftUI skips `onEnded` on a cancelled gesture, so an
        // unconditional `drag ?? ...` would carry a dead gesture's grab and
        // start pan into the next touch; matching the touch-down point is what
        // scopes "decide once" to one gesture instead of to whatever was left
        // behind.
        XCTAssertTrue(
            text.contains("$0.startLocation == value.startLocation"),
            "BoardView reuses a stored drag without checking it belongs to this gesture"
        )
        XCTAssertTrue(
            text.contains("carried ?? BoardGesture.Drag("),
            "BoardView rebuilds the drag on every change rather than carrying the one decision"
        )
        XCTAssertTrue(text.contains("drag = nil"), "BoardView never releases the drag")
    }

    func testViewMakesNoGeometryDecisionOfItsOwn() throws {
        let text = try view()
        for reimplementation in ["floor(", "ceil(", "Int(", "minCellSize", "maxCellSize", "min(max("] {
            XCTAssertFalse(text.contains(reimplementation), "BoardView re-derives geometry via \(reimplementation)")
        }
    }

    func testTheZoomClampLivesOnlyInBoardCamera() throws {
        for file in try BoardSource.all() where file.name != "BoardCamera.swift" {
            let text = BoardSource.strippingComments(file.text)
            for clamp in ["minCellSize", "maxCellSize", "min(max("] {
                XCTAssertFalse(text.contains(clamp), "\(file.name) holds part of the zoom clamp: \(clamp)")
            }
        }
        let camera = BoardSource.strippingComments(try BoardSource.text("BoardCamera.swift"))
        XCTAssertTrue(camera.contains("min(max("), "the clamp has left BoardCamera entirely")
    }

    func testViewNeverClampsThePan() throws {
        // The board is unbounded; a bound on pan in any direction is the
        // guardrail this item must not break.
        let text = try view()
        for clamp in ["pan.width = min", "pan.width = max", "pan.height = min", "pan.height = max",
                      "clamped(", ".clamp("] {
            XCTAssertFalse(text.contains(clamp), "BoardView clamps the pan via \(clamp)")
        }
    }

    func testViewAnimatesRecenterThroughTheMotionToken() throws {
        let text = try view()
        XCTAssertTrue(
            text.contains("withAnimation(DesignTokens.Motion.snap)"),
            "BoardView does not animate recenter over Motion.snapDuration"
        )
        XCTAssertTrue(
            text.contains("BoardGesture.recentered("),
            "BoardView does not route recenter through the pure layer"
        )
    }

    func testSurfaceInterpolatesTheWholeCameraAsOnePiece() throws {
        // Canvas contents do not interpolate under an implicit animation while
        // an offset BrandTile does. Without Animatable over the camera, a
        // recenter slides the tiles and snaps the grid under them.
        let text = try view()
        XCTAssertTrue(text.contains("Animatable"), "the surface does not conform to Animatable")
        XCTAssertTrue(text.contains("animatableData"), "the surface exposes no animatableData")
        for component in ["camera.pan.width", "camera.pan.height", "camera.zoom"] {
            XCTAssertTrue(text.contains(component), "animatableData does not carry \(component)")
        }
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

    func testGestureWiringChecksHaveTeeth() {
        // The gesture guards above are fixed-string `contains`, so their teeth
        // are that they separate a body that gets the wiring wrong from one
        // that gets it right.
        let wrong = "let inFlight = BoardGesture.Drag(at: value.location, in: board, camera: camera)"
        XCTAssertTrue(wrong.contains("BoardGesture.Drag(at: value.location"))
        XCTAssertFalse(wrong.contains("drag ?? BoardGesture.Drag("))
        XCTAssertFalse(wrong.contains("value.startLocation"))

        let right = "let inFlight = drag ?? BoardGesture.Drag(\n at: value.startLocation, in: board, camera: camera\n)"
        XCTAssertFalse(right.contains("BoardGesture.Drag(at: value.location"))
        XCTAssertTrue(right.contains("drag ?? BoardGesture.Drag("))
        XCTAssertTrue(right.contains("value.startLocation"))

        XCTAssertTrue("let s = min(max(x, 24), 72)".contains("min(max("))
        XCTAssertFalse("let s = camera.cellSize".contains("min(max("))

        XCTAssertTrue("var animatableData: CGFloat".contains("animatableData"))
        XCTAssertFalse("var body: some View".contains("animatableData"))

        XCTAssertTrue("withAnimation(.easeOut(duration: 0.16))".contains("duration:"))
        XCTAssertFalse("withAnimation(DesignTokens.Motion.snap)".contains("duration:"))

        // And the stripper must not let a doc comment hide a real clamp, or
        // manufacture one out of prose.
        XCTAssertTrue(BoardSource.strippingComments("/// clamps hard\nlet s = min(max(a, b), c)").contains("min(max("))
        XCTAssertFalse(BoardSource.strippingComments("/// min(max(a, b), c)\nlet s = 1").contains("min(max("))
    }
}
