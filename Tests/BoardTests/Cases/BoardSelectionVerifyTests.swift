import XCTest
import Foundation
import CoreGraphics
import WillagramsRules

/// Independent second-pass checks on multi-tile selection.
///
/// Deliberately separate from `BoardSelectionTests`: these exist to reach the
/// arms that suite proves at one value or one shape only — a sweep passing NEAR
/// a tile, a group move in the negative direction, a selection that is not one
/// contiguous run, and the way out at size 0 and after a refusal.
final class BoardSelectionVerifyTests: XCTestCase {

    private final class Haptics: BoardHaptics, @unchecked Sendable {
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

    private static let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)
    /// Wide enough to accept any release inside a cell, matching the real
    /// `snapThreshold`. At the old 22 these moves were a coin flip: a drag
    /// measured from the tile's DRAWN position carries its scatter as the
    /// residual, up to ~27pt, and anything above the threshold was refused.
    private static let threshold: CGFloat = 96
    private static let viewport = CGRect(x: 0, y: 0, width: 480, height: 320)
    private static let dictionary = EnableWordList(words: ["OX", "ON"])

    private func centre(_ coord: Coord) -> CGPoint {
        let point = Self.camera.point(for: coord)
        let half = Self.camera.cellSize / 2
        return CGPoint(x: point.x + half, y: point.y + half)
    }

    private func board(_ coords: [Coord]) -> Board {
        var board = Board()
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for (offset, coord) in coords.enumerated() {
            try? board.place(Tile(letter: letters[offset % letters.count]), at: coord)
        }
        return board
    }

    /// One one-finger stroke, exactly as `BoardView` reports it: the grab is
    /// decided once at touch-down, `began` runs once, then one `painting` per
    /// reported position — and `endedPainting` only when the stroke held no
    /// tile, which is the branch the view takes.
    @discardableResult
    private func stroke(
        _ model: inout BoardModel, _ path: [CGPoint], on board: Board
    ) -> BoardGesture.Grab {
        let start = path[0]
        let grab = BoardGesture.Drag(
            at: start, in: board, selection: model.selection,
            camera: Self.camera, inputLocked: model.inputLocked
        ).grab
        model.began(grab, haptics: Haptics())
        for point in path {
            model.painting(from: start, to: point, on: board, camera: Self.camera)
        }
        if model.dragging.isEmpty, case .paint = grab { model.endedPainting() }
        return grab
    }

    /// Every pairwise (row, col) offset inside a set.
    private func shape(_ coords: Set<Coord>) -> Set<[Int]> {
        var offsets: Set<[Int]> = []
        for one in coords {
            for other in coords { offsets.insert([one.row - other.row, one.col - other.col]) }
        }
        return offsets
    }

    private func rendersSelected(_ model: BoardModel, on board: Board) -> Set<Coord> {
        Set(
            BoardRender.cells(
                board: board, camera: Self.camera, in: Self.viewport,
                dragging: model.selected, by: model.dragTranslation
            )
            .filter { $0.state == .selected }.map(\.coord)
        )
    }

    // MARK: - Criterion 1 — exactly those, not a superset

    /// The arm `BoardSelectionTests` leaves out: tiles the sweep passes NEXT TO
    /// rather than beyond. A sampler with a slack hit window would sweep the
    /// neighbouring rows up too.
    func testASweepDoesNotPaintTheTilesItMerelyPassesNear() throws {
        let crossed = (0...4).map { Coord(row: 0, col: $0) }
        let above = (0...4).map { Coord(row: -1, col: $0) }
        let below = (0...4).map { Coord(row: 1, col: $0) }
        let board = board(crossed + above + below)

        var model = BoardModel()
        model.enterSelection()
        stroke(&model, [centre(crossed[0]), centre(crossed[4])], on: board)

        XCTAssertEqual(model.selection.coords, Set(crossed),
                       "the sweep swept up tiles it only passed near")
        XCTAssertEqual(rendersSelected(model, on: board), Set(crossed))
        XCTAssertEqual(model.selection.coords.count, 5, "wrong count: \(model.selection.coords.count)")
    }

    /// A sweep that stops one cell short must not overshoot into the next tile,
    /// and one that starts one cell late must not reach back.
    func testASweepPaintsNeitherSideOfWhatItActuallyCovered() throws {
        let row = (0...6).map { Coord(row: 3, col: $0) }
        let board = board(row)
        var model = BoardModel()
        model.enterSelection()
        stroke(&model, [centre(row[2]), centre(row[4])], on: board)
        XCTAssertEqual(model.selection.coords, Set(row[2...4]),
                       "the sweep reached past the cells it covered")
    }

    // MARK: - Criterion 2 — a third size, a non-contiguous shape, a negative delta

    func testADisconnectedSelectionMovesUpAndLeftAsOneKeepingEveryOffset() throws {
        let near = [Coord(row: 0, col: 0), Coord(row: 0, col: 1)]
        let far = [Coord(row: 0, col: 6), Coord(row: 1, col: 6)]
        var board = board(near + far + [Coord(row: 5, col: 5)])
        let ids = Dictionary(uniqueKeysWithValues: (near + far).map { ($0, board.tile(at: $0)!.id) })

        var model = BoardModel()
        model.enterSelection()
        // First stroke sweeps the two near tiles and the top far one, crossing
        // empty space in between.
        stroke(&model, [centre(near[0]), centre(far[0])], on: board)
        // Second stroke starts on the tile the selection does NOT hold, so the
        // view's own decision makes it a sweep rather than a hold.
        stroke(&model, [centre(far[1]), centre(far[0])], on: board)

        let before = model.selection.coords
        XCTAssertEqual(before, Set(near + far), "the fixture painted \(before)")
        XCTAssertEqual(before.count, 4)

        let grab = BoardGesture.Drag(
            at: centre(far[1]), in: board, selection: model.selection, camera: Self.camera
        ).grab
        model.began(grab, haptics: Haptics())
        XCTAssertEqual(model.dragging, before, "the hold did not carry the whole disconnected set")

        // Up one row, left three columns — the negative-delta arm.
        board = model.commit(
            translation: CGSize(width: Self.camera.cellSize * -3, height: Self.camera.cellSize * -1),
            on: board, camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )

        let expected = Set((near + far).map { Coord(row: $0.row - 1, col: $0.col - 3) })
        let landed = Set(board.placementList.map(\.coord)).subtracting([Coord(row: 5, col: 5)])
        XCTAssertEqual(landed, expected, "the disconnected selection did not land as one")
        XCTAssertEqual(shape(landed), shape(before), "the disconnected set did not keep its offsets")
        for (from, id) in ids {
            let to = Coord(row: from.row - 1, col: from.col - 3)
            XCTAssertEqual(board.tile(at: to)?.id, id, "the tile from \(from) is not the one at \(to)")
        }
        XCTAssertEqual(board.placementList.count, 5, "a tile went missing on the group move")
        XCTAssertEqual(model.selection.coords, expected, "the selection did not follow the tiles")
    }

    /// Every pairwise offset, at a fourth size, checked against the board rather
    /// than against the selection — so a selection that agreed with itself while
    /// the board disagreed cannot pass.
    func testASixTileBlockKeepsEveryPairwiseOffsetOnTheBoard() throws {
        let block = (0...1).flatMap { row in (0...2).map { Coord(row: row, col: $0) } }
        var board = board(block)
        var model = BoardModel()
        model.enterSelection()
        stroke(&model, [centre(block[0]), centre(block[2])], on: board)
        stroke(&model, [centre(block[3]), centre(block[5])], on: board)
        let before = model.selection.coords
        XCTAssertEqual(before, Set(block), "the fixture painted \(before.count) of 6")

        let grab = BoardGesture.Drag(
            at: centre(block[4]), in: board, selection: model.selection, camera: Self.camera
        ).grab
        model.began(grab, haptics: Haptics())
        board = model.commit(
            translation: CGSize(width: Self.camera.cellSize * 2, height: Self.camera.cellSize * 4),
            on: board, camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )
        let landed = Set(board.placementList.map(\.coord))
        XCTAssertEqual(landed.count, 6, "the move landed \(landed.count) of 6")
        XCTAssertEqual(shape(landed), shape(before), "the block did not keep its offsets")
        XCTAssertEqual(landed, Set(block.map { Coord(row: $0.row + 4, col: $0.col + 2) }))
    }

    // MARK: - Criterion 3 — all or nothing, element for element

    /// A blocker under a MIDDLE tile of a two-row block, so seven of the eight
    /// destinations are free: a partial commit is maximally tempting here.
    func testABlockedGroupMoveLeavesPlacementListElementForElement() throws {
        let block = (0...1).flatMap { row in (0...3).map { Coord(row: row, col: $0) } }
        let blocker = Coord(row: 3, col: 2)
        var board = board(block + [blocker])
        let before = board.placementList

        var model = BoardModel()
        model.enterSelection()
        stroke(&model, [centre(block[0]), centre(block[3])], on: board)
        stroke(&model, [centre(block[4]), centre(block[7])], on: board)
        XCTAssertEqual(model.selection.coords, Set(block), "the fixture swept the blocker in")

        let haptics = Haptics()
        let grab = BoardGesture.Drag(
            at: centre(block[0]), in: board, selection: model.selection, camera: Self.camera
        ).grab
        model.began(grab, haptics: haptics)
        board = model.commit(
            translation: CGSize(width: 0, height: Self.camera.cellSize * 2),
            on: board, camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )

        XCTAssertEqual(board.placementList, before, "the refused group move changed the board")
        XCTAssertEqual(board.placementList.count, 9, "a tile went missing on a refused move")
        XCTAssertEqual(haptics.events, [.pickup, .reject])
        XCTAssertEqual(model.selection.coords, Set(block), "the selection followed a refused move")
    }

    // MARK: - Guardrail — the way out is always reachable, at every size

    /// Size 0: entered the mode and swept nothing. A single reported position —
    /// a tap, not a drag — must still be the way out.
    func testATapGetsOutOfAnEmptySelection() throws {
        let board = board([Coord(row: 0, col: 0), Coord(row: 0, col: 1)])
        let before = board.placementList
        var model = BoardModel()
        model.enterSelection()
        XCTAssertTrue(model.selection.isActive, "the fixture never entered selection mode")
        XCTAssertTrue(model.selection.isEmpty)

        let empty = centre(Coord(row: 7, col: 7))
        stroke(&model, [empty], on: board)

        XCTAssertFalse(model.selection.isActive, "no way out of an empty selection")
        XCTAssertEqual(board.placementList, before, "getting out of an empty selection moved a tile")
    }

    /// Size 1, as a tap rather than as a sweep across empty space.
    func testATapGetsOutOfASelectionOfOne() throws {
        let one = Coord(row: 2, col: 2)
        let board = board([one, Coord(row: 2, col: 5)])
        var model = BoardModel()
        model.enterSelection()
        stroke(&model, [centre(one)], on: board)
        XCTAssertEqual(model.selection.coords, [one], "the fixture swept \(model.selection.coords)")

        stroke(&model, [centre(Coord(row: 7, col: 7))], on: board)
        XCTAssertTrue(model.selection.isEmpty, "the tap left a tile selected")
        XCTAssertFalse(model.selection.isActive, "no way out of a selection of one")
    }

    /// The state the first pass never puts the model in: a group move that was
    /// REFUSED. The hold is gone, the selection stands — and the way out must
    /// still be there, still costing no tile move.
    func testClearingIsReachableAfterARefusedGroupMove() throws {
        let row = (0...2).map { Coord(row: 0, col: $0) }
        var board = board(row + [Coord(row: 1, col: 1)])
        let before = board.placementList

        var model = BoardModel()
        model.enterSelection()
        stroke(&model, [centre(row[0]), centre(row[2])], on: board)
        let grab = BoardGesture.Drag(
            at: centre(row[0]), in: board, selection: model.selection, camera: Self.camera
        ).grab
        model.began(grab, haptics: Haptics())
        board = model.commit(
            translation: CGSize(width: 0, height: Self.camera.cellSize),
            on: board, camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )
        XCTAssertEqual(board.placementList, before, "the refused move changed the board")
        XCTAssertTrue(model.selection.isActive, "the refusal already left the mode")

        stroke(&model, [centre(Coord(row: 8, col: 8))], on: board)

        XCTAssertFalse(model.selection.isActive, "stuck in selection mode after a refused group move")
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(board.placementList, before, "getting out after a refusal moved a tile")
        XCTAssertEqual(rendersSelected(model, on: board), [])
    }

    /// And after an ACCEPTED group move, which leaves the selection replaced
    /// rather than untouched.
    func testClearingIsReachableAfterAnAcceptedGroupMove() throws {
        let row = (0...2).map { Coord(row: 0, col: $0) }
        var board = board(row)
        var model = BoardModel()
        model.enterSelection()
        stroke(&model, [centre(row[0]), centre(row[2])], on: board)
        let grab = BoardGesture.Drag(
            at: centre(row[1]), in: board, selection: model.selection, camera: Self.camera
        ).grab
        model.began(grab, haptics: Haptics())
        board = model.commit(
            translation: CGSize(width: 0, height: Self.camera.cellSize * 3),
            on: board, camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )
        XCTAssertEqual(model.selection.coords.count, 3, "the selection did not follow the move")
        let after = board.placementList

        stroke(&model, [centre(Coord(row: 9, col: 9))], on: board)
        XCTAssertFalse(model.selection.isActive, "stuck in selection mode after a group move landed")
        XCTAssertEqual(board.placementList, after, "getting out after a landed move moved a tile again")

        // Ordinary handling is back on the moved board.
        let pan = BoardGesture.Drag(
            at: centre(Coord(row: 9, col: 9)), in: board,
            selection: model.selection, camera: Self.camera
        )
        XCTAssertEqual(pan.grab, .pan, "empty space no longer pans")
        let hold = BoardGesture.Drag(
            at: centre(Coord(row: 3, col: 1)), in: board,
            selection: model.selection, camera: Self.camera
        )
        model.began(hold.grab, haptics: Haptics())
        XCTAssertEqual(model.dragging, [Coord(row: 3, col: 1)],
                       "a tile is no longer dragged on its own")
    }

    // MARK: - Guardrail — nothing selects while locked

    /// The arm the first pass proves at size >= 1 only: a lock landing on an
    /// EMPTY active selection must still leave the mode, or the surface comes
    /// back from a lock already sweeping.
    func testALockDropsAnEmptyButActiveSelectionMode() throws {
        var model = BoardModel()
        model.enterSelection()
        XCTAssertTrue(model.selection.isActive)
        model.inputLocked = true
        XCTAssertFalse(model.selection.isActive, "the lock left the surface in an empty selection mode")
    }

    /// A lock arriving mid-group-hold: no board change on the release that
    /// follows, and no feel.
    func testALockMidGroupHoldCommitsNothing() throws {
        let row = (0...2).map { Coord(row: 0, col: $0) }
        var board = board(row)
        let before = board.placementList
        var model = BoardModel()
        model.enterSelection()
        stroke(&model, [centre(row[0]), centre(row[2])], on: board)
        let haptics = Haptics()
        let grab = BoardGesture.Drag(
            at: centre(row[1]), in: board, selection: model.selection, camera: Self.camera
        ).grab
        model.began(grab, haptics: haptics)
        XCTAssertEqual(model.dragging.count, 3, "the fixture held nothing")

        model.inputLocked = true
        board = model.commit(
            translation: CGSize(width: 0, height: Self.camera.cellSize * 2),
            on: board, camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )
        XCTAssertEqual(board.placementList, before, "a locked release still moved the group")
        XCTAssertEqual(haptics.events, [.pickup], "a locked release fired a feel")
        XCTAssertTrue(model.selection.isEmpty, "the lock left the selection standing")
    }
}
