import XCTest
import Foundation
import CoreGraphics
import WillagramsRules

/// QA probes for item 3, aimed at the seams the item's own tests do not reach:
/// what the camera state does *across* gesture boundaries, whether the hit test
/// and the renderer still agree once the viewport is in the negative quadrant
/// or a thousand cells away, and what recenter does when the cell-size clamp
/// and "frame every tile" cannot both hold.
final class BoardGestureProbeTests: XCTestCase {

    /// A run of three at row 0 plus one loose tile well away from it.
    private static func board() -> Board {
        var board = Board()
        for (offset, letter) in "CAT".enumerated() {
            try? board.place(Tile(letter: letter), at: Coord(row: 0, col: offset))
        }
        try? board.place(Tile(letter: "Z"), at: Coord(row: -4, col: -7))
        return board
    }

    /// One complete pinch, wired exactly as `BoardView.magnifyGesture` wires it:
    /// `pinchStart` is nil at touch-down, so the gesture snapshots the *live*
    /// camera, applies a magnification cumulative from that moment, and drops
    /// the snapshot on release. The next pinch therefore starts from whatever
    /// `zoom` this one left behind.
    private func pinch(_ camera: BoardCamera, by magnification: CGFloat, about anchor: CGPoint) -> BoardCamera {
        let start = camera
        return start.magnified(by: magnification, about: anchor)
    }

    /// The board position sitting under `anchor`, in fractional cells.
    private func boardPoint(under anchor: CGPoint, in camera: BoardCamera) -> CGPoint {
        CGPoint(
            x: (anchor.x - camera.pan.width) / camera.cellSize,
            y: (anchor.y - camera.pan.height) / camera.cellSize
        )
    }

    // MARK: - Zoom windup across gestures

    func testAPinchInRespondsAfterSeveralPinchesOut() {
        // `zoom` is stored unclamped and only the derived `cellSize` is clamped,
        // so successive pinches multiply `zoom` without bound while the render
        // has been pinned at 72pt since zoom 1.5. Each gesture re-snapshots the
        // live camera, so that overshoot is carried into the next gesture and
        // has to be paid back before anything on screen moves.
        let anchor = CGPoint(x: 512, y: 384)
        var camera = BoardCamera(baseCellSize: 48)

        for _ in 0..<5 { camera = pinch(camera, by: 3, about: anchor) }
        XCTAssertEqual(camera.cellSize, BoardCamera.maxCellSize, accuracy: 1e-9, "five pinches out must reach the ceiling")

        // One ordinary pinch in — a real one, not the exact arithmetic inverse
        // of everything that came before.
        let after = pinch(camera, by: 0.25, about: anchor)
        XCTAssertLessThan(
            after.cellSize,
            camera.cellSize,
            "a pinch in produced no change in rendered cell size: zoom is \(camera.zoom), "
                + "so the user must unwind \(camera.zoom / (BoardCamera.maxCellSize / camera.baseCellSize))x "
                + "of dead travel before the board responds"
        )
    }

    func testZoomDoesNotGrowWithoutBoundAcrossGestures() {
        // The same defect stated as state rather than as feel: nothing bounds
        // `zoom`, so a session of pinching leaves it arbitrarily far outside
        // the range any cell size can express.
        let anchor = CGPoint(x: 300, y: 200)
        var camera = BoardCamera(baseCellSize: 48)
        for _ in 0..<10 { camera = pinch(camera, by: 2, about: anchor) }

        let ceiling = BoardCamera.maxCellSize / camera.baseCellSize
        XCTAssertLessThanOrEqual(
            camera.zoom, ceiling,
            "zoom reached \(camera.zoom) while the render saturated at zoom \(ceiling)"
        )
    }

    // MARK: - Anchor invariance under saturation

    func testTheAnchorHoldsThroughSaturationAndBackAgain() {
        let anchor = CGPoint(x: 400, y: 300)
        for base: CGFloat in [30, 48, 96] {
            let camera = BoardCamera(pan: CGSize(width: -71.5, height: 133.25), zoom: 1, baseCellSize: base)
            let before = boardPoint(under: anchor, in: camera)

            // Out past the ceiling, further out, then all the way back in.
            let out = camera.magnified(by: 10, about: anchor)
            let further = out.magnified(by: 5, about: anchor)
            let back = further.magnified(by: 1 / 50, about: anchor)

            for (name, stage) in [("out", out), ("further", further), ("back", back)] {
                let now = boardPoint(under: anchor, in: stage)
                XCTAssertEqual(before.x, now.x, accuracy: 1e-6, "base \(base), \(name)")
                XCTAssertEqual(before.y, now.y, accuracy: 1e-6, "base \(base), \(name)")
            }
            // These three assertions used to demand a LOSSLESS 10x, 5x, 1/50x
            // round trip back to the starting camera. That round trip is only
            // available while the stored `zoom` is unbounded — it is exactly
            // the 50x of banked overshoot the two red probes above call a
            // defect, read from the other side. Clamping the stored zoom (the
            // fix those probes demand) necessarily removes it: base 30 lands
            // at cellSize 24 rather than 30, base 48 at 24 rather than 48,
            // base 96 at 24 rather than 72. What is asserted instead is what
            // saturation should actually guarantee — the ceiling holds while
            // pinching out, and a reverse pinch moves the render immediately
            // rather than spending itself unwinding. The anchor-invariance
            // assertions above, which are what this test is named for, are
            // untouched and still exact at every stage.
            XCTAssertEqual(out.cellSize, BoardCamera.maxCellSize, accuracy: 1e-9, "base \(base), out")
            XCTAssertEqual(further.cellSize, BoardCamera.maxCellSize, accuracy: 1e-9, "base \(base), further")
            XCTAssertEqual(back.cellSize, BoardCamera.minCellSize, accuracy: 1e-9, "base \(base), back")
            XCTAssertLessThan(back.cellSize, further.cellSize, "base \(base): the pinch back must move the render")
        }
    }

    /// The zoom windup stated a third way: no sequence of pinches can leave
    /// `zoom` outside what a rendered cell size can express, so no pinch is
    /// ever spent paying off a previous one.
    func testNoPinchSequenceBanksTravelTheNextPinchHasToUnwind() {
        let anchor = CGPoint(x: 512, y: 384)
        for base: CGFloat in [30, 48, 96] {
            var camera = BoardCamera(baseCellSize: base)
            for magnification: CGFloat in [3, 0.2, 12, 0.05, 40, 1.4, 0.001] {
                camera = pinch(camera, by: magnification, about: anchor)
                XCTAssertGreaterThanOrEqual(
                    camera.zoom, BoardCamera.minCellSize / base - 1e-12,
                    "base \(base) after \(magnification)x"
                )
                XCTAssertLessThanOrEqual(
                    camera.zoom, BoardCamera.maxCellSize / base + 1e-12,
                    "base \(base) after \(magnification)x"
                )
            }
        }
    }

    // MARK: - Hit test and renderer agree wherever the viewport is

    /// Walks every drawn cell at four edges plus the centre and asserts the grab
    /// decision matches what the draw list put there.
    private func assertGrabMatchesDrawList(
        camera: BoardCamera,
        board: Board,
        rect: CGRect,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [BoardRender.Cell] {
        let cells = BoardRender.cells(board: board, camera: camera, in: rect)
        XCTAssertFalse(cells.isEmpty, label, file: file, line: line)
        let size = camera.cellSize

        for cell in cells {
            let probes: [(String, CGPoint)] = [
                ("top-left", cell.point),
                ("top-right", CGPoint(x: cell.point.x + size - 0.001, y: cell.point.y)),
                ("bottom-left", CGPoint(x: cell.point.x, y: cell.point.y + size - 0.001)),
                ("bottom-right", CGPoint(x: cell.point.x + size - 0.001, y: cell.point.y + size - 0.001)),
                ("center", CGPoint(x: cell.point.x + size / 2, y: cell.point.y + size / 2)),
            ]
            for (edge, probe) in probes {
                let grab = BoardGesture.Drag(at: probe, in: board, camera: camera).grab
                switch (cell.tile, grab) {
                case (nil, .pan):
                    break
                case (let tile?, .tile(let grabbed, let coord)):
                    XCTAssertEqual(grabbed, tile, "\(label) \(edge) of \(cell.coord)", file: file, line: line)
                    XCTAssertEqual(coord, cell.coord, "\(label) \(edge) of \(cell.coord)", file: file, line: line)
                default:
                    XCTFail(
                        "\(label) \(edge) of \(cell.coord): drew \(String(describing: cell.tile)) but grabbed \(grab)",
                        file: file, line: line
                    )
                }
            }
        }
        return cells
    }

    func testGrabAgreesWithTheDrawListAcrossTheNegativeQuadrant() {
        // The item's own agreement test sits at non-negative rows. The board is
        // unbounded, so the boundary convention has to hold on the other side of
        // the origin too — `.down` rounding, not truncation toward zero.
        let camera = BoardCamera(pan: CGSize(width: 100, height: 100), zoom: 1.25, baseCellSize: 48)
        let rect = CGRect(x: 0, y: 0, width: 420, height: 340)
        let cells = assertGrabMatchesDrawList(camera: camera, board: Self.board(), rect: rect, "negative quadrant")

        XCTAssertTrue(cells.contains { $0.coord.row < 0 }, "the probe never reached a negative row")
        XCTAssertTrue(cells.contains { $0.coord.col < 0 }, "the probe never reached a negative column")
        XCTAssertTrue(cells.contains { $0.tile != nil }, "the probe never covered an occupied cell")
    }

    func testGrabAgreesWithTheDrawListAfterAThousandCellPan() {
        let base = BoardCamera(pan: CGSize(width: 13.5, height: -27.25), zoom: 1.25, baseCellSize: 48)
        let rect = CGRect(x: 0, y: 0, width: 420, height: 340)
        let step = base.cellSize * 1000

        var board = Board()
        // Tiles placed where the viewport lands after each pan, so the panned
        // draw list is not all-empty and the agreement check has something to
        // disagree about.
        for shift in [-1000, 1000] {
            for offset in 0..<3 {
                try? board.place(Tile(letter: "A"), at: Coord(row: shift, col: shift + offset))
            }
        }

        for (name, translation) in [
            ("up-left", CGSize(width: step, height: step)),
            ("down-right", CGSize(width: -step, height: -step)),
        ] {
            let panned = base.panned(by: translation)
            let cells = assertGrabMatchesDrawList(camera: panned, board: board, rect: rect, name)
            XCTAssertTrue(cells.contains { $0.tile != nil }, "\(name) drew no tile, so the check was vacuous")
        }
    }

    // MARK: - A thousand cells out and back

    func testPanningAThousandCellsOutAndBackRedrawsTheIdenticalList() {
        // Counting cells only proves the range survived. This proves the whole
        // draw list does: same coords, same points, same tiles, same states.
        let rect = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let board = Self.board()
        let base = BoardCamera(pan: CGSize(width: 17.5, height: -9.25), zoom: 1, baseCellSize: 48)
        let baseline = BoardRender.cells(board: board, camera: base, in: rect)
        XCTAssertTrue(baseline.contains { $0.tile != nil }, "the baseline must draw tiles or this is vacuous")

        let step = base.cellSize * 1000
        for (name, out) in [
            ("left", CGSize(width: step, height: 0)),
            ("right", CGSize(width: -step, height: 0)),
            ("up", CGSize(width: 0, height: step)),
            ("down", CGSize(width: 0, height: -step)),
            ("up-left", CGSize(width: step, height: step)),
            ("down-right", CGSize(width: -step, height: -step)),
        ] {
            let away = base.panned(by: out)
            let there = BoardRender.cells(board: board, camera: away, in: rect)
            XCTAssertEqual(there.count, baseline.count, "\(name) changed the draw list size")
            XCTAssertTrue(there.allSatisfy { $0.point.x.isFinite && $0.point.y.isFinite }, name)

            let home = away.panned(by: CGSize(width: -out.width, height: -out.height))
            XCTAssertEqual(home.pan.width, base.pan.width, accuracy: 1e-9, name)
            XCTAssertEqual(home.pan.height, base.pan.height, accuracy: 1e-9, name)
            XCTAssertEqual(
                BoardRender.cells(board: board, camera: home, in: rect), baseline,
                "\(name) and back did not redraw the same board"
            )
        }
    }

    // MARK: - Degenerate input reaching the hit test

    func testDragWithNonFiniteStartLocationDegradesRatherThanTrapping() {
        // `startLocation` comes from a live gesture. `Int(floor(.nan))` is a
        // Swift runtime crash, so the guard in BoardCamera's index helper is
        // what stands between a stray non-finite touch point and a trap.
        let camera = BoardCamera(pan: CGSize(width: 12, height: -8), zoom: 1.1, baseCellSize: 48)
        let board = Self.board()
        for bad: CGFloat in [.nan, .infinity, -.infinity, 1e300] {
            for start in [CGPoint(x: bad, y: 0), CGPoint(x: 0, y: bad), CGPoint(x: bad, y: bad)] {
                let drag = BoardGesture.Drag(at: start, in: board, camera: camera)
                let moved = drag.camera(camera, translatedBy: CGSize(width: 40, height: 40))
                XCTAssertTrue(moved.pan.width.isFinite && moved.pan.height.isFinite, "\(start)")
                XCTAssertTrue(moved.cellSize.isFinite, "\(start)")
                _ = BoardRender.cells(board: board, camera: moved, in: CGRect(x: 0, y: 0, width: 200, height: 200))
            }
        }
    }

    func testAGeometryReaderFirstPassRectDrivesNothingIntoTheCamera() {
        // GeometryReader reports .zero on its first layout pass, and that rect
        // reaches both the draw list and the recenter control.
        let camera = BoardCamera(pan: CGSize(width: 5, height: 6), zoom: 1.2)
        let board = Self.board()
        XCTAssertTrue(BoardRender.cells(board: board, camera: camera, in: .zero).isEmpty)

        let recentered = BoardGesture.recentered(camera, over: board, in: .zero)
        XCTAssertEqual(recentered.pan, camera.pan)
        XCTAssertEqual(recentered.zoom, camera.zoom)
    }

    // MARK: - Recenter

    func testRecenterFramesASingleTile() {
        let rect = CGRect(x: 0, y: 0, width: 1024, height: 768)
        var board = Board()
        try? board.place(Tile(letter: "Q"), at: Coord(row: -312, col: 907))

        let recentered = BoardGesture.recentered(BoardCamera(), over: board, in: rect)
        let origin = recentered.point(for: Coord(row: -312, col: 907))
        let size = recentered.cellSize
        XCTAssertEqual(origin.x + size / 2, rect.midX, accuracy: 1e-6)
        XCTAssertEqual(origin.y + size / 2, rect.midY, accuracy: 1e-6)
        XCTAssertEqual(size, BoardCamera.maxCellSize, accuracy: 1e-9, "one tile should frame at the ceiling")
    }

    func testRecenterCentersContentTooLargeToFitAtTheCellSizeFloor() {
        // The 24pt floor and "frame every placed tile" cannot both hold once the
        // span exceeds the viewport in cells (a 1024pt viewport holds 42 cells
        // at the floor). The floor wins — criterion 2 is the harder constraint —
        // so the honest guarantee here is that the content is centered, not that
        // it is contained.
        let rect = CGRect(x: 0, y: 0, width: 1024, height: 768)
        var board = Board()
        for coord in [Coord(row: -100, col: -100), Coord(row: 100, col: 100)] {
            try? board.place(Tile(letter: "A"), at: coord)
        }

        let recentered = BoardGesture.recentered(BoardCamera(), over: board, in: rect)
        XCTAssertEqual(recentered.cellSize, BoardCamera.minCellSize, accuracy: 1e-9)

        let size = recentered.cellSize
        let first = recentered.point(for: Coord(row: -100, col: -100))
        let last = recentered.point(for: Coord(row: 100, col: 100))
        XCTAssertEqual((first.x + last.x + size) / 2, rect.midX, accuracy: 1e-6, "content is not horizontally centered")
        XCTAssertEqual((first.y + last.y + size) / 2, rect.midY, accuracy: 1e-6, "content is not vertically centered")
    }

    func testRecenterIsIdempotent() {
        // Pressing the control twice must not walk the camera.
        let rect = CGRect(x: 0, y: 0, width: 1024, height: 768)
        var board = Board()
        for coord in [Coord(row: -3, col: -9), Coord(row: 4, col: 2), Coord(row: 0, col: 11)] {
            try? board.place(Tile(letter: "A"), at: coord)
        }
        let once = BoardGesture.recentered(BoardCamera(pan: CGSize(width: 400, height: -900), zoom: 0.3), over: board, in: rect)
        let twice = BoardGesture.recentered(once, over: board, in: rect)
        XCTAssertEqual(once.pan.width, twice.pan.width, accuracy: 1e-9)
        XCTAssertEqual(once.pan.height, twice.pan.height, accuracy: 1e-9)
        XCTAssertEqual(once.cellSize, twice.cellSize, accuracy: 1e-9)
    }

    func testRecenterFramesTilesAThousandCellsAwayAfterPanning() {
        // Criterion 4 and criterion 3 together: pan a thousand cells off, then
        // the control must still bring every tile back into frame.
        let rect = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let coords = [Coord(row: -2, col: -3), Coord(row: 5, col: 6)]
        var board = Board()
        for coord in coords { try? board.place(Tile(letter: "A"), at: coord) }

        let lost = BoardCamera(baseCellSize: 48).panned(by: CGSize(width: -48_000, height: 48_000))
        XCTAssertTrue(BoardRender.cells(board: board, camera: lost, in: rect).allSatisfy { $0.tile == nil })

        let recentered = BoardGesture.recentered(lost, over: board, in: rect)
        let drawn = BoardRender.cells(board: board, camera: recentered, in: rect).compactMap { $0.tile == nil ? nil : $0.coord }
        XCTAssertEqual(Set(drawn), Set(coords), "recenter did not bring every placed tile back into the draw list")
    }

    // MARK: - Criterion 3's duration: the token chain, pinned end to end

    func testMotionSnapResolvesToSnapDuration() throws {
        // BoardView is pinned to `withAnimation(DesignTokens.Motion.snap)`, but
        // the criterion names `Motion.snapDuration`. Nothing yet pinned the link
        // between the two, so `snap` could be redefined at another duration and
        // every existing check would stay green. SwiftUI animation timing is not
        // observable in `swift test`, so this closes the chain by source text.
        let text = try ProbeSource.text("Willagrams/Style/DesignTokens.swift")
        XCTAssertFalse(
            ProbeSource.matches(#"static let snap\s*=\s*Animation\.\w+\(duration:\s*snapDuration\)"#, in: text).isEmpty,
            "Motion.snap is no longer built from Motion.snapDuration"
        )
    }

    func testTheMotionSnapChainCheckHasTeeth() {
        let pattern = #"static let snap\s*=\s*Animation\.\w+\(duration:\s*snapDuration\)"#
        XCTAssertFalse(
            ProbeSource.matches(pattern, in: "public static let snap = Animation.easeOut(duration: snapDuration)").isEmpty
        )
        XCTAssertTrue(
            ProbeSource.matches(pattern, in: "public static let snap = Animation.easeOut(duration: 0.42)").isEmpty
        )
        XCTAssertTrue(
            ProbeSource.matches(pattern, in: "public static let snap = Animation.spring()").isEmpty
        )
    }
}

/// Reads repo sources by path anchored off `#filePath`, never by walking the
/// repo root — sibling worktrees live under the same parent directory.
private enum ProbeSource {

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Cases
        .deletingLastPathComponent()   // BoardTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }
}
