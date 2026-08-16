import XCTest
import Foundation
import CoreGraphics
import WillagramsRules

/// Where tiles arriving from outside land: the opening block a game starts on,
/// and the cells a Draw delivers into.
final class BoardLayoutTests: XCTestCase {

    // MARK: - Fixtures

    /// Landscape, real device point sizes.
    private let iPad = CGRect(x: 0, y: 0, width: 1366, height: 1024)
    private let iPhone = CGRect(x: 0, y: 0, width: 852, height: 393)

    /// A word list that holds nothing, so any run of two or more letters that
    /// formed would be reported invalid. Non-adjacent tiles form no runs at
    /// all, which is exactly what makes this the honest check.
    private let dictionary = EnableWordList(words: [])

    private func tiles(_ count: Int) -> [Tile] {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return (0..<count).map { Tile(letter: letters[$0 % letters.count]) }
    }

    private func assertNoneAdjacent(_ board: Board, _ label: String, line: UInt = #line) {
        for placement in board.placementList {
            for neighbor in placement.coord.neighbors {
                XCTAssertNil(
                    board.tile(at: neighbor),
                    "\(label): \(placement.coord) touches \(neighbor)",
                    line: line
                )
            }
        }
    }

    // MARK: - Opening

    /// The count is an input. Both values run the same checks, so a hardcoded
    /// 21 anywhere on the path fails at 13 while still passing at 21.
    private func assertOpening(_ count: Int, line: UInt = #line) {
        let handed = tiles(count)
        let board = BoardLayout.opening(handed)

        XCTAssertEqual(board.placementList.count, count, "opening \(count) landed a different number", line: line)
        XCTAssertEqual(
            Set(board.placementList.map(\.tile.id)), Set(handed.map(\.id)),
            "opening \(count) landed tiles other than the ones it was handed", line: line
        )
        assertNoneAdjacent(board, "opening \(count)", line: line)

        let validation = board.validate(against: dictionary)
        XCTAssertEqual(validation.tileCount, count, "opening \(count): tile count", line: line)
        XCTAssertEqual(validation.clusterCount, count, "opening \(count): tiles are joined up", line: line)
        XCTAssertEqual(validation.invalidWords, [], "opening \(count): a run of random letters formed", line: line)

        // Roughly three rows deep, and wrapped rather than run out in a line.
        XCTAssertEqual(
            Set(board.placementList.map(\.coord.row)).count, min(BoardLayout.openingRows, count),
            "opening \(count) is not \(BoardLayout.openingRows) rows deep", line: line
        )
    }

    func testOpeningOfTwentyOneLandsUnjoined() { assertOpening(21) }

    /// The different N. The starting count travels on the wire and is about to
    /// be configurable.
    func testOpeningOfADifferentCountLandsUnjoined() { assertOpening(13) }

    func testOpeningOfOneAndOfNoneAreBothWellFormed() {
        XCTAssertEqual(BoardLayout.opening(tiles(1)).placementList.count, 1)
        XCTAssertEqual(BoardLayout.opening([]).placementList.count, 0)
    }

    // MARK: - The initial camera

    /// Every opening tile is drawn strictly inside the viewport with clear
    /// space around the block, on both device shapes and at both counts.
    func testInitialCameraFramesEveryOpeningTileWithMargin() {
        for (name, rect) in [("iPad", iPad), ("iPhone", iPhone)] {
            for count in [21, 13] {
                let board = BoardLayout.opening(tiles(count))
                let camera = BoardLayout.framing(board, in: rect, camera: BoardCamera())
                let size = camera.cellSize
                let framed = rect.insetBy(dx: BoardLayout.openingMargin, dy: BoardLayout.openingMargin)

                for placement in board.placementList {
                    let point = camera.point(for: placement.coord)
                    let cell = CGRect(x: point.x, y: point.y, width: size, height: size)
                    XCTAssertTrue(
                        framed.contains(cell),
                        "\(name)/\(count): \(placement.coord) at \(cell) is not inside \(framed)"
                    )
                }
            }
        }
    }

    // MARK: - Draw landing

    /// Delivered tiles are visible without moving the camera.
    func testDeliveredTilesLandInsideTheViewportAndTouchNothing() {
        for (name, rect) in [("iPad", iPad), ("iPhone", iPhone)] {
            let camera = BoardCamera()
            let board = BoardLayout.opening(tiles(21))
            let before = Set(board.placementList.map(\.coord))
            let drawn = tiles(5)

            let next = BoardLayout.delivered(drawn, onto: board, camera: camera, in: rect)
            let landed = next.placementList.map(\.coord).filter { !before.contains($0) }

            XCTAssertEqual(next.placementList.count, before.count + drawn.count, "\(name): not every tile landed")
            XCTAssertEqual(landed.count, drawn.count, "\(name): landed count")
            assertNoneAdjacent(next, "\(name) delivery")

            let visible = Set(camera.visibleCoords(in: rect))
            for coord in landed {
                XCTAssertTrue(visible.contains(coord), "\(name): \(coord) landed outside the viewport")
            }
            // Below what the player was already looking at, not above it.
            let bottom = before.map(\.row).max()!
            for coord in landed {
                XCTAssertGreaterThan(coord.row, bottom, "\(name): \(coord) landed above the content")
            }
        }
    }

    /// The occupancy arm of the guardrail, on the viewport where it bites: a
    /// phone shows eight rows, so the rows a delivery reaches for next are
    /// already full and out of sight. Every tile must still land, over none of
    /// them, and `PlacementError.occupied` must not escape.
    ///
    /// The odd row at the bottom is the other arm. Tiles the player has
    /// dragged sit wherever they were dropped, not on the arrival lattice — so
    /// free is not enough, a cell has to be clear of its NEIGHBOURS too, or a
    /// vertical run of random letters forms under the delivery.
    func testDeliveryOntoOccupiedCellsBelowPlacesEveryTileAndTouchesNone() throws {
        var board = BoardLayout.opening(tiles(21))
        var occupied: [Coord: UUID] = [:]
        func plant(_ coord: Coord) throws {
            let tile = Tile(letter: "Z")
            try board.place(tile, at: coord)
            occupied[coord] = tile.id
        }
        // Full lattice rows straight below the phone's last visible row.
        for row in stride(from: 6, through: 20, by: BoardLayout.step) {
            for col in stride(from: 0, through: 16, by: BoardLayout.step) {
                try plant(Coord(row: row, col: col))
            }
        }
        // And an OFF-lattice row two below those, which no arriving tile may
        // come to rest against.
        for col in stride(from: 0, through: 16, by: BoardLayout.step) {
            try plant(Coord(row: 23, col: col))
        }
        let before = Set(board.placementList.map(\.coord))
        let drawn = tiles(9)

        let next = BoardLayout.delivered(drawn, onto: board, camera: BoardCamera(), in: iPhone)
        let landed = next.placementList.map(\.coord).filter { !before.contains($0) }

        XCTAssertEqual(next.placementList.count, before.count + drawn.count, "the delivery lost or doubled a tile")
        XCTAssertEqual(landed.count, drawn.count, "landed count")
        for (coord, id) in occupied {
            XCTAssertEqual(next.tile(at: coord)?.id, id, "the delivery wrote over the tile at \(coord)")
        }
        for tile in drawn {
            XCTAssertTrue(next.placementList.contains { $0.tile.id == tile.id }, "a drawn tile never landed")
        }
        for coord in landed {
            XCTAssertFalse(
                coord.neighbors.contains { occupied[$0] != nil },
                "\(coord) landed against a tile that was already there"
            )
        }
        assertNoneAdjacent(next, "delivery onto an occupied board")
        XCTAssertEqual(next.validate(against: dictionary).invalidWords, [], "a run of random letters formed")
    }

    /// Framed tight to the opening block there is no free row left on screen.
    /// The delivery carries on below the viewport rather than refusing.
    func testDeliveryContinuesBelowTheViewportWhenItIsExhausted() {
        let board = BoardLayout.opening(tiles(21))
        let camera = BoardLayout.framing(board, in: iPhone, camera: BoardCamera())
        let before = Set(board.placementList.map(\.coord))

        let next = BoardLayout.delivered(tiles(5), onto: board, camera: camera, in: iPhone)

        XCTAssertEqual(next.placementList.count, before.count + 5)
        assertNoneAdjacent(next, "delivery below an exhausted viewport")
    }

    /// A `GeometryReader` reports a zero-size rect on its first layout pass.
    /// The tiles still land somewhere free rather than going nowhere.
    func testDeliveryIntoADegenerateViewportStillPlacesEveryTile() {
        let board = BoardLayout.opening(tiles(21))
        let next = BoardLayout.delivered(tiles(4), onto: board, camera: BoardCamera(), in: .zero)
        XCTAssertEqual(next.placementList.count, board.placementList.count + 4)
        assertNoneAdjacent(next, "delivery into a degenerate viewport")
    }

    func testDeliveringNothingLeavesTheBoardAlone() {
        let board = BoardLayout.opening(tiles(21))
        XCTAssertEqual(BoardLayout.delivered([], onto: board, camera: BoardCamera(), in: iPad), board)
    }

    // MARK: - The session publishes both arrivals

    /// Built the way `BoardView` builds it — the cheap init, then the arrival —
    /// so what is checked here is the model the app actually runs.
    func testTheSessionPublishesTheOpeningAndTheDelivery() {
        var model = BoardModel(inputLocked: false)
        XCTAssertEqual(model.validation.tileCount, 0)

        let board = model.opening(tiles(21), against: dictionary)
        XCTAssertEqual(board.placementList.count, 21)
        XCTAssertEqual(model.validation.tileCount, 21, "the opening was not published")
        XCTAssertEqual(model.validation.clusterCount, 21)
        XCTAssertFalse(model.canDraw, "21 loose tiles read as a finished board")

        let next = model.delivered(tiles(5), onto: board, camera: BoardCamera(), in: iPad, against: dictionary)
        XCTAssertEqual(next.placementList.count, 26)
        XCTAssertEqual(model.validation.tileCount, 26, "the delivery was not published")
        XCTAssertEqual(model.validation.clusterCount, 26)
        XCTAssertEqual(model.validation.invalidWords, [])
    }

    /// A different count through the session too, since this is the layer the
    /// caller actually holds.
    func testTheSessionTakesTheCountFromItsInput() {
        var model = BoardModel(inputLocked: false)
        XCTAssertEqual(model.opening(tiles(30), against: dictionary).placementList.count, 30)
        XCTAssertEqual(model.validation.tileCount, 30)
    }

    // MARK: - There is no rack

    func testNoArrivalPathRoutesATileThroughAHand() throws {
        for name in ["BoardLayout.swift", "BoardModel.swift"] {
            let text = try String(
                contentsOf: BoardLayoutSource.boardDir.appendingPathComponent(name), encoding: .utf8
            )
            XCTAssertFalse(text.contains("GameState"), "\(name) reaches for GameState")
            XCTAssertFalse(text.contains(".hand"), "\(name) routes a tile through a rack")
        }
    }

    func testTheHandCheckHasTeeth() {
        XCTAssertTrue("state.hand.append(tile)".contains(".hand"))
        XCTAssertTrue("var state = GameState()".contains("GameState"))
        XCTAssertFalse("board.place(tile, at: coord)".contains(".hand"))
        XCTAssertFalse("board.place(tile, at: coord)".contains("GameState"))
    }

    func testTheAdjacencyCheckHasTeeth() throws {
        // A board that genuinely touches must read as touching, or every
        // non-adjacency assertion above is vacuous.
        var joined = Board()
        try joined.place(Tile(letter: "A"), at: Coord(row: 0, col: 0))
        try joined.place(Tile(letter: "B"), at: Coord(row: 0, col: 1))
        let touching = joined.placementList.contains { placement in
            placement.coord.neighbors.contains { joined.tile(at: $0) != nil }
        }
        XCTAssertTrue(touching, "the adjacency check cannot see an adjacent pair")

        let spaced = BoardLayout.opening(tiles(21))
        XCTAssertFalse(
            spaced.placementList.contains { p in p.coord.neighbors.contains { spaced.tile(at: $0) != nil } },
            "the opening block reads as touching"
        )
        XCTAssertEqual(joined.validate(against: dictionary).clusterCount, 1)
    }
}

private enum BoardLayoutSource {
    static let boardDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Cases
        .deletingLastPathComponent()   // BoardTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Willagrams/Board")
}
