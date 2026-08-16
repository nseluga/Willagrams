import XCTest
import Foundation
import CoreGraphics
import WillagramsRules

/// Records what a drag asked the hardware for, in order.
private final class RecordedHaptics: BoardHaptics, @unchecked Sendable {
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

/// Multi-tile selection: entering the mode, painting a set by sweeping, moving
/// the whole set as one, and getting back out again.
///
/// Every decision under test is pure, so these execute it rather than reading it
/// as text. The SwiftUI half — a double tap entering the mode, a sweep reaching
/// `painting` — is pinned in `BoardSourceTests`.
final class BoardSelectionTests: XCTestCase {

    // MARK: - Fixtures

    /// 48pt cells at the origin: cell (r, c) has its corner at (48c, 48r) and
    /// its centre 24 in from that, so a whole-cell step is a translation of 48.
    private static let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)

    /// Mirrors `DesignTokens.Motion.snapThreshold`, which is unreachable from
    /// this host-side package and is a `commit` parameter for that reason.
    /// Wide enough to accept any release inside a cell, matching the real
    /// `snapThreshold`. At the old 22 these moves were a coin flip: a drag
    /// measured from the tile's DRAWN position carries its scatter as the
    /// residual, up to ~27pt, and anything above the threshold was refused.
    private static let threshold: CGFloat = 96

    private static let viewport = CGRect(x: 0, y: 0, width: 480, height: 320)

    private static let dictionary = EnableWordList(words: ["OX", "ON"])

    /// The centre of a cell, which is where a finger that means to be on a tile
    /// lands.
    private func centre(_ coord: Coord) -> CGPoint {
        let point = Self.camera.point(for: coord)
        let half = Self.camera.cellSize / 2
        return CGPoint(x: point.x + half, y: point.y + half)
    }

    private func board(_ coords: [Coord]) -> Board {
        var board = Board()
        for (offset, coord) in coords.enumerated() {
            let letters = Array("ABCDEFGHIJKLMNOP")
            try? board.place(Tile(letter: letters[offset % letters.count]), at: coord)
        }
        return board
    }

    /// A model already in selection mode, having swept `path` — the same calls
    /// the view makes: one `began` on the decided grab, then one `painting` per
    /// reported position, from the touch-down point.
    private func swept(
        _ path: [CGPoint],
        on board: Board,
        locked: Bool = false
    ) -> BoardModel {
        var model = BoardModel(inputLocked: locked)
        model.enterSelection()
        sweep(&model, path, on: board)
        return model
    }

    private func sweep(_ model: inout BoardModel, _ path: [CGPoint], on board: Board) {
        guard let start = path.first else { return }
        let grab = BoardGesture.Drag(
            at: start, in: board, selection: model.selection,
            camera: Self.camera, inputLocked: model.inputLocked
        ).grab
        model.began(grab, haptics: RecordedHaptics())
        for point in path {
            model.painting(from: start, to: point, on: board, camera: Self.camera)
        }
    }

    /// Every pairwise (row, col) offset inside a set, which is the shape of the
    /// selection with its position taken out.
    private func shape(_ coords: Set<Coord>) -> Set<[Int]> {
        var offsets: Set<[Int]> = []
        for one in coords {
            for other in coords {
                offsets.insert([one.row - other.row, one.col - other.col])
            }
        }
        return offsets
    }

    /// Which coords `BoardRender` would draw `.selected`.
    private func rendersSelected(_ model: BoardModel, on board: Board) -> Set<Coord> {
        Set(
            BoardRender.cells(
                board: board, camera: Self.camera, in: Self.viewport,
                dragging: model.selected, by: model.dragTranslation
            )
            .filter { $0.state == .selected }
            .map(\.coord)
        )
    }

    // MARK: - Criterion 1 — a sweep paints exactly the tiles it crosses

    func testASweepPaintsExactlyTheTilesItCrossesAndTheyRenderSelected() throws {
        // Three in a row swept, a fourth in the same row left alone, and one
        // off the path entirely.
        let painted = [Coord(row: 0, col: 0), Coord(row: 0, col: 1), Coord(row: 0, col: 2)]
        let board = board(painted + [Coord(row: 0, col: 5), Coord(row: 4, col: 4)])

        let model = swept([centre(painted[0]), centre(painted[2])], on: board)

        XCTAssertTrue(model.selection.isActive, "the sweep left selection mode")
        XCTAssertEqual(model.selection.coords, Set(painted), "the sweep did not paint exactly what it crossed")
        XCTAssertEqual(rendersSelected(model, on: board), Set(painted), "the painted tiles do not render selected")
    }

    /// The same criterion at a different N and a different shape, so a
    /// hardcoded count or a row-only walk cannot pass it.
    func testASweepOfADifferentSizeAndShapePaintsExactlyWhatItCrosses() throws {
        let column = (0...4).map { Coord(row: $0, col: 3) }
        let elbow = [Coord(row: 4, col: 4), Coord(row: 4, col: 5)]
        let board = board(column + elbow + [Coord(row: 0, col: 0), Coord(row: 2, col: 7)])

        // Down the column, then right along the elbow: two reported positions
        // for a path that is not a straight line.
        let model = swept(
            [centre(column[0]), centre(column[4]), centre(elbow[1])],
            on: board
        )

        XCTAssertEqual(model.selection.coords.count, 7, "the L-shaped sweep painted \(model.selection.coords.count) tiles")
        XCTAssertEqual(model.selection.coords, Set(column + elbow), "the sweep did not paint exactly what it crossed")
        XCTAssertEqual(rendersSelected(model, on: board), Set(column + elbow))
    }

    func testAFingerThatJumpsAWholeRowInOneFrameStillPaintsTheTilesBetween() throws {
        // One reported position per gesture is all SwiftUI promises. The tiles
        // between two positions are crossed whether or not a frame landed on
        // them.
        let row = (0...6).map { Coord(row: 2, col: $0) }
        let board = board(row)
        let model = swept([centre(row[0]), centre(row[6])], on: board)
        XCTAssertEqual(model.selection.coords, Set(row), "the tiles between two reported positions were skipped")
    }

    func testNothingIsPaintedWithoutEnteringSelectionModeFirst() throws {
        let row = (0...2).map { Coord(row: 0, col: $0) }
        let board = board(row)

        var model = BoardModel()
        sweep(&model, [centre(row[0]), centre(row[2])], on: board)

        XCTAssertTrue(model.selection.isEmpty, "an ordinary drag painted a selection")
        XCTAssertFalse(model.selection.isActive)
        // The one tile it took hold of reads selected, and nothing else does.
        XCTAssertEqual(model.dragging, [row[0]], "the fixture took hold of nothing, so it proves nothing")
        XCTAssertEqual(rendersSelected(model, on: board), [row[0]],
                       "an ordinary drag renders more than the tile it holds selected")
    }

    // MARK: - Guardrail — painting is view state, the board is untouched

    func testPaintingLeavesTheBoardExactlyAsItWas() throws {
        let row = (0...3).map { Coord(row: 1, col: $0) }
        var board = board(row)
        let before = board.placementList

        let model = swept([centre(row[0]), centre(row[3])], on: board)

        XCTAssertEqual(board.placementList, before, "painting a selection changed the board")
        XCTAssertEqual(model.selection.coords, Set(row), "the fixture painted nothing, so it proves nothing")
        // And the same sweep run twice over, in case a write only lands on a
        // repeat pass.
        _ = swept([centre(row[3]), centre(row[0])], on: board)
        XCTAssertEqual(board.placementList, before, "painting a selection changed the board")
    }

    // MARK: - Criterion 2 — a group move carries every tile, offsets intact

    func testDraggingOneSelectedTileMovesTheWholeSelectionKeepingEveryOffset() throws {
        let row = (0...2).map { Coord(row: 0, col: $0) }
        var board = board(row)
        let ids = row.map { board.tile(at: $0)?.id }
        XCTAssertEqual(ids.compactMap { $0 }.count, row.count, "the fixture placed no tiles")

        var model = swept([centre(row[0]), centre(row[2])], on: board)
        let before = model.selection.coords

        // Take hold of the middle tile — not the one the sweep started on — and
        // move the whole set two cells down and one right.
        let anchor = row[1]
        let grab = BoardGesture.Drag(
            at: centre(anchor), in: board, selection: model.selection, camera: Self.camera
        ).grab
        model.began(grab, haptics: RecordedHaptics())
        XCTAssertEqual(model.dragging, before, "the hold carries something other than the whole selection")

        let travel = CGSize(width: Self.camera.cellSize, height: Self.camera.cellSize * 2)
        board = model.commit(
            translation: travel, on: board, camera: Self.camera,
            threshold: Self.threshold, against: Self.dictionary
        )

        let landed = Set(board.placementList.map(\.coord))
        XCTAssertEqual(landed, Set(row.map { Coord(row: $0.row + 2, col: $0.col + 1) }),
                       "the selection did not land where the finger took it")
        XCTAssertEqual(shape(landed), shape(before), "the tiles did not keep their offsets from each other")
        // The same tiles, not rebuilt ones, each at its own new cell.
        for (offset, coord) in row.enumerated() {
            let moved = Coord(row: coord.row + 2, col: coord.col + 1)
            XCTAssertEqual(board.tile(at: moved)?.id, ids[offset], "the tile from \(coord) is not the one at \(moved)")
        }
        XCTAssertEqual(model.selection.coords, landed, "the selection did not follow the tiles it moved")
    }

    /// The same criterion at a different selection size and a different shape.
    func testAGroupMoveOfADifferentSizeAndShapeKeepsEveryOffset() throws {
        let elbow = [
            Coord(row: 0, col: 0), Coord(row: 1, col: 0),
            Coord(row: 2, col: 0), Coord(row: 2, col: 1), Coord(row: 2, col: 2),
        ]
        var board = board(elbow)
        var model = swept(
            [centre(elbow[0]), centre(elbow[2]), centre(elbow[4])],
            on: board
        )
        XCTAssertEqual(model.selection.coords, Set(elbow), "the fixture did not paint the whole shape")
        let before = model.selection.coords

        let anchor = elbow[4]
        let grab = BoardGesture.Drag(
            at: centre(anchor), in: board, selection: model.selection, camera: Self.camera
        ).grab
        model.began(grab, haptics: RecordedHaptics())
        board = model.commit(
            translation: CGSize(width: Self.camera.cellSize * 3, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )

        let landed = Set(board.placementList.map(\.coord))
        XCTAssertEqual(landed.count, 5, "the move landed \(landed.count) of 5 tiles")
        XCTAssertEqual(landed, Set(elbow.map { Coord(row: $0.row, col: $0.col + 3) }))
        XCTAssertEqual(shape(landed), shape(before), "the tiles did not keep their offsets from each other")
    }

    // MARK: - Guardrail — a group move is all or nothing

    func testAGroupMoveOntoANonSelectedTileLeavesTheBoardUntouched() throws {
        let row = [Coord(row: 0, col: 0), Coord(row: 0, col: 1), Coord(row: 0, col: 2)]
        // The blocker sits under the MIDDLE tile's destination, so the outer two
        // would both fit — a partial commit lands them and leaves this one.
        let blocker = Coord(row: 1, col: 1)
        var board = board(row + [blocker])
        let before = board.placementList

        var model = swept([centre(row[0]), centre(row[2])], on: board)
        XCTAssertEqual(model.selection.coords, Set(row), "the blocker was swept up with the row")

        let haptics = RecordedHaptics()
        let grab = BoardGesture.Drag(
            at: centre(row[0]), in: board, selection: model.selection, camera: Self.camera
        ).grab
        model.began(grab, haptics: haptics)
        board = model.commit(
            translation: CGSize(width: 0, height: Self.camera.cellSize),
            on: board, camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )

        XCTAssertEqual(board.placementList, before, "the refused group move changed the board")
        XCTAssertEqual(haptics.events, [.pickup, .reject], "the refused group move was not felt as a refusal")
        XCTAssertEqual(model.selection.coords, Set(row), "the selection followed a move that never happened")
    }

    /// The same guardrail with the blocker under an END of the selection and at
    /// a different size, so a partial commit has a different tile to leave
    /// behind.
    func testAGroupMoveBlockedAtItsFarEndLeavesTheBoardUntouched() throws {
        let column = (0...3).map { Coord(row: $0, col: 2) }
        let blocker = Coord(row: 4, col: 2)
        var board = board(column + [blocker])
        let before = board.placementList

        var model = swept([centre(column[0]), centre(column[3])], on: board)
        let grab = BoardGesture.Drag(
            at: centre(column[1]), in: board, selection: model.selection, camera: Self.camera
        ).grab
        model.began(grab, haptics: RecordedHaptics())
        board = model.commit(
            translation: CGSize(width: 0, height: Self.camera.cellSize),
            on: board, camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )

        XCTAssertEqual(board.placementList, before, "the refused group move changed the board")
        XCTAssertEqual(board.placementList.count, 5, "a tile went missing on a refused move")
    }

    func testAGroupMoveOverItsOwnCellsIsAcceptedRatherThanReadAsACollision() throws {
        // The selection sliding one cell along its own row: two of the three
        // destinations are cells the selection itself is standing on.
        let row = (0...2).map { Coord(row: 0, col: $0) }
        var board = board(row)
        var model = swept([centre(row[0]), centre(row[2])], on: board)
        let grab = BoardGesture.Drag(
            at: centre(row[0]), in: board, selection: model.selection, camera: Self.camera
        ).grab
        model.began(grab, haptics: RecordedHaptics())
        board = model.commit(
            translation: CGSize(width: Self.camera.cellSize, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )
        XCTAssertEqual(Set(board.placementList.map(\.coord)), Set(row.map { Coord(row: 0, col: $0.col + 1) }),
                       "a selection sliding along its own row was refused as a collision")
    }

    // MARK: - Criterion 3 — tapping empty space is the way out

    func testTappingEmptySpaceClearsTheSelectionAndRestoresPanningAndSingleDragging() throws {
        let row = (0...2).map { Coord(row: 0, col: $0) }
        var board = board(row)
        let before = board.placementList

        var model = swept([centre(row[0]), centre(row[2])], on: board)
        XCTAssertFalse(model.selection.isEmpty, "the fixture swept nothing, so the escape proves nothing")

        // A tap: one touch-down on an empty cell, one reported position, one
        // release. No tile is moved to get out.
        let empty = centre(Coord(row: 6, col: 6))
        sweep(&model, [empty], on: board)
        model.endedPainting()

        XCTAssertTrue(model.selection.isEmpty, "the tap left tiles selected")
        XCTAssertFalse(model.selection.isActive, "the tap left the player in selection mode")
        XCTAssertEqual(board.placementList, before, "getting out of selection mode moved a tile")
        XCTAssertEqual(rendersSelected(model, on: board), [], "cleared tiles still render selected")

        // And ordinary handling is back: empty space pans, a tile is held on
        // its own.
        let pan = BoardGesture.Drag(
            at: empty, in: board, selection: model.selection, camera: Self.camera
        )
        XCTAssertEqual(pan.grab, .pan, "empty space no longer pans")
        let moved = pan.camera(Self.camera, translatedBy: CGSize(width: 30, height: 12))
        XCTAssertEqual(moved.pan, CGSize(width: 30, height: 12), "the pan no longer moves the camera")

        let hold = BoardGesture.Drag(
            at: centre(row[1]), in: board, selection: model.selection, camera: Self.camera
        )
        model.began(hold.grab, haptics: RecordedHaptics())
        XCTAssertEqual(model.dragging, [row[1]], "a tile is no longer held on its own")
        board = model.commit(
            translation: CGSize(width: 0, height: Self.camera.cellSize * 2),
            on: board, camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )
        XCTAssertEqual(board.tile(at: Coord(row: 2, col: 1))?.letter, "B", "the single-tile move did not land")
        XCTAssertEqual(board.placementList.count, 3, "the single-tile move took its neighbours with it")
    }

    func testASweepBackOverTilesAlreadySelectedDoesNotReadAsATap() throws {
        // Crossed, not newly added: a second pass over the same tiles adds
        // nothing to the set and must still not be mistaken for a tap.
        let row = (0...2).map { Coord(row: 0, col: $0) }
        let board = board(row)
        var model = swept([centre(row[0]), centre(row[2])], on: board)
        model.endedPainting()

        sweep(&model, [centre(row[2]), centre(row[0])], on: board)
        model.endedPainting()

        XCTAssertEqual(model.selection.coords, Set(row), "a second pass over the selection cleared it")
        XCTAssertTrue(model.selection.isActive)
    }

    func testGettingOutIsReachableFromEverySelectionSizeWithoutMovingATile() throws {
        // The clause that is easiest to leave untested: whatever is swept up,
        // there is a way out that costs no tile move.
        for count in 1...6 {
            let row = (0..<count).map { Coord(row: 0, col: $0) }
            let board = board(row)
            let before = board.placementList
            var model = swept([centre(row[0]), centre(row[count - 1])], on: board)
            XCTAssertEqual(model.selection.coords.count, count, "the fixture swept \(model.selection.coords.count) of \(count)")

            sweep(&model, [centre(Coord(row: 9, col: 9))], on: board)
            model.endedPainting()

            XCTAssertTrue(model.selection.isEmpty, "no way out of a selection of \(count)")
            XCTAssertFalse(model.selection.isActive, "still in selection mode after a selection of \(count)")
            XCTAssertEqual(board.placementList, before, "getting out of a selection of \(count) moved a tile")
        }
    }

    func testASweepThatCrossesNoTileAtAllStillLeavesSelectionMode() throws {
        // Empty space swept rather than tapped — the same way out, so a player
        // whose finger drifted is not stuck.
        let board = board([Coord(row: 0, col: 0)])
        var model = BoardModel()
        model.enterSelection()
        sweep(&model, [centre(Coord(row: 5, col: 5)), centre(Coord(row: 5, col: 9))], on: board)
        model.endedPainting()
        XCTAssertFalse(model.selection.isActive, "a sweep across empty space left the player in selection mode")
    }

    // MARK: - Guardrail — nothing selects while the surface is locked

    func testALockedSurfaceRefusesToEnterSelectionModeOrPaint() throws {
        let row = (0...2).map { Coord(row: 0, col: $0) }
        let board = board(row)

        var model = BoardModel(inputLocked: true)
        model.enterSelection()
        XCTAssertFalse(model.selection.isActive, "a locked surface entered selection mode")

        sweep(&model, [centre(row[0]), centre(row[2])], on: board)
        XCTAssertTrue(model.selection.isEmpty, "a locked surface painted a selection")
        XCTAssertEqual(rendersSelected(model, on: board), [], "a locked surface renders tiles selected")
    }

    func testALockLandingMidSelectionDropsIt() throws {
        let row = (0...2).map { Coord(row: 0, col: $0) }
        let board = board(row)
        var model = swept([centre(row[0]), centre(row[2])], on: board)
        XCTAssertEqual(model.selection.coords.count, 3, "the fixture swept nothing to be dropped")

        model.inputLocked = true

        XCTAssertTrue(model.selection.isEmpty, "the lock left a selection standing")
        XCTAssertFalse(model.selection.isActive, "the lock left the surface in selection mode")

        // And it stays refused: the finger still down paints nothing more.
        model.painting(from: centre(row[0]), to: centre(row[2]), on: board, camera: Self.camera)
        XCTAssertTrue(model.selection.isEmpty, "the sweep carried on through the lock")
    }

    func testALockedTouchIsAPanEvenInSelectionMode() throws {
        let row = (0...2).map { Coord(row: 0, col: $0) }
        let board = board(row)
        let model = swept([centre(row[0]), centre(row[2])], on: board)

        let locked = BoardGesture.Drag(
            at: centre(row[1]), in: board, selection: model.selection,
            camera: Self.camera, inputLocked: true
        )
        XCTAssertEqual(locked.grab, .pan, "a locked touch on a selected tile still took hold of it")

        let unlocked = BoardGesture.Drag(
            at: centre(row[1]), in: board, selection: model.selection, camera: Self.camera
        )
        XCTAssertNotEqual(unlocked.grab, .pan, "the unlocked half of the check proves nothing")
    }

    func testALockedSurfaceTakesNoHoldOfASelection() throws {
        let row = (0...2).map { Coord(row: 0, col: $0) }
        let board = board(row)
        var model = swept([centre(row[0]), centre(row[2])], on: board)
        let grab = BoardGesture.Drag(
            at: centre(row[1]), in: board, selection: model.selection, camera: Self.camera
        ).grab

        model.inputLocked = true
        let haptics = RecordedHaptics()
        model.began(grab, haptics: haptics)

        XCTAssertTrue(model.dragging.isEmpty, "a locked surface took hold of the selection")
        XCTAssertEqual(haptics.events, [], "a locked surface felt a pickup")
    }

    // MARK: - The grab decision, taken once

    func testSelectionModeDecidesPaintOrHoldAtTouchDownAndNeverPans() throws {
        let row = (0...2).map { Coord(row: 0, col: $0) }
        let loose = Coord(row: 3, col: 3)
        let board = board(row + [loose])
        let model = swept([centre(row[0]), centre(row[2])], on: board)

        // A tile the selection holds: a hold, so the group can be moved.
        let held = BoardGesture.Drag(
            at: centre(row[1]), in: board, selection: model.selection, camera: Self.camera
        ).grab
        guard case .tile(_, let coord) = held else { return XCTFail("a selected tile is not held: \(held)") }
        XCTAssertEqual(coord, row[1])

        // A tile the selection does not hold, and empty space: both paint, so
        // one finger never pans while sweeping.
        for point in [centre(loose), centre(Coord(row: 8, col: 8))] {
            let grab = BoardGesture.Drag(
                at: point, in: board, selection: model.selection, camera: Self.camera
            ).grab
            guard case .paint = grab else { return XCTFail("a sweep in selection mode is \(grab)") }
        }

        // And a paint grab moves no camera, so the sweep cannot pan the surface
        // out from under itself.
        let sweeping = BoardGesture.Drag(
            at: centre(Coord(row: 8, col: 8)), in: board, selection: model.selection, camera: Self.camera
        )
        XCTAssertEqual(
            sweeping.camera(Self.camera, translatedBy: CGSize(width: 40, height: 40)).pan,
            Self.camera.pan,
            "a sweep panned the camera"
        )
    }

    func testASweepPaintsNoTileTheCameraCannotReallyIndex() throws {
        // `camera.coord(at:)` answers the origin cell for anything it cannot
        // index. A sample that far out must paint nothing rather than sweep up
        // whatever tile sits at (0, 0).
        let board = board([Coord(row: 0, col: 0)])
        var model = BoardModel()
        model.enterSelection()
        model.painting(
            from: CGPoint(x: 1e300, y: 1e300), to: CGPoint(x: 1e300, y: 1e300),
            on: board, camera: Self.camera
        )
        model.painting(
            from: CGPoint(x: CGFloat.nan, y: 0), to: CGPoint(x: 0, y: CGFloat.nan),
            on: board, camera: Self.camera
        )
        XCTAssertTrue(model.selection.isEmpty, "an unindexable sample swept up the origin tile")
        XCTAssertTrue(model.selection.isActive, "an unindexable sample dropped the mode")
    }
}
