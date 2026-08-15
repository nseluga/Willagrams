import XCTest
import Foundation
import CoreGraphics
import WillagramsRules

/// Records what a drag asked the hardware for, in order. A second copy of the
/// double rather than a shared one: `BoardDragTests` keeps its own private, and
/// a recorder is four lines.
private final class Recorder: BoardHaptics, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BoardHapticEvent] = []

    var events: [BoardHapticEvent] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func fire(_ event: BoardHapticEvent) {
        lock.lock(); defer { lock.unlock() }
        stored.append(event)
    }
}

/// The gate's own coverage for item 4, alongside the engineer's.
///
/// Every case here is one the engineer's suite does not execute: a second cell
/// size, the exact threshold boundary, a move across the coord zero line, a
/// refusal compared placement-by-placement and id-by-id, and the draw list read
/// AFTER a commit rather than only before one.
final class BoardDragGateTests: XCTestCase {

    // MARK: - Fixtures

    /// 48pt cells, so a whole cell step is a translation of 48.
    private static let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)
    /// 72pt cells — the OTHER end of the camera's clamp, so the threshold pair
    /// below is measured against a second cell size rather than one.
    private static let wide = BoardCamera(pan: .zero, zoom: 1.5, baseCellSize: 48)
    /// Mirrors `DesignTokens.Motion.snapThreshold`; `BoardSourceTests` pins that
    /// the view passes the real token.
    private static let threshold: CGFloat = 22
    private static let viewport = CGRect(x: 0, y: 0, width: 480, height: 320)

    private static func board(_ entries: [(Coord, Tile)]) -> Board {
        var board = Board()
        for (coord, tile) in entries { try? board.place(tile, at: coord) }
        return board
    }

    private func drag(
        _ origins: Set<Coord>,
        anchor: Coord,
        _ haptics: Recorder = Recorder()
    ) throws -> TileDrag {
        try XCTUnwrap(TileDrag(origins: origins, anchor: anchor, haptics: haptics))
    }

    // MARK: - Criterion 2 — the threshold boundary, at more than one cell size

    func testJustInsideAndJustOutsideTheThresholdAtASecondCellSize() throws {
        // 72pt cells: centres are 72 apart, so the numbers that straddle a 22pt
        // reach are different ones from the 48pt case. A drop measured against
        // a cell size baked in anywhere would only be right at one of the two.
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])
        let target = Coord(row: 0, col: 1)
        XCTAssertEqual(Self.wide.cellSize, 72, "fixture no longer exercises a second cell size")

        // Anchor centre starts at 36; +51 puts it at 87, which is 21 short of
        // the next centre at 108.
        let landed = try drag([home], anchor: home).drop(
            translation: CGSize(width: 51, height: 0),
            on: board, camera: Self.wide, threshold: Self.threshold
        )
        XCTAssertEqual(landed.tile(at: target)?.id, tile.id, "21pt is inside a 22pt reach at 72pt cells")

        // +49 leaves it 23 short.
        let refused = try drag([home], anchor: home).drop(
            translation: CGSize(width: 49, height: 0),
            on: board, camera: Self.wide, threshold: Self.threshold
        )
        XCTAssertEqual(refused, board, "23pt is outside a 22pt reach at 72pt cells")
    }

    func testAReachExactlyEqualToTheThresholdLands() throws {
        // The boundary itself, which neither "just inside" nor "just outside"
        // touches. 48pt cells, anchor centre 24 + 26 = 50, next centre 72,
        // reach exactly 22.
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])
        let translation = CGSize(width: 26, height: 0)

        let onTheLine = try drag([home], anchor: home).drop(
            translation: translation, on: board, camera: Self.camera, threshold: 22
        )
        XCTAssertEqual(onTheLine.tile(at: Coord(row: 0, col: 1))?.id, tile.id, "reach == threshold must land")

        // Teeth: the same translation against a hair-tighter reach must refuse,
        // or the assertion above is being carried by something other than the
        // threshold comparison.
        let justUnder = try drag([home], anchor: home).drop(
            translation: translation, on: board, camera: Self.camera, threshold: 21.9
        )
        XCTAssertEqual(justUnder, board)
    }

    func testAtTheCellSizeFloorTheThresholdCanNeverRefuseADistantDrop() throws {
        // Not a defect — the consequence of a threshold measured in POINTS
        // against cells that shrink. At the 24pt floor the furthest a release
        // can be from the centre of the cell it lands in is hypot(12, 12) ≈ 17pt,
        // which is inside a 22pt reach from every corner of every cell. So at
        // maximum zoom-out only an OCCUPIED destination refuses, never distance.
        // Pinned so the next person to touch the threshold sees it deliberately
        // rather than discovering it.
        let floored = BoardCamera(pan: .zero, zoom: 0.5, baseCellSize: 48)
        XCTAssertEqual(floored.cellSize, BoardCamera.minCellSize)

        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])

        // The worst case: a release at the far corner of a cell, both axes.
        for offset in [CGSize(width: 11.9, height: 11.9), CGSize(width: -11.9, height: -11.9)] {
            let after = try drag([home], anchor: home).drop(
                translation: offset, on: board, camera: floored, threshold: Self.threshold
            )
            XCTAssertEqual(after.placementList.count, 1)
            XCTAssertEqual(after.placementList.first?.tile.id, tile.id, "the tile was lost at the cell floor")
        }

        // Distance cannot refuse here, but an occupied destination still must.
        let blocked = Self.board([(home, tile), (Coord(row: 0, col: 1), Tile(letter: "B"))])
        let haptics = Recorder()
        let after = try drag([home], anchor: home, haptics).drop(
            translation: CGSize(width: 24, height: 0),
            on: blocked, camera: floored, threshold: Self.threshold
        )
        XCTAssertEqual(after.placementList, blocked.placementList)
        XCTAssertEqual(haptics.events, [.pickup, .reject])
    }

    func testTheDropMeasuresAgainstTheClampedCellSizeNotTheRawZoom() throws {
        // zoom 100 * 48pt base is 4800pt of cell, which `cellSize` clamps to 72.
        // Whichever number the drop measures against is decided here: one whole
        // CLAMPED cell lands, one whole UNCLAMPED cell does not.
        let clamped = BoardCamera(pan: .zero, zoom: 100, baseCellSize: 48)
        XCTAssertEqual(clamped.cellSize, 72)

        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])

        let byClampedCell = try drag([home], anchor: home).drop(
            translation: CGSize(width: 72, height: 0),
            on: board, camera: clamped, threshold: Self.threshold
        )
        XCTAssertEqual(byClampedCell.tile(at: Coord(row: 0, col: 1))?.id, tile.id)

        let byRawZoom = try drag([home], anchor: home).drop(
            translation: CGSize(width: 4800, height: 0),
            on: board, camera: clamped, threshold: Self.threshold
        )
        XCTAssertEqual(byRawZoom, board, "the drop measured against the unclamped zoom")
    }

    // MARK: - Criterion 2 — the unbounded lattice, across the zero line

    func testADragCrossesTheCoordZeroBoundaryInEveryDirection() throws {
        // `coord(at:)` floors rather than truncating precisely so row/col -1 and
        // 0 stay different cells. A drag that steps over that line either way is
        // the thing that notices if it ever stops.
        let cases: [(from: Coord, by: CGSize, to: Coord)] = [
            (Coord(row: 0, col: -1), CGSize(width: 48, height: 0), Coord(row: 0, col: 0)),
            (Coord(row: 0, col: 0), CGSize(width: -48, height: 0), Coord(row: 0, col: -1)),
            (Coord(row: -1, col: 0), CGSize(width: 0, height: 48), Coord(row: 0, col: 0)),
            (Coord(row: 0, col: 0), CGSize(width: 0, height: -48), Coord(row: -1, col: 0)),
            // Several cells at once, from negative to positive in one move.
            (Coord(row: -2, col: -2), CGSize(width: 144, height: 144), Coord(row: 1, col: 1)),
        ]

        for step in cases {
            let tile = Tile(letter: "A")
            let board = Self.board([(step.from, tile)])
            let haptics = Recorder()
            let after = try drag([step.from], anchor: step.from, haptics).drop(
                translation: step.by, on: board, camera: Self.camera, threshold: Self.threshold
            )
            XCTAssertEqual(
                after.tile(at: step.to)?.id, tile.id,
                "\(step.from) + \(step.by) did not land on \(step.to)"
            )
            XCTAssertNil(after.tile(at: step.from), "\(step.from) still holds the tile it gave up")
            XCTAssertEqual(after.placementList.count, 1)
            XCTAssertEqual(haptics.events, [.pickup, .snap])
        }
    }

    func testAnOccupiedDestinationIsRefusedAtNegativeCoordsToo() throws {
        let mover = Tile(letter: "A")
        let sitter = Tile(letter: "B")
        let home = Coord(row: -9, col: -9)
        let taken = Coord(row: -9, col: -8)
        let board = Self.board([(home, mover), (taken, sitter)])
        let before = board.placementList
        let haptics = Recorder()

        let after = try drag([home], anchor: home, haptics).drop(
            translation: CGSize(width: 48, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(after.placementList, before)
        XCTAssertEqual(after.tile(at: taken)?.id, sitter.id)
        XCTAssertEqual(after.tile(at: home)?.id, mover.id)
        XCTAssertEqual(haptics.events, [.pickup, .reject])
    }

    func testAFarButStillIndexableDropLandsRatherThanBeingRefused() throws {
        // The cell-proximity guard exists to refuse the unindexable fallback.
        // This pins that it does not ALSO refuse a legitimately distant cell —
        // the board is unbounded, and a 20-million-cell drop is a real drop.
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])
        let haptics = Recorder()

        let after = try drag([home], anchor: home, haptics).drop(
            translation: CGSize(width: 1e9, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertNotEqual(after, board, "a far but indexable drop was refused")
        XCTAssertNil(after.tile(at: home))
        XCTAssertEqual(after.placementList.count, 1)
        let landed = try XCTUnwrap(after.placementList.first)
        XCTAssertEqual(landed.tile.id, tile.id)
        XCTAssertEqual(landed.coord, Coord(row: 0, col: 20_833_333))
        XCTAssertEqual(haptics.events, [.pickup, .snap])
    }

    // MARK: - Criterion 3 — a refusal is identical placement-by-placement and id-by-id

    func testEveryRefusalLeavesTheWholePlacementListIdenticalElementForElement() throws {
        // A count check passes for a board that swapped two tiles' cells or
        // rebuilt one at the same coord. This compares the sorted list itself,
        // then the ids alone, then the raw dictionary.
        let mover = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let taken = Coord(row: 0, col: 1)
        let board = Self.board([
            (home, mover),
            (taken, Tile(letter: "B")),
            (Coord(row: -4, col: -4), Tile(letter: "C")),
            (Coord(row: 7, col: -2), Tile(letter: "D")),
            (Coord(row: -1, col: 6), Tile(letter: "E")),
        ])
        let before = board.placementList
        let beforeIDs = before.map(\.tileID)
        let beforeCoords = before.map(\.coord)

        let refusals: [(name: String, translation: CGSize, threshold: CGFloat)] = [
            ("onto an occupied cell", CGSize(width: 48, height: 0), Self.threshold),
            ("halfway between two centres", CGSize(width: 0, height: 24), Self.threshold),
            ("a non-finite translation", CGSize(width: CGFloat.nan, height: 0), Self.threshold),
            ("an unindexable translation", CGSize(width: 1e300, height: 1e300), Self.threshold),
            ("a generous reach onto the fallback", CGSize(width: 1e300, height: 0), .greatestFiniteMagnitude),
            ("a non-finite reach", CGSize(width: 48, height: 0), .nan),
        ]

        for refusal in refusals {
            let haptics = Recorder()
            let after = try drag([home], anchor: home, haptics).drop(
                translation: refusal.translation, on: board,
                camera: Self.camera, threshold: refusal.threshold
            )
            XCTAssertEqual(after, board, "\(refusal.name) changed the board")
            XCTAssertEqual(after.placementList, before, "\(refusal.name) changed a placement")
            XCTAssertEqual(after.placementList.map(\.tileID), beforeIDs, "\(refusal.name) changed a tile id")
            XCTAssertEqual(after.placementList.map(\.coord), beforeCoords, "\(refusal.name) moved a tile")
            XCTAssertEqual(after.placements, board.placements, "\(refusal.name) changed the dictionary")
            XCTAssertEqual(haptics.events, [.pickup, .reject], "\(refusal.name) fired the wrong feel")
        }
    }

    func testARefusedDropReturnsTheCallersOwnBoardEvenWhenTheAnchorIsNotWhereTheTileIs() throws {
        // A drag whose anchor holds no tile at all: `remove` answers nil and the
        // whole move has to unwind rather than placing a tile it never lifted.
        let board = Self.board([(Coord(row: 5, col: 5), Tile(letter: "A"))])
        let before = board.placementList
        let empty = Coord(row: 0, col: 0)
        let haptics = Recorder()

        let after = try drag([empty], anchor: empty, haptics).drop(
            translation: CGSize(width: 48, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(after.placementList, before)
        XCTAssertEqual(haptics.events, [.pickup, .reject])
    }

    func testAMoveThatFailsAfterLiftingATileNeverReachesTheCaller() throws {
        // The lane's hardest guardrail: never a remove that lands without its
        // matching place. This drag carries one real tile and one empty coord,
        // so BOTH destinations pass the free check and the failure happens
        // AFTER the real tile has already been lifted off the working copy.
        // The caller must still get its own board back, byte for byte.
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let phantom = Coord(row: 2, col: 2)
        let board = Self.board([(home, tile)])
        let before = board.placementList
        XCTAssertNil(board.tile(at: phantom), "the fixture needs the second origin empty")
        let haptics = Recorder()

        let after = try drag([home, phantom], anchor: home, haptics).drop(
            translation: CGSize(width: 48, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )

        XCTAssertEqual(after, board, "a half-finished move escaped to the caller")
        XCTAssertEqual(after.placementList, before)
        XCTAssertEqual(after.tile(at: home)?.id, tile.id, "the lifted tile was never put back")
        XCTAssertNil(after.tile(at: Coord(row: 0, col: 1)), "the lifted tile landed anyway")
        XCTAssertNil(after.tile(at: Coord(row: 2, col: 3)), "a tile that never existed was placed")
        XCTAssertEqual(after.placementList.count, 1)
        XCTAssertEqual(haptics.events, [.pickup, .reject])
    }

    // MARK: - Criterion 4 — exactly one of each, and none of the others

    func testARefusedDragFiresNoSnapAndALandedDragFiresNoReject() throws {
        let mover = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, mover), (Coord(row: 0, col: 1), Tile(letter: "B"))])

        // Landed: exactly one pickup, exactly one snap, zero rejects.
        let landed = Recorder()
        _ = try drag([home], anchor: home, landed).drop(
            translation: CGSize(width: 0, height: 48),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(landed.events.filter { $0 == .pickup }.count, 1)
        XCTAssertEqual(landed.events.filter { $0 == .snap }.count, 1)
        XCTAssertEqual(landed.events.filter { $0 == .reject }.count, 0, "a landed drag fired a reject")
        XCTAssertEqual(landed.events.count, 2)

        // Refused: exactly one pickup, exactly one reject, zero snaps.
        let refused = Recorder()
        _ = try drag([home], anchor: home, refused).drop(
            translation: CGSize(width: 48, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(refused.events.filter { $0 == .pickup }.count, 1)
        XCTAssertEqual(refused.events.filter { $0 == .reject }.count, 1)
        XCTAssertEqual(refused.events.filter { $0 == .snap }.count, 0, "a refused drag fired a snap")
        XCTAssertEqual(refused.events.count, 2)
    }

    func testAFingerThatWandersAndComesBackCommitsOnlyTheFinalTranslation() throws {
        // 128 frames out to +127pt — two whole cells past the neighbour — and
        // back to zero, then release. Only the LAST translation may decide
        // anything: no frame in between commits, and no running total survives.
        // The check is the resulting board and the event list, not an
        // arithmetic round trip, so an implementation that accumulated would
        // land the tile two cells over and fail here.
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])
        let haptics = Recorder()
        let inFlight = try drag([home], anchor: home, haptics)

        var lastWidth: CGFloat = 0
        for step in 0..<128 {
            lastWidth = step < 64 ? CGFloat(step) : CGFloat(127 - step)
            _ = BoardRender.cells(
                board: board, camera: Self.camera, in: Self.viewport,
                dragging: inFlight.origins, by: CGSize(width: lastWidth, height: 0)
            )
        }
        XCTAssertEqual(lastWidth, 0, "the finger did not return to where it started")
        XCTAssertEqual(haptics.events, [.pickup], "rendering a frame fired a feel")

        let after = inFlight.drop(
            translation: CGSize(width: lastWidth, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(after.tile(at: home)?.id, tile.id, "a mid-drag frame moved the tile")
        XCTAssertNil(after.tile(at: Coord(row: 0, col: 1)), "the drag accumulated the frames it passed through")
        XCTAssertNil(after.tile(at: Coord(row: 0, col: 2)))
        XCTAssertEqual(after.placementList, board.placementList)
        XCTAssertEqual(haptics.events, [.pickup, .snap])
    }

    // MARK: - No cumulative state hides behind the drag

    func testTheDropIsAPureFunctionOfTheTranslationItIsHanded() throws {
        // `DragGesture` reports a translation cumulative from its own start, so
        // the drag must hold NO running total of its own. Five identical drops
        // that walked the tile further each time would be exactly that bug.
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])
        let inFlight = try drag([home], anchor: home)
        let translation = CGSize(width: 48, height: 0)

        let first = inFlight.drop(
            translation: translation, on: board, camera: Self.camera, threshold: Self.threshold
        )
        for _ in 0..<5 {
            let again = inFlight.drop(
                translation: translation, on: board, camera: Self.camera, threshold: Self.threshold
            )
            XCTAssertEqual(again, first, "the drag accumulated state across drops")
            XCTAssertEqual(again.tile(at: Coord(row: 0, col: 1))?.id, tile.id)
        }

        // And a zero translation afterwards still means "stay put", not
        // "wherever the last drop left it".
        let stayed = inFlight.drop(
            translation: .zero, on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(stayed, board)
    }

    // MARK: - Criterion 1 — the draw list AFTER the commit, not only before it

    func testTheCommittedTileDrawsAtItsNewCellAndTheOldCellIsEmptyAgain() throws {
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let target = Coord(row: 0, col: 1)
        let board = Self.board([(home, tile)])
        let inFlight = try drag([home], anchor: home)

        let after = inFlight.drop(
            translation: CGSize(width: 48, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        // The view clears its drag set in `onEnded`, so the post-commit draw
        // list is the default one.
        let cells = BoardRender.cells(board: after, camera: Self.camera, in: Self.viewport)

        let vacated = try XCTUnwrap(cells.first { $0.coord == home })
        XCTAssertNil(vacated.tile)
        XCTAssertNil(vacated.state)
        XCTAssertNil(vacated.tilePoint)

        let landed = try XCTUnwrap(cells.first { $0.coord == target })
        XCTAssertEqual(landed.tile?.id, tile.id)
        XCTAssertEqual(landed.state, .idle, "a lone landed tile must revert to .idle, not stay .selected")
        XCTAssertEqual(landed.tilePoint, landed.point, "the landed tile is still drawn lifted")
        XCTAssertEqual(landed.point, Self.camera.point(for: target))
    }

    func testACommittedTileThatLandsBesideAnotherRevertsToPlaced() throws {
        let mover = Tile(letter: "A")
        let sitter = Tile(letter: "B")
        let home = Coord(row: 0, col: 0)
        let target = Coord(row: 0, col: 1)
        let board = Self.board([(home, mover), (Coord(row: 0, col: 2), sitter)])

        let after = try drag([home], anchor: home).drop(
            translation: CGSize(width: 48, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        let cells = BoardRender.cells(board: after, camera: Self.camera, in: Self.viewport)
        XCTAssertEqual(cells.first { $0.coord == target }?.state, .placed)
        XCTAssertEqual(cells.first { $0.coord == Coord(row: 0, col: 2) }?.state, .placed)
        XCTAssertEqual(cells.first { $0.coord == home }?.state, nil)
    }

    func testARefusedDragAlsoRevertsTheDrawStateAndTheTilePoint() throws {
        // The refusal path has to revert too — the engineer's suite reads the
        // post-release draw list only after a drop that changed nothing.
        let mover = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let taken = Coord(row: 0, col: 1)
        let board = Self.board([(home, mover), (taken, Tile(letter: "B"))])
        let inFlight = try drag([home], anchor: home)

        let lifted = BoardRender.cells(
            board: board, camera: Self.camera, in: Self.viewport,
            dragging: inFlight.origins, by: CGSize(width: 44, height: 0)
        )
        let carried = try XCTUnwrap(lifted.first { $0.coord == home })
        XCTAssertEqual(carried.state, .selected)
        XCTAssertEqual(carried.tilePoint?.x, carried.point.x + 44)

        let after = inFlight.drop(
            translation: CGSize(width: 48, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(after, board)
        let released = BoardRender.cells(board: after, camera: Self.camera, in: Self.viewport)
        let home_ = try XCTUnwrap(released.first { $0.coord == home })
        XCTAssertEqual(home_.state, .placed, "the returned tile is still reading .selected")
        XCTAssertEqual(home_.tilePoint, home_.point, "the returned tile is still drawn lifted")
        XCTAssertEqual(home_.tile?.id, mover.id)
    }
}

/// Structural checks the drag's correctness rests on but no runtime assertion
/// can reach.
final class BoardDragStructureTests: XCTestCase {

    private static let boardDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Cases
        .deletingLastPathComponent()   // BoardTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Willagrams/Board")

    private func source(_ name: String) throws -> String {
        try String(contentsOf: Self.boardDir.appendingPathComponent(name), encoding: .utf8)
    }

    /// Strips `//` and `/* */` so a term used in prose is not read as code.
    private static func code(_ source: String) -> String {
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
            if c == "/" && next == "/" { while i < chars.count && chars[i] != "\n" { i += 1 }; continue }
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

    func testTheDragDerivesNoCellIndexOfItsOwn() throws {
        // `BoardCamera.coord(at:)` and `point(for:)` are one paired rounding
        // convention. A second "which cell is this" here would be free to
        // disagree with them at a cell edge, and the two would drift apart the
        // first time either is touched.
        let text = Self.code(try source("BoardDrag.swift"))
        for derivation in ["floor(", "ceil(", ".rounded(", "Int(", "truncatingRemainder"] {
            XCTAssertFalse(
                text.contains(derivation),
                "BoardDrag derives a cell index with \(derivation) instead of routing through BoardCamera"
            )
        }
        XCTAssertTrue(text.contains("camera.coord(at:"), "the drag does not route through coord(at:)")
        XCTAssertTrue(text.contains("camera.point(for:"), "the drag does not route through point(for:)")
        XCTAssertTrue(text.contains("camera.cellSize"), "the drag does not read the clamped cell size")
    }

    func testTheDragTranslationIsAssignedRatherThanAccumulated() throws {
        // `DragGesture.translation` is ALREADY cumulative from the gesture's
        // start. Adding to a stored copy would double-count every frame, and the
        // render clamp would hide it until the release read the runaway total.
        //
        // The stored translation now lives in `BoardModel` rather than in the
        // view. Same rule, pinned at both ends of the hand-off: the view passes
        // the gesture's own cumulative value straight through, and the model
        // ASSIGNS what it was passed.
        let view = Self.code(try source("BoardView.swift"))
        XCTAssertTrue(
            view.contains("model.moved(to: value.translation)"),
            "BoardView no longer hands the gesture's own cumulative translation to the session"
        )
        let model = Self.code(try source("BoardModel.swift"))
        XCTAssertTrue(
            model.contains("dragTranslation = translation"),
            "BoardModel no longer assigns the cumulative translation it was handed"
        )
        for accumulation in ["dragTranslation +=", "dragTranslation = dragTranslation", "dragTranslation.width +="] {
            XCTAssertFalse(view.contains(accumulation), "BoardView accumulates via \(accumulation)")
            XCTAssertFalse(model.contains(accumulation), "BoardModel accumulates via \(accumulation)")
        }
        XCTAssertTrue(model.contains("dragTranslation = .zero"), "BoardModel never resets the translation on release")
    }

    func testTheStructuralChecksHaveTeeth() {
        // Each predicate has to separate the shipped shape from the shape it
        // exists to catch, or the two tests above pass against anything.
        let reDerived = "let col = Int(floor((dropped.x - pan.width) / size))"
        XCTAssertTrue(reDerived.contains("floor("))
        XCTAssertTrue(reDerived.contains("Int("))
        XCTAssertFalse("let target = camera.coord(at: dropped)".contains("floor("))
        XCTAssertTrue("let target = camera.coord(at: dropped)".contains("camera.coord(at:"))

        let accumulated = "dragTranslation += translation"
        XCTAssertTrue(accumulated.contains("dragTranslation +="))
        XCTAssertFalse(accumulated.contains("dragTranslation = translation"))
        let assigned = "dragTranslation = translation"
        XCTAssertFalse(assigned.contains("dragTranslation +="))
        XCTAssertTrue(assigned.contains("dragTranslation = translation"))

        // And the view half: a body that drops the translation on the floor, or
        // one that hands over a value of its own making, must both read as
        // unpinned against one that forwards the gesture's own.
        XCTAssertFalse("model.moved(to: .zero)".contains("model.moved(to: value.translation)"))
        XCTAssertFalse("camera = inFlight.camera(camera, translatedBy: value.translation)".contains("model.moved(to: value.translation)"))
        XCTAssertTrue("model.moved(to: value.translation)".contains("model.moved(to: value.translation)"))

        // And the comment stripper must actually strip, or a term named only in
        // prose reads as code and every check above fires on documentation.
        XCTAssertFalse(Self.code("// floor(x)\nlet t = camera.coord(at: p)").contains("floor("))
        XCTAssertTrue(Self.code("/// prose\nlet c = Int(floor(v))").contains("floor("))
    }

    func testTheSelectedStateIsWhatActuallyAppliesTheLiftToken() throws {
        // Criterion 1's last link. The pure layer reports `.selected`, the view
        // maps it onto `BrandTile.State.selected`, and BRANDTILE is what turns
        // that into the `Motion.tileLift` offset. Nothing else in the chain may
        // name the token, so if BrandTile stopped applying it a touched tile
        // would read selected and never rise, with every other test still green.
        let brandTile = Self.boardDir
            .deletingLastPathComponent()          // Willagrams
            .appendingPathComponent("Style/BrandTile.swift")
        let text = Self.code(try String(contentsOf: brandTile, encoding: .utf8))
        XCTAssertTrue(
            text.contains("DesignTokens.Motion.tileLift"),
            "BrandTile no longer applies the lift token, so a selected tile never rises"
        )
        XCTAssertTrue(
            text.contains("state == .selected ? DesignTokens.Motion.tileLift"),
            "BrandTile applies the lift somewhere other than the .selected state"
        )
        // And the lift is a token, never a number written out here.
        XCTAssertTrue(Self.code("let o = state == .selected ? DesignTokens.Motion.tileLift : 0")
            .contains("state == .selected ? DesignTokens.Motion.tileLift"))
        XCTAssertFalse(Self.code("let o = state == .selected ? -8 : 0")
            .contains("state == .selected ? DesignTokens.Motion.tileLift"))
    }

    func testTheDragSourceIsASymlinkAndNotASecondCopy() throws {
        // A copied file drifts silently: the package would keep compiling and
        // testing yesterday's logic while the app shipped today's.
        let link = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("BoardDrag.swift")
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(
            attributes[.type] as? FileAttributeType, .typeSymbolicLink,
            "Tests/BoardTests/Cases/BoardDrag.swift is a copy, not a symlink to the app source"
        )
        XCTAssertEqual(
            link.resolvingSymlinksInPath().standardizedFileURL,
            Self.boardDir.appendingPathComponent("BoardDrag.swift")
                .resolvingSymlinksInPath().standardizedFileURL
        )
    }
}
