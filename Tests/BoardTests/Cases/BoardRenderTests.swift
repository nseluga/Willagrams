import XCTest
import Foundation
import CoreGraphics
import WillagramsRules

/// `BoardRender` is every draw decision `BoardView` makes, with none of the
/// drawing — so it is the only place the item's criteria can be asserted by
/// execution. SwiftUI is not host-compilable here; `BoardSourceTests` covers
/// what is left by source text.
final class BoardRenderTests: XCTestCase {

    // MARK: - Fixtures

    /// A run of four across, a vertical pair, a lone tile, and a diagonal-only
    /// pair — offsets are relative so the same shape can be planted anywhere.
    private static let shape: [(row: Int, col: Int, letter: Character)] = [
        (0, 0, "W"), (0, 1, "I"), (0, 2, "L"), (0, 3, "L"),   // across run
        (3, 0, "A"), (4, 0, "M"),                             // down run
        (7, 10, "Z"),                                         // lone
        (6, 5, "Q"), (7, 6, "X"),                             // diagonal only
    ]

    private static func board(offsetRow: Int = 0, offsetCol: Int = 0) -> Board {
        var board = Board()
        for entry in shape {
            try? board.place(
                Tile(letter: entry.letter),
                at: Coord(row: entry.row + offsetRow, col: entry.col + offsetCol)
            )
        }
        return board
    }

    /// A camera that puts the cell at `(row, col)` exactly at the view origin,
    /// so a translated board frames identically to the untranslated one.
    private static func camera(framing row: Int, _ col: Int, baseCellSize: CGFloat = 48) -> BoardCamera {
        BoardCamera(
            pan: CGSize(width: -CGFloat(col) * baseCellSize, height: -CGFloat(row) * baseCellSize),
            zoom: 1,
            baseCellSize: baseCellSize
        )
    }

    private static let viewport = CGRect(x: 0, y: 0, width: 640, height: 480)

    private func cell(_ coord: Coord, in cells: [BoardRender.Cell]) -> BoardRender.Cell? {
        cells.first { $0.coord == coord }
    }

    // MARK: - Criterion 1: every visible coord renders, at the camera's point

    func testEveryVisibleCoordRendersExactlyOnceAtTheCameraPoint() {
        let camera = BoardCamera(pan: CGSize(width: 13.5, height: -27.25), zoom: 1.25, baseCellSize: 48)
        let board = Self.board()
        let rect = Self.viewport

        let expected = Array(camera.visibleCoords(in: rect))
        let cells = BoardRender.cells(board: board, camera: camera, in: rect)

        XCTAssertFalse(expected.isEmpty, "fixture viewport enumerates no coords")
        XCTAssertEqual(cells.count, expected.count, "draw list is not one entry per visible coord")
        XCTAssertEqual(cells.map(\.coord), expected, "draw list is not the visible range, in order")
        XCTAssertEqual(Set(cells.map(\.coord)).count, cells.count, "a coord is drawn more than once")

        for entry in cells {
            // Nothing in BoardRender may re-derive geometry; the point must be
            // the camera's, exactly.
            XCTAssertEqual(entry.point, camera.point(for: entry.coord), "point drifted at \(entry.coord)")
        }
    }

    // MARK: - Criterion 1: every placed tile inside the range renders

    func testPlacedTilesRenderWithTheirIdentityAndEmptyCellsCarryNoState() {
        let camera = BoardCamera(pan: CGSize(width: 13.5, height: -27.25), zoom: 1.25, baseCellSize: 48)
        let board = Self.board()
        let rect = Self.viewport

        let visible = Set(camera.visibleCoords(in: rect))
        let cells = BoardRender.cells(board: board, camera: camera, in: rect)

        // Oracle is `board.placements` — the test's independent path, and the
        // one the render is forbidden from taking.
        let inside = board.placements.filter { visible.contains($0.key) }
        XCTAssertFalse(inside.isEmpty, "fixture places no tile inside the viewport")

        for (coord, tile) in inside {
            let drawn = self.cell(coord, in: cells)
            XCTAssertEqual(drawn?.tile?.id, tile.id, "tile identity lost at \(coord)")
            XCTAssertEqual(drawn?.tile?.letter, tile.letter, "letter lost at \(coord)")
            XCTAssertNotNil(drawn?.state, "a drawn tile has no state at \(coord)")
        }

        for entry in cells where board.tile(at: entry.coord) == nil {
            XCTAssertNil(entry.tile, "empty cell carries a tile at \(entry.coord)")
            XCTAssertNil(entry.state, "empty cell carries a state at \(entry.coord)")
        }
    }

    func testTilesOutsideTheVisibleRectNeverAppear() {
        let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)
        let rect = Self.viewport

        var board = Self.board()
        let strayFar = Coord(row: 900, col: 900)
        let strayNegative = Coord(row: -7, col: -3)
        try? board.place(Tile(letter: "F"), at: strayFar)
        try? board.place(Tile(letter: "N"), at: strayNegative)

        let visible = Set(camera.visibleCoords(in: rect))
        XCTAssertFalse(visible.contains(strayFar))
        XCTAssertFalse(visible.contains(strayNegative))

        let cells = BoardRender.cells(board: board, camera: camera, in: rect)
        let drawn = Set(cells.map(\.coord))
        XCTAssertFalse(drawn.contains(strayFar), "an off-screen tile was drawn")
        XCTAssertFalse(drawn.contains(strayNegative), "an off-screen tile was drawn")

        let letters = Set(cells.compactMap { $0.tile?.letter })
        XCTAssertFalse(letters.contains("F"), "an off-screen tile's art was drawn")
        XCTAssertFalse(letters.contains("N"), "an off-screen tile's art was drawn")
    }

    // MARK: - Criterion 2: a far-field board costs exactly what an origin board costs

    func testFarFieldBoardBuildsNoMoreViewsThanTheSameBoardAtTheOrigin() {
        let rect = Self.viewport
        let originCells = BoardRender.cells(
            board: Self.board(),
            camera: Self.camera(framing: 0, 0),
            in: rect
        )
        let emptyCells = BoardRender.cells(
            board: Board(),
            camera: Self.camera(framing: 0, 0),
            in: rect
        )

        XCTAssertEqual(
            originCells.count, emptyCells.count,
            "an occupied board draws a different number of cells than an empty one"
        )

        for offset in [(row: 500, col: 500), (row: -500, col: -500), (row: 500, col: -500), (row: -500, col: 500)] {
            let farCells = BoardRender.cells(
                board: Self.board(offsetRow: offset.row, offsetCol: offset.col),
                camera: Self.camera(framing: offset.row, offset.col),
                in: rect
            )

            // "no more views" — the count is the view count.
            XCTAssertEqual(
                farCells.count, originCells.count,
                "a board at row/col \(offset) draws a different number of cells"
            )

            // ...and the tile-carrying entries match one for one, translated.
            let farTiles = farCells.filter { $0.tile != nil }
            let originTiles = originCells.filter { $0.tile != nil }
            XCTAssertEqual(farTiles.count, originTiles.count, "tile count differs at \(offset)")
            XCTAssertFalse(originTiles.isEmpty, "fixture draws no tiles at all")

            for (far, near) in zip(farTiles, originTiles) {
                XCTAssertEqual(far.coord.row - offset.row, near.coord.row, "row misaligned at \(offset)")
                XCTAssertEqual(far.coord.col - offset.col, near.coord.col, "col misaligned at \(offset)")
                XCTAssertEqual(far.point, near.point, "point misaligned at \(offset)")
                XCTAssertEqual(far.tile?.letter, near.tile?.letter, "letter misaligned at \(offset)")
                XCTAssertEqual(far.state, near.state, "state misaligned at \(offset)")
            }
        }
    }

    func testDrawListIsIndependentOfHowManyTilesTheBoardHolds() {
        let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)
        let rect = Self.viewport

        var crowded = Board()
        for row in 1000..<1100 {
            for col in 1000..<1010 {
                try? crowded.place(Tile(letter: "T"), at: Coord(row: row, col: col))
            }
        }
        XCTAssertEqual(crowded.placements.count, 1000)

        // Identical content, not merely identical count: nothing about a
        // thousand off-screen placements may reach the draw list.
        XCTAssertEqual(
            BoardRender.cells(board: crowded, camera: camera, in: rect),
            BoardRender.cells(board: Board(), camera: camera, in: rect),
            "off-screen placements changed the draw list"
        )
    }

    // MARK: - Criterion 3: a run of 2+ is .placed, a loose tile is .idle

    func testRunsReadPlacedAndLooseTilesReadIdle() {
        let camera = Self.camera(framing: 0, 0)
        let cells = BoardRender.cells(board: Self.board(), camera: camera, in: Self.viewport)

        // across run of four
        for col in 0...3 {
            XCTAssertEqual(cell(Coord(row: 0, col: col), in: cells)?.state, .placed, "across run at col \(col)")
        }
        // down run of two — two is already a run
        XCTAssertEqual(cell(Coord(row: 3, col: 0), in: cells)?.state, .placed, "down run head")
        XCTAssertEqual(cell(Coord(row: 4, col: 0), in: cells)?.state, .placed, "down run tail")
        // no orthogonal neighbor at all
        XCTAssertEqual(cell(Coord(row: 7, col: 10), in: cells)?.state, .idle, "lone tile is not idle")
        // only neighbor is diagonal — diagonals never connect tiles
        XCTAssertEqual(cell(Coord(row: 6, col: 5), in: cells)?.state, .idle, "diagonal pair read as a run")
        XCTAssertEqual(cell(Coord(row: 7, col: 6), in: cells)?.state, .idle, "diagonal pair read as a run")
    }

    func testRunsAndLooseTilesReadTheSameAtNegativeCoords() {
        let offset = (row: -500, col: -500)
        let camera = Self.camera(framing: offset.row, offset.col)
        let cells = BoardRender.cells(
            board: Self.board(offsetRow: offset.row, offsetCol: offset.col),
            camera: camera,
            in: Self.viewport
        )

        func at(_ row: Int, _ col: Int) -> BoardRender.TileState? {
            cell(Coord(row: row + offset.row, col: col + offset.col), in: cells)?.state
        }

        XCTAssertEqual(at(0, 0), .placed, "across run at row -500")
        XCTAssertEqual(at(0, 3), .placed, "across run tail at row -500")
        XCTAssertEqual(at(3, 0), .placed, "down run at row -500")
        XCTAssertEqual(at(4, 0), .placed, "down run at row -500")
        XCTAssertEqual(at(7, 10), .idle, "lone tile at negative coords is not idle")
        XCTAssertEqual(at(6, 5), .idle, "diagonal pair at negative coords read as a run")
        XCTAssertEqual(at(7, 6), .idle, "diagonal pair at negative coords read as a run")
    }

    // MARK: - Degenerate input degrades, never traps

    func testDegenerateRectsYieldAnEmptyDrawListWithoutTrapping() {
        let camera = BoardCamera(pan: CGSize(width: 13.5, height: -27.25), zoom: 1.25, baseCellSize: 48)
        let board = Self.board()

        // A GeometryReader's first layout pass really does report .zero.
        let degenerate: [(String, CGRect)] = [
            (".zero", .zero),
            ("nan origin", CGRect(x: CGFloat.nan, y: 0, width: 640, height: 480)),
            ("nan size", CGRect(x: 0, y: 0, width: CGFloat.nan, height: CGFloat(480))),
            ("infinite origin", CGRect(x: -CGFloat.infinity, y: 0, width: 640, height: 480)),
            ("infinite size", CGRect(x: 0, y: 0, width: CGFloat.infinity, height: CGFloat.infinity)),
            ("zero width", CGRect(x: 10, y: 10, width: 0, height: 480)),
        ]

        for (name, rect) in degenerate {
            XCTAssertTrue(
                BoardRender.cells(board: board, camera: camera, in: rect).isEmpty,
                "\(name) rect produced a draw list"
            )
        }
    }

    func testAnEmptyRectDrawsNothingWhateverTheSubCellPanIs() {
        // Same degenerate input, two different answers: the half-open range is
        // [floor(min), ceil(max) - 1], and for an empty rect that collapses to
        // an empty range only when the edge happens to land on a cell boundary.
        // A first layout pass must not depend on where the board was panned to.
        let board = Self.board()
        let onBoundary = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)
        let offBoundary = BoardCamera(pan: CGSize(width: 13.5, height: -27.25), zoom: 1, baseCellSize: 48)

        XCTAssertEqual(
            BoardRender.cells(board: board, camera: offBoundary, in: .zero).count,
            BoardRender.cells(board: board, camera: onBoundary, in: .zero).count,
            "an empty rect draws a different number of cells depending on sub-cell pan"
        )

        // Attribution: the draw list is the camera's range verbatim, so the
        // divergence is in `visibleCoords(in:)`, not in anything BoardRender adds.
        XCTAssertEqual(Array(offBoundary.visibleCoords(in: .zero)).count,
                       Array(onBoundary.visibleCoords(in: .zero)).count,
                       "BoardCamera.visibleCoords disagrees with itself on an empty rect")
    }

    func testNegativeSizeRectDegradesToTheMirroredRangeWithoutTrapping() {
        // CGRect.minX/maxX standardize, so a negative-size rect is a real
        // (mirrored) region rather than a trap. The requirement is that it does
        // not crash and adds no geometry of its own.
        let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)
        let rect = CGRect(x: 0, y: 0, width: -96, height: -96)

        let cells = BoardRender.cells(board: Self.board(), camera: camera, in: rect)
        XCTAssertEqual(cells.map(\.coord), Array(camera.visibleCoords(in: rect)))
        for entry in cells {
            XCTAssertEqual(entry.point, camera.point(for: entry.coord))
        }
    }

    // MARK: - Item 1's paired-rounding defect family

    func testEveryDrawnCellHitTestsBackToItself() {
        // Item 1 shipped `coord(at:)` and `visibleCoords(in:)` on one shared
        // rounding rule. If the draw list ever re-derived a point of its own, a
        // position inside a drawn cell would hit-test into a different cell.
        let camera = BoardCamera(pan: CGSize(width: 13.5, height: -27.25), zoom: 1.25, baseCellSize: 48)
        let size = camera.cellSize

        for framing in [(row: 0, col: 0), (row: -500, col: -500), (row: 500, col: -500)] {
            let framed = Self.camera(framing: framing.row, framing.col)
            let cells = BoardRender.cells(board: Board(), camera: framed, in: Self.viewport)
            XCTAssertFalse(cells.isEmpty)

            for entry in cells {
                let inside = [
                    CGPoint(x: entry.point.x + 0.01, y: entry.point.y + 0.01),
                    CGPoint(x: entry.point.x + framed.cellSize / 2, y: entry.point.y + framed.cellSize / 2),
                    CGPoint(x: entry.point.x + framed.cellSize - 0.01, y: entry.point.y + framed.cellSize - 0.01),
                ]
                for point in inside {
                    XCTAssertEqual(framed.coord(at: point), entry.coord, "hit test left the cell it was drawn in")
                }
            }
        }

        // ...and once more on a sub-cell pan, where the boundary is not on an
        // integer point.
        let cells = BoardRender.cells(board: Board(), camera: camera, in: Self.viewport)
        for entry in cells {
            XCTAssertEqual(camera.coord(at: CGPoint(x: entry.point.x + size / 2, y: entry.point.y + size / 2)), entry.coord)
        }
    }
}
