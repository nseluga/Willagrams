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

    private func model() throws -> String {
        BoardSource.strippingComments(try BoardSource.text("BoardModel.swift"))
    }

    /// The text between two markers, so a check aimed at one gesture path
    /// cannot be satisfied by another one further down the file.
    private func section(of text: String, from: String, to: String) throws -> String {
        let tail = try XCTUnwrap(
            text.range(of: from).map { String(text[$0.lowerBound...]) },
            "no \(from) in this file"
        )
        return try XCTUnwrap(
            tail.range(of: to).map { String(tail[..<$0.lowerBound]) },
            "no \(to) after \(from)"
        )
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
        for name in ["BoardCamera.swift", "BoardRender.swift", "BoardGesture.swift",
                     "BoardDrag.swift", "BoardModel.swift"] {
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
        // start pan into the next touch; comparing the touch-down point is what
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

    func testViewComposesTheGesturesExclusivelyRatherThanSimultaneously() throws {
        // Two fingers drift far enough to feed a drag recognizer — and the drag
        // now has no minimum distance of its own to filter them out — so under
        // `.simultaneousGesture` a pinch feeds BOTH recognizers and
        // each writes the whole camera from its own start snapshot — pan and
        // zoom alternate instead of composing. Whether SwiftUI's recognizers
        // actually fire that way is not observable headlessly; the wiring that
        // decides it is, so the wiring is what gets pinned.
        let text = try view()
        XCTAssertTrue(
            text.contains("magnifyGesture.exclusively(before: dragGesture)"),
            "BoardView does not give the pinch first refusal over the drag"
        )
        XCTAssertFalse(
            text.contains(".simultaneousGesture"),
            "BoardView still feeds both recognizers, so pan and zoom fight over the camera"
        )
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

    // MARK: - Tile dragging: the view wires, the pure layer decides

    func testViewPassesTheRealSnapThresholdTokenToTheDrag() throws {
        // The threshold is a `drop` PARAMETER so the pure layer never has to
        // name a number DesignTokens owns. That only keeps the token as the one
        // source of truth if the view actually passes it.
        let text = try view()
        XCTAssertTrue(
            text.contains("threshold: DesignTokens.Motion.snapThreshold"),
            "BoardView does not pass DesignTokens.Motion.snapThreshold to the drop"
        )
        XCTAssertTrue(text.contains("model.commit("), "BoardView never commits a drag")
        XCTAssertTrue(text.contains("board = "), "BoardView never lands a committed drag")

        // The commit itself moved into the pure session with the rest of the
        // drag state. Same two things pinned, where they now live: it lands
        // through `TileDrag.drop`, and it forwards the threshold it was handed
        // rather than naming a distance of its own.
        let model = try self.model()
        XCTAssertTrue(model.contains(".drop("), "BoardModel commits through something other than TileDrag")
        XCTAssertTrue(
            model.contains("threshold: threshold"),
            "BoardModel does not forward the injected threshold to the drop"
        )
    }

    func testNoPureFileNamesTheThresholdOrTheLiftItself() throws {
        // Either token appearing outside the view means a second copy of a
        // DesignTokens value, which is the lane's one hard rule.
        for name in ["BoardDrag.swift", "BoardRender.swift", "BoardGesture.swift",
                     "BoardCamera.swift", "BoardModel.swift"] {
            let text = BoardSource.strippingComments(try BoardSource.text(name))
            XCTAssertFalse(text.contains("snapThreshold"), "\(name) names the threshold token")
            XCTAssertFalse(text.contains("tileLift"), "\(name) names the lift token")
            XCTAssertFalse(text.contains("DesignTokens"), "\(name) reaches for DesignTokens")
        }
        let drag = BoardSource.strippingComments(try BoardSource.text("BoardDrag.swift"))
        XCTAssertTrue(drag.contains("threshold: CGFloat"), "the threshold is not injected into BoardDrag")
    }

    func testViewMapsTheSelectedRenderStateOntoBrandTileAndOwnsNoLiftOfItsOwn() throws {
        let text = try view()
        XCTAssertTrue(
            text.contains("case .selected: .selected"),
            "BoardView does not map the pure .selected state onto BrandTile.State.selected"
        )
        // BrandTile applies Motion.tileLift for .selected itself. Naming it here
        // would be a second lift on top of the one the tile already has.
        XCTAssertFalse(text.contains("tileLift"), "BoardView applies its own lift")
        XCTAssertFalse(text.contains(".offset(y:"), "BoardView lifts the tile itself")
    }

    func testTheTileDragIsBuiltOnceFromTheDecidedGrabAndAlwaysReleased() throws {
        let text = try view()
        // Construction is what fires the pickup feel, so it must sit behind the
        // same "freshly decided" branch the grab does — `onChanged` fires many
        // times per drag.
        XCTAssertTrue(
            text.contains("if carried == nil"),
            "BoardView rebuilds the tile drag every change, so pickup fires per frame"
        )
        XCTAssertTrue(
            text.contains("model.began(inFlight.grab"),
            "BoardView does not hand the already-decided grab to the session"
        )
        // The session state moved into the pure model, so the same two things
        // are pinned there: it builds the drag from the carried grab rather
        // than hit-testing again, and it lets go of it.
        let model = try self.model()
        XCTAssertTrue(model.contains("TileDrag(grab:"), "BoardModel runs a second hit test of its own")
        XCTAssertTrue(model.contains("tileDrag = nil"), "BoardModel never releases the tile drag")
        XCTAssertFalse(text.contains("tileDrag"), "BoardView still owns tile-drag state of its own")
    }

    func testViewLiftsTheDraggedTileAboveTheOnesItPassesOver() throws {
        // `cells` arrives in `visibleCoords` row-major order, so without a
        // stacking order a tile dragged down or right draws BEHIND every tile
        // at a greater row and the lift reads as sunk.
        let text = try view()
        XCTAssertTrue(
            text.contains("zIndex(cell.state == .selected"),
            "BoardView does not raise the dragged tile above the ones it crosses"
        )
    }

    func testViewRecognizesTheDragOnTouchDownRatherThanAfterTenPoints() throws {
        // The criterion is that TOUCHING a tile lifts it. At DragGesture's
        // default minimumDistance the selection, the lift and the pickup feel
        // all wait for 10pt of travel.
        let text = try view()
        XCTAssertTrue(
            text.contains("DragGesture(minimumDistance: 0)"),
            "BoardView still waits for DragGesture's default travel before the tile lifts"
        )
    }

    func testPinchClearsATileDragItStealsThroughTheOneCancelPathWithoutFiringAFeel() throws {
        // With no minimum distance the drag recognizes on touch-down, so a
        // second finger can take the gesture away before `onEnded` ever runs.
        // The pinch path has to drop that pickup, and must NOT call it a
        // rejected drop — criterion 4 counts exactly one reject per refusal.
        let text = try view()
        let magnify = try section(of: text, from: "private var magnifyGesture", to: "private func recenterControl")
        XCTAssertTrue(magnify.contains("model.cancel()"), "a pinch leaves a stolen tile drag lifted")
        XCTAssertFalse(magnify.contains("haptics"), "the pinch path fires a feel for a cancellation")
        XCTAssertFalse(magnify.contains(".drop("), "the pinch path commits a drop")
        XCTAssertFalse(magnify.contains("model.commit("), "the pinch path commits a drop")

        // The cancel it takes is the SAME one the lock takes, and it clears both
        // halves of the session. One path, two callers: a second one is a second
        // chance to clear half of it.
        let model = try self.model()
        XCTAssertTrue(model.contains("tileDrag = nil"), "the cancel path leaves the tile drag held")
        XCTAssertTrue(model.contains("dragTranslation = .zero"), "the cancel path leaves the tile offset")
        XCTAssertEqual(
            BoardSource.matches(#"(tileDrag = nil)"#, in: model).count, 1,
            "BoardModel holds more than one cancel path"
        )
        XCTAssertFalse(model.contains("haptics.fire"), "BoardModel fires a feel of its own")
    }

    // MARK: - The external input lock

    func testViewPassesTheInputLockIntoTheGrabDecisionAndNowhereElse() throws {
        let text = try view()
        // The lock reaches exactly one place: the grab decision, which is made
        // once at touch-down. That is what makes a locked touch a refusal at
        // gesture start rather than a revert after a tile has already lifted.
        XCTAssertTrue(
            text.contains("camera: camera, inputLocked: model.inputLocked"),
            "BoardView decides the grab without the lock, so a locked touch still lifts a tile"
        )
        XCTAssertTrue(
            text.contains(".onChange(of: inputLocked, initial: true)"),
            "BoardView does not sync the external lock into the session on the first pass"
        )
        // No second reading of it that undoes work already done.
        XCTAssertFalse(
            text.contains("if model.inputLocked"),
            "BoardView branches on the lock after the fact instead of refusing at gesture start"
        )
        XCTAssertFalse(
            text.contains("if inputLocked"),
            "BoardView branches on the lock after the fact instead of refusing at gesture start"
        )

        // And the gesture layer takes it where the grab is decided — in `init`,
        // read before the hit test, defaulted so existing call sites are unmoved.
        let gesture = BoardSource.strippingComments(try BoardSource.text("BoardGesture.swift"))
        XCTAssertTrue(
            gesture.contains("inputLocked: Bool = false"),
            "BoardGesture.Drag does not accept the lock, or its default is not unlocked"
        )
        XCTAssertTrue(
            gesture.contains("guard !inputLocked else"),
            "BoardGesture.Drag accepts the lock but never refuses on it"
        )
    }

    func testTheCameraPathsNameTheLockNowhere() throws {
        // Panning, zooming and recentering stay live while the tiles are inert,
        // and the way that is guaranteed is that neither path can see the flag.
        let text = try view()
        let magnify = try section(of: text, from: "private var magnifyGesture", to: "private func recenterControl")
        let recenter = try section(of: text, from: "private func recenterControl", to: "private static let recenterLabel")
        for (name, path) in [("the pinch path", magnify), ("the recenter path", recenter)] {
            XCTAssertFalse(path.contains("inputLocked"), "\(name) consults the lock")
            XCTAssertFalse(path.contains("Locked"), "\(name) consults the lock")
        }
        // Both still do their own job, so the checks above are not passing on an
        // empty path.
        XCTAssertTrue(magnify.contains("magnified(by:"), "the pinch path no longer zooms")
        XCTAssertTrue(recenter.contains("BoardGesture.recentered("), "the recenter path no longer recenters")

        // The session that owns the lock owns no camera at all, so there is
        // nothing there for a zoom or a recenter to be refused by.
        let model = try self.model()
        XCTAssertFalse(model.contains("var camera"), "BoardModel stores a camera the lock could reach")
        XCTAssertFalse(model.contains("magnified("), "BoardModel zooms")
        XCTAssertFalse(model.contains("recenter"), "BoardModel recenters")
        XCTAssertFalse(model.contains("panned("), "BoardModel pans")
    }

    func testTheBodyNeverSpendsTheLockOnTheSurfaceItself() throws {
        // Criterion 2's view half, and the one the pure checks cannot reach.
        // Refusing at the grab decision is the only sanctioned refusal: a lock
        // spent on the SURFACE instead — `.disabled`, a hit-test switch, a
        // gesture attached only while unlocked — takes panning, zooming and
        // recentering down with the tiles, and every check that reads
        // `BoardGesture` or `BoardModel` stays green while it does, because
        // neither of those files is where it happened.
        let text = try view()
        let body = try section(of: text, from: "public var body: some View", to: "private var dragGesture")

        for killer in [".disabled(", ".allowsHitTesting(", "EmptyView()"] {
            XCTAssertFalse(body.contains(killer), "BoardView's body spends the lock on \(killer), stopping the camera too")
        }

        // The same two, over the WHOLE file: the body slice ends at
        // `dragGesture`, so a `.disabled(` on the surface inside `BoardSurface`
        // — or on any modifier below the slice — would sail past the check
        // above while taking the camera down just the same.
        for killer in [".disabled(", ".allowsHitTesting("] {
            XCTAssertFalse(text.contains(killer), "BoardView spends the lock on \(killer) outside its body, stopping the camera too")
        }

        // The body names the lock exactly once, and that once is the sync into
        // the session. A second mention is a second decision.
        let named = body.split(separator: "\n").filter { $0.contains("Locked") }
        XCTAssertEqual(named.count, 1, "BoardView's body reads the lock outside the sync: \(named)")
        XCTAssertTrue(
            named.first?.contains(".onChange(of: inputLocked, initial: true)") == true,
            "the one place the body names the lock is not the sync"
        )

        // And the camera gestures are still attached unconditionally, so the
        // checks above are not passing on a body that stopped attaching them.
        XCTAssertTrue(
            body.contains(".gesture(magnifyGesture.exclusively(before: dragGesture))"),
            "BoardView no longer attaches the camera gestures"
        )
    }

    func testTheBodyLockCheckHasTeeth() {
        let gated = """
            BoardSurface(board: board, camera: camera, rect: rect)
                .disabled(inputLocked)
                .gesture(magnifyGesture.exclusively(before: dragGesture))
                .onChange(of: inputLocked, initial: true) { model.inputLocked = inputLocked }
            """
        XCTAssertTrue(gated.contains(".disabled("))
        XCTAssertEqual(gated.split(separator: "\n").filter { $0.contains("Locked") }.count, 2)

        let clean = """
            BoardSurface(board: board, camera: camera, rect: rect)
                .gesture(magnifyGesture.exclusively(before: dragGesture))
                .onChange(of: inputLocked, initial: true) { model.inputLocked = inputLocked }
            """
        XCTAssertFalse(clean.contains(".disabled("))
        XCTAssertEqual(clean.split(separator: "\n").filter { $0.contains("Locked") }.count, 1)
        XCTAssertTrue(clean.contains(".gesture(magnifyGesture.exclusively(before: dragGesture))"))

        // A body that hid the gesture behind the lock instead of disabling the
        // surface must read as gated too.
        let conditional = "if !inputLocked { surface.gesture(dragGesture) } else { surface }"
        XCTAssertEqual(conditional.split(separator: "\n").filter { $0.contains("Locked") }.count, 1)
        XCTAssertFalse(conditional.contains(".onChange(of: inputLocked, initial: true)"))

        // And the widened whole-file half: a `.disabled(` planted BELOW the
        // body slice — inside `BoardSurface`, say — is invisible to the slice
        // and must still be caught by the file-wide check.
        let plantedOutsideTheBody = """
            public var body: some View {
                BoardSurface(board: board, camera: camera, rect: rect)
                    .gesture(magnifyGesture.exclusively(before: dragGesture))
                    .onChange(of: inputLocked, initial: true) { model.inputLocked = inputLocked }
            }
            private var dragGesture: some Gesture { DragGesture() }
            private struct BoardSurface: View {
                var body: some View { ZStack { Canvas { _, _ in } }.disabled(locked) }
            }
            """
        let slice = plantedOutsideTheBody
            .range(of: "private var dragGesture")
            .map { String(plantedOutsideTheBody[..<$0.lowerBound]) }
        XCTAssertEqual(slice?.contains(".disabled("), false, "the plant must be outside the body slice")
        XCTAssertTrue(plantedOutsideTheBody.contains(".disabled("), "the file-wide check must catch the plant")
    }

    func testFeedbackHoldsPreparedGeneratorsAndNeverTrapsOffTheMainActor() throws {
        // UIKit, so unexecutable here. A generator built and fired in one
        // statement wakes the engine on the event and lands the buzz late.
        let text = BoardSource.strippingComments(try BoardSource.text("BoardFeedback.swift"))
        XCTAssertTrue(text.contains("prepare()"), "BoardFeedback never prepares a generator")
        // Each generator by name, not a bare "static let" anywhere in the file:
        // one of the three sliding back to a rebuilt-per-event `var` still
        // leaves the other two reading `static let`, and the buzz it wakes on
        // the event itself is exactly the late one this pins.
        for generator in ["pickupGenerator", "snapGenerator", "rejectGenerator"] {
            XCTAssertTrue(
                text.contains("static let \(generator)"),
                "BoardFeedback rebuilds \(generator) per event, so preparing it buys nothing"
            )
        }
        // Three feels that stay distinguishable by hand.
        for feel in ["style: .light", "style: .medium", "notificationOccurred(.error)"] {
            XCTAssertTrue(text.contains(feel), "BoardFeedback no longer fires \(feel)")
        }
        // A missed buzz must never be a crash.
        XCTAssertTrue(
            text.contains("Thread.isMainThread"),
            "BoardFeedback reaches assumeIsolated without establishing the main thread"
        )
    }

    func testViewNeverMutatesTheBoardItself() throws {
        // Every board change goes through TileDrag, which builds on a copy.
        // A place or a remove here would be a move that can land half done.
        // The preview fixture builds its board under another name for exactly
        // this reason — the live `board` is the one being pinned.
        let text = try view()
        for mutation in ["board.place(", "board.remove(", ".placements["] {
            XCTAssertFalse(text.contains(mutation), "BoardView mutates the board via \(mutation)")
        }
    }

    func testDragCommitsThroughPlaceAndRemoveOnly() throws {
        let text = BoardSource.strippingComments(try BoardSource.text("BoardDrag.swift"))
        XCTAssertTrue(text.contains(".remove(at:"), "the drag does not remove through Board.remove")
        XCTAssertTrue(text.contains(".place("), "the drag does not land through Board.place")
        XCTAssertFalse(text.contains("placements"), "the drag reaches into Board.placements")
    }

    // MARK: - Live validation: the view reads published state, and checks nothing

    func testNoFileOutsideTheSessionCallsTheCheckerAndTheSessionCallsItOnce() throws {
        // The whole file, every type in it — the view's body, its computed
        // properties, `BoardSurface`, the previews. A `validate` anywhere in a
        // draw path is the guardrail this item must not break, and a slice of
        // the body would not see one planted in the surface below it.
        for file in try BoardSource.all() where file.name != "BoardModel.swift" {
            let text = BoardSource.strippingComments(file.text)
            for reimplementation in [".validate(", "validate(against:", ".clusters", ".words()", "isComplete"] {
                XCTAssertFalse(
                    text.contains(reimplementation),
                    "\(file.name) checks the board itself via \(reimplementation)"
                )
            }
        }

        // And the session holds exactly one call to it, in one place. Two would
        // be two answers that can disagree.
        let model = try self.model()
        XCTAssertEqual(
            BoardSource.matches(#"(board\.validate\(against:)"#, in: model).count, 1,
            "BoardModel calls the checker somewhere other than its one revalidate"
        )
        XCTAssertEqual(
            BoardSource.matches(#"(private mutating func revalidate)"#, in: model).count, 1,
            "BoardModel holds more than one revalidate path"
        )
        XCTAssertTrue(
            model.contains("validation.isComplete"),
            "canDraw does not come from the frozen isComplete"
        )
        // Every part of the completeness rule restated here would be a second
        // copy of a rule BoardAnalysis owns.
        for rule in ["clusterCount == 1", "invalidWords.isEmpty", "tileCount >= 2"] {
            XCTAssertFalse(model.contains(rule), "BoardModel re-derives the Draw gate: \(rule)")
        }
    }

    func testTheViewTintsFromPublishedStateAndNamesTheDangerToken() throws {
        let text = try view()
        XCTAssertTrue(text.contains("Palette.danger"), "BoardView does not tint a refused run at all")
        XCTAssertTrue(
            text.contains("invalid: model.invalidCoords"),
            "BoardView does not hand the published invalid set to the draw list"
        )
        XCTAssertTrue(
            text.contains("cell.isInvalid"),
            "BoardView tints from something other than the draw list's own marker"
        )
        // The one call site that could reintroduce a per-frame check.
        XCTAssertTrue(
            text.contains("against: dictionary"),
            "BoardView does not hand the word list to the commit"
        )
        XCTAssertFalse(
            text.contains("EnableWordList()"),
            "BoardView loads a word list of its own rather than taking the one it was given"
        )
    }

    func testTheValidationChecksHaveTeeth() {
        // A view that checked the board in its own body, versus one that reads
        // the published set.
        let checking = "let bad = board.validate(against: dictionary).invalidWords"
        XCTAssertTrue(checking.contains(".validate("))
        XCTAssertFalse("BoardRender.cells(board: board, invalid: invalid)".contains(".validate("))

        // A view that re-derived the gate instead of reading isComplete.
        let derived = "var canDraw: Bool { board.clusters.count == 1 }"
        XCTAssertTrue(derived.contains(".clusters"))
        XCTAssertFalse(derived.contains("validation.isComplete"))
        XCTAssertTrue("var canDraw: Bool { validation.isComplete }".contains("validation.isComplete"))

        // A restated completeness rule.
        XCTAssertTrue("clusterCount == 1 && invalidWords.isEmpty".contains("clusterCount == 1"))
        XCTAssertFalse("validation.isComplete".contains("clusterCount == 1"))

        // Two calls to the checker versus one.
        let twice = """
            validation = board.validate(against: dictionary)
            let gate = board.validate(against: dictionary).isComplete
            """
        XCTAssertEqual(BoardSource.matches(#"(board\.validate\(against:)"#, in: twice).count, 2)
        XCTAssertEqual(
            BoardSource.matches(#"(board\.validate\(against:)"#, in: "validation = board.validate(against: d)").count, 1
        )

        // A tint hardcoded to a colour of its own versus the token.
        XCTAssertFalse("Color.red.blendMode(.multiply)".contains("Palette.danger"))
        XCTAssertTrue("DesignTokens.Palette.danger".contains("Palette.danger"))

        // And a view that tinted from a set it built itself rather than the
        // marker the pure draw list carries.
        XCTAssertFalse("if badWords.contains(cell.coord)".contains("cell.isInvalid"))
        XCTAssertTrue("cell.isInvalid ? DesignTokens.Palette.danger : Color.clear".contains("cell.isInvalid"))
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
        XCTAssertFalse(wrong.contains("carried ?? BoardGesture.Drag("))
        XCTAssertFalse(wrong.contains("value.startLocation"))

        let right = """
            let carried = drag.flatMap { $0.startLocation == value.startLocation ? $0 : nil }
            let inFlight = carried ?? BoardGesture.Drag(at: value.startLocation, in: board, camera: camera)
            """
        XCTAssertFalse(right.contains("BoardGesture.Drag(at: value.location"))
        XCTAssertTrue(right.contains("carried ?? BoardGesture.Drag("))
        XCTAssertTrue(right.contains("$0.startLocation == value.startLocation"))

        // The staleness check must separate carrying a stored drag over
        // unconditionally from carrying it over only within one gesture.
        let stale = "let inFlight = drag ?? BoardGesture.Drag(at: value.startLocation, in: board, camera: camera)"
        XCTAssertTrue(stale.contains("value.startLocation"))
        XCTAssertFalse(stale.contains("$0.startLocation == value.startLocation"))

        // And the composition check must separate the two wirings.
        let fighting = ".gesture(dragGesture)\n.simultaneousGesture(magnifyGesture)"
        XCTAssertTrue(fighting.contains(".simultaneousGesture"))
        XCTAssertFalse(fighting.contains("magnifyGesture.exclusively(before: dragGesture)"))

        let composed = ".gesture(magnifyGesture.exclusively(before: dragGesture))"
        XCTAssertFalse(composed.contains(".simultaneousGesture"))
        XCTAssertTrue(composed.contains("magnifyGesture.exclusively(before: dragGesture)"))

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

    func testDragWiringChecksHaveTeeth() {
        // Each of these separates a body that hardcodes the token's value from
        // one that passes the token.
        let copied = "board = tileDrag.drop(translation: t, on: board, camera: camera, threshold: 22)"
        XCTAssertFalse(copied.contains("threshold: DesignTokens.Motion.snapThreshold"))
        let passed = "threshold: DesignTokens.Motion.snapThreshold"
        XCTAssertTrue(passed.contains("threshold: DesignTokens.Motion.snapThreshold"))

        // And a pure file that reached for the token at all.
        XCTAssertTrue("let t = DesignTokens.Motion.snapThreshold".contains("snapThreshold"))
        XCTAssertFalse("public func drop(threshold: CGFloat)".contains("snapThreshold"))
        XCTAssertTrue("public func drop(threshold: CGFloat)".contains("threshold: CGFloat"))

        // A view that lifts the tile itself rather than letting BrandTile do it.
        let doubleLift = ".offset(y: DesignTokens.Motion.tileLift)"
        XCTAssertTrue(doubleLift.contains("tileLift"))
        XCTAssertTrue(doubleLift.contains(".offset(y:"))
        XCTAssertFalse("BrandTile(letter: l, size: s, state: .selected)".contains("tileLift"))

        // A view that rebuilds the drag — and therefore the pickup — per frame.
        let perFrame = "tileDrag = TileDrag(grab: inFlight.grab, haptics: haptics)"
        XCTAssertFalse(perFrame.contains("if carried == nil"))
        let once = "if carried == nil {\n    tileDrag = TileDrag(grab: inFlight.grab, haptics: haptics)\n}"
        XCTAssertTrue(once.contains("if carried == nil"))
        XCTAssertTrue(once.contains("TileDrag(grab:"))

        // A view that moved the tile itself instead of going through the drag.
        let handRolled = "board.remove(at: from)\ntry? board.place(tile, at: to)"
        XCTAssertTrue(handRolled.contains("board.remove("))
        XCTAssertTrue(handRolled.contains("board.place("))
        XCTAssertFalse(handRolled.contains(".drop("))

        // And the mapping check must separate the two arms.
        XCTAssertFalse("case .placed: .placed".contains("case .selected: .selected"))
        XCTAssertTrue("case .selected: .selected".contains("case .selected: .selected"))
    }

    func testRoundTwoWiringChecksHaveTeeth() {
        // Stacking order: a body with no zIndex, and one that raises the wrong
        // thing, must both read as unpinned.
        let flat = "BrandTile(letter: l, size: s, state: st)\n.offset(x: p.x, y: p.y)"
        XCTAssertFalse(flat.contains("zIndex(cell.state == .selected"))
        XCTAssertFalse(".zIndex(cell.coord.row)".contains("zIndex(cell.state == .selected"))
        XCTAssertTrue(".zIndex(cell.state == .selected ? 1 : 0)".contains("zIndex(cell.state == .selected"))

        // Touch-down recognition: the default and an explicit non-zero distance
        // must both fail, or the check is not reading the number.
        XCTAssertFalse("DragGesture()".contains("DragGesture(minimumDistance: 0)"))
        XCTAssertFalse("DragGesture(minimumDistance: 10)".contains("DragGesture(minimumDistance: 0)"))
        XCTAssertTrue("DragGesture(minimumDistance: 0)".contains("DragGesture(minimumDistance: 0)"))

        // The pinch belt: a magnify path that clears nothing, and one that
        // clears by firing a rejected-drop feel, are both wrong.
        let unbelted = "MagnifyGesture().onChanged { value in\nlet start = camera\n}"
        XCTAssertFalse(unbelted.contains("tileDrag = nil"))
        let buzzing = "if tileDrag != nil { haptics.fire(.reject); tileDrag = nil }"
        XCTAssertTrue(buzzing.contains("tileDrag = nil"))
        XCTAssertTrue(buzzing.contains("haptics"), "the teeth must catch a feel on the cancel path")
        let belted = "if tileDrag != nil {\n    tileDrag = nil\n    dragTranslation = .zero\n}"
        XCTAssertTrue(belted.contains("tileDrag = nil"))
        XCTAssertTrue(belted.contains("dragTranslation = .zero"))
        XCTAssertFalse(belted.contains("haptics"))

        // Cold generators built per event, versus held and prepared ones. The
        // check names each generator, so a single one sliding back to a `var`
        // has to read as cold even while its two siblings still read as held.
        let cold = "UIImpactFeedbackGenerator(style: .light).impactOccurred()"
        XCTAssertFalse(cold.contains("prepare()"))
        XCTAssertFalse(cold.contains("static let pickupGenerator"))
        let oneCold = """
        @MainActor private static var pickupGenerator = UIImpactFeedbackGenerator(style: .light)
        @MainActor private static let snapGenerator = UIImpactFeedbackGenerator(style: .medium)
        """
        XCTAssertFalse(oneCold.contains("static let pickupGenerator"))
        XCTAssertTrue(oneCold.contains("static let snapGenerator"), "a bare \"static let\" would pass this file")
        let warm = "@MainActor private static let pickupGenerator = UIImpactFeedbackGenerator(style: .light)"
        XCTAssertTrue(warm.contains("static let pickupGenerator"))

        // And the trap-versus-hop separation.
        XCTAssertFalse("MainActor.assumeIsolated { play(event) }".contains("Thread.isMainThread"))
        XCTAssertTrue("guard Thread.isMainThread else { return }".contains("Thread.isMainThread"))
    }

    func testInputLockWiringChecksHaveTeeth() throws {
        // A grab decided without the lock, versus one decided with it.
        let deaf = "let inFlight = carried ?? BoardGesture.Drag(at: value.startLocation, in: board, camera: camera)"
        XCTAssertFalse(deaf.contains("camera: camera, inputLocked: model.inputLocked"))
        let wired = "carried ?? BoardGesture.Drag(at: value.startLocation, in: board, camera: camera, inputLocked: model.inputLocked)"
        XCTAssertTrue(wired.contains("camera: camera, inputLocked: model.inputLocked"))

        // A gesture that ACCEPTS the flag and never reads it must still read as
        // unpinned, or the check is only counting a parameter list.
        let acceptedNotRead = """
            public init(at p: CGPoint, in board: Board, camera: BoardCamera, inputLocked: Bool = false) {
                self.grab = board.tile(at: c).map { .tile($0, at: c) } ?? .pan
            }
            """
        XCTAssertTrue(acceptedNotRead.contains("inputLocked: Bool = false"))
        XCTAssertFalse(acceptedNotRead.contains("guard !inputLocked else"))
        XCTAssertTrue("guard !inputLocked else {\n    self.grab = .pan\n    return\n}".contains("guard !inputLocked else"))

        // A default that flipped would break every existing call site silently.
        XCTAssertFalse("inputLocked: Bool = true".contains("inputLocked: Bool = false"))

        // Reverting after the fact, versus refusing at the start.
        XCTAssertTrue("if model.inputLocked { model.cancel() }".contains("if model.inputLocked"))
        XCTAssertFalse("model.began(inFlight.grab, haptics: haptics)".contains("if model.inputLocked"))

        // A sync that only runs on a LATER change leaves a rebuilt view unlocked.
        XCTAssertFalse(
            ".onChange(of: inputLocked) { model.inputLocked = inputLocked }"
                .contains(".onChange(of: inputLocked, initial: true)")
        )
        XCTAssertTrue(
            ".onChange(of: inputLocked, initial: true) { model.inputLocked = inputLocked }"
                .contains(".onChange(of: inputLocked, initial: true)")
        )

        // A camera path that grew a lock check, versus one that did not.
        XCTAssertTrue("if model.inputLocked { return }\ncamera = start.magnified(by: m, about: a)".contains("inputLocked"))
        XCTAssertFalse("camera = start.magnified(by: m, about: a)".contains("inputLocked"))
        XCTAssertTrue("if isLocked { return }".contains("Locked"))
        XCTAssertFalse("camera = BoardGesture.recentered(camera, over: board, in: rect)".contains("Locked"))
        // ...and the "still does its job" halves must separate a live path from
        // an emptied one.
        XCTAssertTrue("camera = start.magnified(by: value.magnification, about: a)".contains("magnified(by:"))
        XCTAssertFalse("camera = start".contains("magnified(by:"))

        // Two cancel paths versus one.
        let twoCancels = """
            public mutating func cancel() { tileDrag = nil }
            public mutating func lockOut() { tileDrag = nil; dragTranslation = .zero }
            """
        XCTAssertEqual(BoardSource.matches(#"(tileDrag = nil)"#, in: twoCancels).count, 2)
        XCTAssertEqual(
            BoardSource.matches(#"(tileDrag = nil)"#, in: "mutating func cancel() { tileDrag = nil }").count, 1
        )

        // A session that buzzed on its own cancel path, versus one that only
        // ever hands the hardware to `TileDrag`.
        XCTAssertTrue("haptics.fire(.reject)".contains("haptics.fire"))
        XCTAssertFalse("tileDrag = TileDrag(grab: grab, haptics: haptics)".contains("haptics.fire"))

        // A commit that names a distance of its own instead of forwarding the
        // injected one.
        XCTAssertFalse("tileDrag.drop(translation: t, on: board, camera: c, threshold: 22)".contains("threshold: threshold"))
        XCTAssertTrue("tileDrag.drop(translation: t, on: board, camera: c, threshold: threshold)".contains("threshold: threshold"))

        // A view that kept session state of its own after the move.
        XCTAssertTrue("@State private var tileDrag: TileDrag?".contains("tileDrag"))
        XCTAssertFalse("@State private var model: BoardModel".contains("tileDrag"))

        // A model that grew a camera the lock could reach.
        XCTAssertTrue("private var camera: BoardCamera".contains("var camera"))
        XCTAssertFalse("public mutating func commit(translation: CGSize, on board: Board, camera: BoardCamera)".contains("var camera"))

        // And the section slicer must actually slice, or every path check above
        // is reading the whole file.
        let file = "private var magnifyGesture {\n  zoom()\n}\nprivate func recenterControl() {\n  frame()\n}"
        let sliced = try section(of: file, from: "private var magnifyGesture", to: "private func recenterControl")
        XCTAssertTrue(sliced.contains("zoom()"))
        XCTAssertFalse(sliced.contains("frame()"))
    }
}
