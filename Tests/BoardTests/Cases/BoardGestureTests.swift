import XCTest
import Foundation
import CoreGraphics
import WillagramsRules

/// The camera gestures, executed. `BoardView` only wires SwiftUI's
/// `DragGesture`/`MagnifyGesture` to these calls, so driving them directly is
/// driving the gesture — the four criteria for this item are all decided here,
/// not in the view.
final class BoardGestureTests: XCTestCase {

    /// A run of three at row 0 plus one loose tile well away from it, so both
    /// occupied and empty cells are easy to name at any camera.
    private static func board() -> Board {
        var board = Board()
        for (offset, letter) in "CAT".enumerated() {
            try? board.place(Tile(letter: letter), at: Coord(row: 0, col: offset))
        }
        try? board.place(Tile(letter: "Z"), at: Coord(row: -4, col: -7))
        return board
    }

    /// A point inside `coord`'s cell, `fraction` of the way across it.
    private func point(in coord: Coord, camera: BoardCamera, fraction: CGFloat = 0.5) -> CGPoint {
        let origin = camera.point(for: coord)
        let size = camera.cellSize
        return CGPoint(x: origin.x + size * fraction, y: origin.y + size * fraction)
    }

    // MARK: - Criterion 1: empty cell pans one-to-one, tile leaves the camera alone

    func testDragBeginningOnAnEmptyCellPansOneToOne() {
        let camera = BoardCamera(pan: CGSize(width: 31.5, height: -17.25), zoom: 1.3, baseCellSize: 48)
        let board = Self.board()
        let empty = Coord(row: 5, col: 5)
        XCTAssertNil(board.tile(at: empty))

        let drag = BoardGesture.Drag(at: point(in: empty, camera: camera), in: board, camera: camera)
        XCTAssertEqual(drag.grab, .pan)

        for translation in [
            CGSize(width: 0, height: 0),
            CGSize(width: 137, height: -211),
            CGSize(width: -4321.75, height: 9876.25),
        ] {
            let moved = drag.camera(camera, translatedBy: translation)
            XCTAssertEqual(moved.pan.width, camera.pan.width + translation.width, accuracy: 1e-9)
            XCTAssertEqual(moved.pan.height, camera.pan.height + translation.height, accuracy: 1e-9)
            XCTAssertEqual(moved.zoom, camera.zoom, "a pan must not change zoom")
        }
    }

    func testDragBeginningOnATileLeavesTheCameraUnchanged() {
        let camera = BoardCamera(pan: CGSize(width: 31.5, height: -17.25), zoom: 1.3, baseCellSize: 48)
        let board = Self.board()
        let occupied = Coord(row: 0, col: 1)
        let tile = try! XCTUnwrap(board.tile(at: occupied))

        let drag = BoardGesture.Drag(at: point(in: occupied, camera: camera), in: board, camera: camera)
        XCTAssertEqual(drag.grab, .tile(tile, at: occupied))

        for translation in [CGSize(width: 200, height: 200), CGSize(width: -50, height: 900)] {
            let moved = drag.camera(camera, translatedBy: translation)
            XCTAssertEqual(moved.pan, camera.pan)
            XCTAssertEqual(moved.zoom, camera.zoom)
        }
    }

    func testTheNegativeQuadrantHitTestsTheSameWay() {
        // The board is unbounded; a grab at row/col well below zero must
        // decide exactly as one above it.
        let camera = BoardCamera(pan: CGSize(width: -640, height: 480), zoom: 0.9, baseCellSize: 48)
        let board = Self.board()
        let loose = Coord(row: -4, col: -7)
        let tile = try! XCTUnwrap(board.tile(at: loose))

        XCTAssertEqual(
            BoardGesture.Drag(at: point(in: loose, camera: camera), in: board, camera: camera).grab,
            .tile(tile, at: loose)
        )
        XCTAssertEqual(
            BoardGesture.Drag(at: point(in: Coord(row: -4, col: -6), camera: camera), in: board, camera: camera).grab,
            .pan
        )
    }

    // MARK: - Guardrail: the decision is taken once and never changes mid-gesture

    func testAPanThatCrossesATileKeepsPanning() {
        let camera = BoardCamera(baseCellSize: 48)
        let board = Self.board()
        let start = point(in: Coord(row: 3, col: 0), camera: camera)
        let drag = BoardGesture.Drag(at: start, in: board, camera: camera)
        XCTAssertEqual(drag.grab, .pan)

        // Walk the finger up through row 0, which is solid tiles, one cell at
        // a time. Every step must still be a pan, and still one-to-one.
        for step in 1...6 {
            let translation = CGSize(width: 0, height: -camera.cellSize * CGFloat(step))
            let here = CGPoint(x: start.x + translation.width, y: start.y + translation.height)
            let coordUnderFinger = camera.coord(at: here)
            if step == 3 {
                XCTAssertNotNil(board.tile(at: coordUnderFinger), "step 3 must actually cross a tile")
            }
            let moved = drag.camera(camera, translatedBy: translation)
            XCTAssertEqual(moved.pan.height, camera.pan.height + translation.height, accuracy: 1e-9)
        }
    }

    func testATileGrabStaysATileGrabOverEmptyCells() {
        let camera = BoardCamera(baseCellSize: 48)
        let board = Self.board()
        let drag = BoardGesture.Drag(
            at: point(in: Coord(row: 0, col: 0), camera: camera), in: board, camera: camera
        )
        for step in 1...6 {
            let moved = drag.camera(camera, translatedBy: CGSize(width: 0, height: camera.cellSize * CGFloat(step)))
            XCTAssertEqual(moved.pan, camera.pan, "a tile grab must never start panning mid-gesture")
        }
    }

    // MARK: - Guardrail: the hit test and the renderer agree on every cell edge

    func testGrabAgreesWithTheDrawListOnEveryVisibleCellIncludingItsEdges() {
        // The carried defect family for this item: a hit test that re-derives
        // "which cell is this" disagrees with the renderer at a boundary, and
        // a tile becomes pannable along one edge and draggable along the
        // other. Both sides route through BoardCamera's one index helper, and
        // this walks every drawn cell — corner, mid-edge and center — to prove
        // it.
        let camera = BoardCamera(pan: CGSize(width: 13.5, height: -27.25), zoom: 1.25, baseCellSize: 48)
        let board = Self.board()
        let rect = CGRect(x: 0, y: 0, width: 420, height: 340)
        let cells = BoardRender.cells(board: board, camera: camera, in: rect)
        XCTAssertFalse(cells.isEmpty)

        for cell in cells {
            let size = camera.cellSize
            let probes: [(String, CGPoint)] = [
                ("top-left corner", cell.point),
                ("mid-left edge", CGPoint(x: cell.point.x, y: cell.point.y + size / 2)),
                ("top mid-edge", CGPoint(x: cell.point.x + size / 2, y: cell.point.y)),
                ("center", CGPoint(x: cell.point.x + size / 2, y: cell.point.y + size / 2)),
                ("last interior point", CGPoint(x: cell.point.x + size - 0.001, y: cell.point.y + size - 0.001)),
            ]
            for (name, probe) in probes {
                let grab = BoardGesture.Drag(at: probe, in: board, camera: camera).grab
                switch (cell.tile, grab) {
                case (nil, .pan):
                    break
                case (let tile?, .tile(let grabbed, let coord)):
                    XCTAssertEqual(grabbed, tile, "\(name) of \(cell.coord)")
                    XCTAssertEqual(coord, cell.coord, "\(name) of \(cell.coord)")
                default:
                    XCTFail("\(name) of \(cell.coord) drew \(String(describing: cell.tile)) but grabbed \(grab)")
                }
            }
        }
    }

    // MARK: - Criterion 2: pinch holds its midpoint, cell size stops at 24 and 72

    func testMagnifyKeepsTheBoardPositionUnderTheAnchorFixed() {
        let cameras = [
            BoardCamera(baseCellSize: 48),
            BoardCamera(pan: CGSize(width: -913.5, height: 617.25), zoom: 0.62, baseCellSize: 48),
            BoardCamera(pan: CGSize(width: 44, height: -44), zoom: 1.44, baseCellSize: 30),
        ]
        let anchors = [CGPoint(x: 0, y: 0), CGPoint(x: 512, y: 384), CGPoint(x: -220.5, y: 77.25)]
        // Includes magnifications far past both clamp ends: the anchor must
        // hold even once the cell size has saturated.
        let magnifications: [CGFloat] = [0.001, 0.5, 0.999, 1, 1.001, 2, 12, 1000]

        for camera in cameras {
            for anchor in anchors {
                for magnification in magnifications {
                    let zoomed = camera.magnified(by: magnification, about: anchor)

                    let before = CGPoint(
                        x: (anchor.x - camera.pan.width) / camera.cellSize,
                        y: (anchor.y - camera.pan.height) / camera.cellSize
                    )
                    let after = CGPoint(
                        x: (anchor.x - zoomed.pan.width) / zoomed.cellSize,
                        y: (anchor.y - zoomed.pan.height) / zoomed.cellSize
                    )
                    XCTAssertEqual(before.x, after.x, accuracy: 1e-6, "x, magnification \(magnification)")
                    XCTAssertEqual(before.y, after.y, accuracy: 1e-6, "y, magnification \(magnification)")
                }
            }
        }
    }

    func testRenderedCellSizeStopsAtTwentyFourAndSeventyTwo() {
        let camera = BoardCamera(pan: CGSize(width: 12, height: -34), zoom: 1, baseCellSize: 48)
        let anchor = CGPoint(x: 300, y: 200)

        XCTAssertEqual(camera.magnified(by: 0.0001, about: anchor).cellSize, 24, accuracy: 1e-9)
        XCTAssertEqual(camera.magnified(by: 10000, about: anchor).cellSize, 72, accuracy: 1e-9)

        // And nothing in between escapes the range, at any base cell size.
        for baseCellSize: CGFloat in [8, 30, 48, 96] {
            for magnification: CGFloat in [0.01, 0.3, 1, 1.7, 5, 40] {
                let size = BoardCamera(zoom: 1, baseCellSize: baseCellSize)
                    .magnified(by: magnification, about: anchor)
                    .cellSize
                XCTAssertGreaterThanOrEqual(size, BoardCamera.minCellSize)
                XCTAssertLessThanOrEqual(size, BoardCamera.maxCellSize)
            }
        }
    }

    func testRepeatedPinchesCompoundThroughTheClampWithoutSticking() {
        // Pinching hard past the ceiling must bank no dead travel: the stored
        // zoom is clamped, so an ordinary reverse pinch moves the rendered size
        // at once instead of unwinding overshoot first.
        //
        // 0.5x, deliberately NOT the 0.01x that is the exact inverse of the
        // 100x above: an exact reciprocal returns to the start by arithmetic
        // whatever the code does, so it cannot fail and tested nothing.
        let camera = BoardCamera(zoom: 1, baseCellSize: 48)
        let anchor = CGPoint(x: 100, y: 100)
        let out = camera.magnified(by: 100, about: anchor)
        XCTAssertEqual(out.cellSize, 72, accuracy: 1e-9)
        let back = out.magnified(by: 0.5, about: anchor)
        XCTAssertLessThan(
            back.cellSize, out.cellSize,
            "a reverse pinch must move the rendered size on the very next gesture"
        )
    }

    func testMagnifyWithDegenerateInputLeavesTheCameraUnchanged() {
        // A pinch really can report zero or a non-finite value on its first
        // change, and a NaN reaching `pan` would trap the next Int conversion.
        let camera = BoardCamera(pan: CGSize(width: 7, height: -9), zoom: 1.1, baseCellSize: 48)
        for magnification: CGFloat in [0, -1, .nan, .infinity, -.infinity] {
            let result = camera.magnified(by: magnification, about: CGPoint(x: 10, y: 10))
            XCTAssertEqual(result.pan, camera.pan, "magnification \(magnification)")
            XCTAssertEqual(result.zoom, camera.zoom, "magnification \(magnification)")
        }
        for bad: CGFloat in [.nan, .infinity, -.infinity] {
            for anchor in [CGPoint(x: bad, y: 0), CGPoint(x: 0, y: bad), CGPoint(x: bad, y: bad)] {
                let result = camera.magnified(by: 2, about: anchor)
                XCTAssertEqual(result.pan, camera.pan)
                XCTAssertTrue(result.cellSize.isFinite)
            }
        }
        // A camera already holding a degenerate zoom is returned exactly as it
        // was rather than having a NaN written into `pan` — pan is the field
        // every later Int conversion reads, so that is the trap risk.
        let sick = BoardCamera(zoom: .nan, baseCellSize: 48)
            .magnified(by: 2, about: CGPoint(x: 10, y: 10))
        XCTAssertEqual(sick.pan, .zero)
        _ = sick.coord(at: CGPoint(x: 5, y: 5))
    }

    func testPanWithNonFiniteTranslationLeavesTheCameraUnchanged() {
        let camera = BoardCamera(pan: CGSize(width: 3, height: 4))
        for bad: CGFloat in [.nan, .infinity, -.infinity] {
            for translation in [CGSize(width: bad, height: 0), CGSize(width: 0, height: bad)] {
                XCTAssertEqual(camera.panned(by: translation).pan, camera.pan)
            }
        }
    }

    // MARK: - Criterion 3: recenter frames every placed tile

    func testRecenteredFramesEveryPlacedTile() {
        let rect = CGRect(x: 0, y: 0, width: 1024, height: 768)
        // Spread across all four quadrants, and wide enough that the fit is
        // decided by the span rather than by the clamp ceiling.
        let coords = [
            Coord(row: -10, col: -15), Coord(row: 0, col: 0),
            Coord(row: 10, col: 15), Coord(row: -6, col: 9),
        ]
        var board = Board()
        for coord in coords { try? board.place(Tile(letter: "A"), at: coord) }

        let recentered = BoardGesture.recentered(BoardCamera(), over: board, in: rect)

        for coord in coords {
            let origin = recentered.point(for: coord)
            let cell = CGRect(
                origin: origin,
                size: CGSize(width: recentered.cellSize, height: recentered.cellSize)
            )
            // Not `rect.contains`: a span that fits exactly puts the outermost
            // cell's far edge on rect.maxX, which `contains` excludes.
            XCTAssertGreaterThanOrEqual(cell.minX, rect.minX - 1e-6, "\(coord) left of \(rect)")
            XCTAssertLessThanOrEqual(cell.maxX, rect.maxX + 1e-6, "\(coord) right of \(rect)")
            XCTAssertGreaterThanOrEqual(cell.minY, rect.minY - 1e-6, "\(coord) above \(rect)")
            XCTAssertLessThanOrEqual(cell.maxY, rect.maxY + 1e-6, "\(coord) below \(rect)")
        }
        XCTAssertGreaterThanOrEqual(recentered.cellSize, BoardCamera.minCellSize)
        XCTAssertLessThanOrEqual(recentered.cellSize, BoardCamera.maxCellSize)
        XCTAssertLessThan(recentered.cellSize, BoardCamera.maxCellSize, "the span, not the clamp, must decide this fit")
    }

    func testRecenteredOverAnEmptyBoardLeavesTheCameraUnchanged() {
        let camera = BoardCamera(pan: CGSize(width: 5, height: 6), zoom: 1.3)
        let result = BoardGesture.recentered(camera, over: Board(), in: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(result.pan, camera.pan)
        XCTAssertEqual(result.zoom, camera.zoom)
    }

    func testRecenteredReadsEveryPlacementNotJustTheVisibleOnes() {
        // A recenter driven off the visible range would frame nothing, since
        // the tile starts off screen. This is what "every placed coord" buys.
        let rect = CGRect(x: 0, y: 0, width: 800, height: 600)
        let camera = BoardCamera(baseCellSize: 48)
        var board = Board()
        try? board.place(Tile(letter: "Q"), at: Coord(row: 400, col: -400))
        XCTAssertTrue(BoardRender.cells(board: board, camera: camera, in: rect).allSatisfy { $0.tile == nil })

        let recentered = BoardGesture.recentered(camera, over: board, in: rect)
        XCTAssertTrue(rect.contains(recentered.point(for: Coord(row: 400, col: -400))))
    }

    // MARK: - Criterion 4: a thousand cells in any direction still renders

    func testPanningAThousandCellsInEveryDirectionStillRendersNormally() {
        let rect = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let board = Self.board()
        let base = BoardCamera(baseCellSize: 48)
        let baseline = BoardRender.cells(board: board, camera: base, in: rect)
        XCTAssertFalse(baseline.isEmpty)

        let cells: CGFloat = 1000
        let step = base.cellSize * cells
        let directions: [(String, CGSize, Int, Int)] = [
            ("left", CGSize(width: step, height: 0), 0, -1000),
            ("right", CGSize(width: -step, height: 0), 0, 1000),
            ("up", CGSize(width: 0, height: step), -1000, 0),
            ("down", CGSize(width: 0, height: -step), 1000, 0),
            ("up-left", CGSize(width: step, height: step), -1000, -1000),
            ("down-right", CGSize(width: -step, height: -step), 1000, 1000),
        ]

        for (name, translation, rowShift, colShift) in directions {
            let drag = BoardGesture.Drag(at: CGPoint(x: 500, y: 400), in: board, camera: base)
            XCTAssertEqual(drag.grab, .pan, name)
            let panned = drag.camera(base, translatedBy: translation)

            // Pan is exact: nothing clamped it on the way out.
            XCTAssertEqual(panned.pan.width, base.pan.width + translation.width, accuracy: 1e-9, name)
            XCTAssertEqual(panned.pan.height, base.pan.height + translation.height, accuracy: 1e-9, name)

            let moved = BoardRender.cells(board: board, camera: panned, in: rect)
            XCTAssertEqual(moved.count, baseline.count, "\(name) changed the draw list size")
            XCTAssertEqual(
                moved.map(\.coord),
                baseline.map { Coord(row: $0.coord.row + rowShift, col: $0.coord.col + colShift) },
                "\(name) did not shift the visible range by exactly 1000 cells"
            )
            for cell in moved {
                XCTAssertEqual(cell.point, panned.point(for: cell.coord))
                XCTAssertTrue(cell.point.x.isFinite && cell.point.y.isFinite, name)
            }
        }
    }

    func testPanIsNeverClampedToAnyMaximumExtent() {
        let camera = BoardCamera()
        for magnitude: CGFloat in [1e3, 1e6, 1e9, 1e12] {
            for translation in [
                CGSize(width: magnitude, height: magnitude),
                CGSize(width: -magnitude, height: -magnitude),
            ] {
                let panned = camera.panned(by: translation)
                XCTAssertEqual(panned.pan.width, translation.width)
                XCTAssertEqual(panned.pan.height, translation.height)
            }
        }
    }

    // MARK: - Deferred minor: recenter and visibleCoords share one rect convention

    func testRecenterAndVisibleCoordsAgreeOnAMirroredRect() {
        // Before `standardized`, `visibleCoords` enumerated a mirrored rect
        // (its minX/maxX reads already standardize) while `recenter`'s
        // `width > 0` refused it. One convention now: a mirrored rect
        // describes a real region and both handle it.
        let mirrored = CGRect(x: 800, y: 600, width: -800, height: -600)
        XCTAssertFalse(Array(BoardCamera().visibleCoords(in: mirrored)).isEmpty)

        var board = Board()
        try? board.place(Tile(letter: "A"), at: Coord(row: -3, col: -3))
        try? board.place(Tile(letter: "B"), at: Coord(row: 3, col: 3))

        let recentered = BoardGesture.recentered(BoardCamera(), over: board, in: mirrored)
        for coord in [Coord(row: -3, col: -3), Coord(row: 3, col: 3)] {
            XCTAssertTrue(
                mirrored.standardized.contains(recentered.point(for: coord)),
                "\(coord) not framed by the mirrored rect"
            )
        }
    }

    func testRecenterStillRefusesAnAreaLessOrNonFiniteRect() {
        // Standardizing must not have widened the guard: a rect with no area
        // is still not a frame, and a non-finite one still must not reach the
        // divide.
        let camera = BoardCamera(pan: CGSize(width: 5, height: 7))
        var board = Board()
        try? board.place(Tile(letter: "A"), at: Coord(row: 0, col: 0))
        for rect in [
            CGRect(x: 0, y: 0, width: 0, height: 600),
            CGRect(x: 0, y: 0, width: 800, height: 0),
            CGRect(x: 0, y: 0, width: CGFloat.nan, height: 600),
            CGRect(x: CGFloat.infinity, y: 0, width: 800, height: 600),
        ] {
            let result = BoardGesture.recentered(camera, over: board, in: rect)
            XCTAssertEqual(result.pan, camera.pan)
            XCTAssertEqual(result.zoom, camera.zoom)
            XCTAssertTrue(result.cellSize.isFinite)
        }
    }
}
