import XCTest
import Foundation
import CoreGraphics
import WillagramsRules

/// Records what the session asked the hardware for, in order.
///
/// `@unchecked Sendable` over a lock rather than an actor, for the same reason
/// as the other doubles here: `BoardHaptics.fire` is synchronous by design.
private final class SessionHaptics: BoardHaptics, @unchecked Sendable {
    private let guardLock = NSLock()
    private var stored: [BoardHapticEvent] = []

    var events: [BoardHapticEvent] {
        guardLock.lock(); defer { guardLock.unlock() }
        return stored
    }

    func fire(_ event: BoardHapticEvent) {
        guardLock.lock(); defer { guardLock.unlock() }
        stored.append(event)
    }
}

/// The external input lock, and the tile-drag session it governs.
///
/// Every criterion below is executed, not inspected: `BoardModel` is pure
/// Foundation/CoreGraphics and is symlinked into this package, so the same file
/// the app compiles is the one under test here.
final class BoardModelTests: XCTestCase {

    // MARK: - Fixtures

    /// 48pt cells at the origin, so a whole cell step is a translation of 48
    /// and a cell centre sits 24 in from its corner.
    private static let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)

    /// Mirrors `DesignTokens.Motion.snapThreshold`, which is SwiftUI and
    /// unreachable here. It is a `commit` PARAMETER precisely so a test drives
    /// its own distance; `BoardSourceTests` pins that the view passes the token.
    private static let threshold: CGFloat = 22

    private static let viewport = CGRect(x: 0, y: 0, width: 480, height: 320)

    /// The word list every commit here is checked against. Empty on purpose:
    /// these cases are about the drag session, and an empty list keeps the
    /// checker's answer constant so nothing below depends on it.
    private static let dictionary = EnableWordList(words: [])

    private static let home = Coord(row: 0, col: 0)
    private static let target = Coord(row: 0, col: 1)
    /// A second tile far from `home`, so `placementList` is never a one-entry
    /// list that two different boards could trivially agree on — and far enough
    /// that it is no orthogonal neighbour, keeping `home`'s resting state
    /// `.idle` rather than `.placed`.
    private static let bystander = Coord(row: 4, col: 6)

    /// The centre of `home`'s cell.
    private static let touch = CGPoint(x: 24, y: 24)

    /// Exactly one cell to the right: the drop lands dead centre on `target`.
    private static let oneCell = CGSize(width: 48, height: 0)

    private struct Fixture {
        let board: Board
        let tile: Tile
    }

    private func fixture() -> Fixture {
        var board = Board()
        let tile = Tile(letter: "A")
        try? board.place(tile, at: Self.home)
        try? board.place(Tile(letter: "B"), at: Self.bystander)
        return Fixture(board: board, tile: tile)
    }

    private func cells(_ board: Board, _ model: BoardModel) -> [BoardRender.Cell] {
        BoardRender.cells(
            board: board, camera: Self.camera, in: Self.viewport,
            dragging: model.dragging, by: model.dragTranslation
        )
    }

    private func cell(at coord: Coord, _ board: Board, _ model: BoardModel) throws -> BoardRender.Cell {
        try XCTUnwrap(cells(board, model).first { $0.coord == coord })
    }

    // MARK: - Criterion 1 — a locked touch neither lifts a tile nor buzzes

    func testALockedTouchOnATileTakesNoHoldChangesNoPlacementAndFiresNoFeel() throws {
        let fixture = self.fixture()

        // The control comes first and proves the fixture point really does land
        // on the tile. Without it, the locked assertions below would pass just
        // as happily on a point that misses.
        let open = BoardGesture.Drag(
            at: Self.touch, in: fixture.board, camera: Self.camera, inputLocked: false
        )
        XCTAssertEqual(open.grab, .tile(fixture.tile, at: Self.home))

        // Same point, locked. The refusal is at gesture start: the grab itself
        // comes back `.pan`, so nothing was ever lifted to revert.
        let locked = BoardGesture.Drag(
            at: Self.touch, in: fixture.board, camera: Self.camera, inputLocked: true
        )
        XCTAssertEqual(locked.grab, .pan)

        let feel = SessionHaptics()
        var model = BoardModel(inputLocked: true)
        model.began(locked.grab, haptics: feel)
        XCTAssertTrue(model.dragging.isEmpty, "a locked touch took hold of a tile")

        model.moved(to: Self.oneCell)
        XCTAssertEqual(model.dragTranslation, .zero, "a locked touch dragged a tile")

        let after = model.commit(
            translation: Self.oneCell, on: fixture.board,
            camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )
        XCTAssertEqual(after.placementList, fixture.board.placementList, "a locked drag changed the board")
        XCTAssertEqual(feel.events, [], "a locked touch fired \(feel.events)")

        // And nothing reads as lifted: no ring, no selected state anywhere.
        XCTAssertNil(cells(after, model).first { $0.state == .selected }, "a locked tile reads as lifted")
        XCTAssertEqual(try cell(at: Self.home, after, model).state, .idle)
    }

    func testALockedModelRefusesATileGrabHandedToItDirectly() throws {
        // The gesture layer refuses one step earlier, but the hold lives here,
        // so the invariant is restated here too: a locked model cannot be
        // talked into a hold by a caller that skipped that refusal.
        let fixture = self.fixture()
        let grab = BoardGesture.Grab.tile(fixture.tile, at: Self.home)

        let refused = SessionHaptics()
        var locked = BoardModel(inputLocked: true)
        locked.began(grab, haptics: refused)
        XCTAssertTrue(locked.dragging.isEmpty)
        XCTAssertEqual(refused.events, [])

        // The same grab, same call, unlocked — so the refusal is the lock's
        // doing and not the grab's.
        let taken = SessionHaptics()
        var open = BoardModel()
        open.began(grab, haptics: taken)
        XCTAssertEqual(open.dragging, [Self.home])
        XCTAssertEqual(taken.events, [.pickup])
    }

    func testTheGestureDefaultsToUnlockedSoAnUnaskedCallStillHitTests() {
        // ~100 existing call sites omit the argument. If the default ever flips,
        // every one of them silently stops picking tiles up.
        let fixture = self.fixture()
        let drag = BoardGesture.Drag(at: Self.touch, in: fixture.board, camera: Self.camera)
        XCTAssertEqual(drag.grab, .tile(fixture.tile, at: Self.home))
    }

    // MARK: - Criterion 2 — the camera stays live while the input is locked

    func testPanZoomAndRecenterAllStayLiveWhileTheInputIsLocked() {
        let fixture = self.fixture()
        let travel = CGSize(width: 60, height: -30)

        // A locked touch that landed ON a tile still pans — the strongest form
        // of the criterion, since that is the touch a lock is refusing.
        let locked = BoardGesture.Drag(
            at: Self.touch, in: fixture.board, camera: Self.camera, inputLocked: true
        )
        let panned = locked.camera(Self.camera, translatedBy: travel)
        XCTAssertEqual(panned.pan, travel)
        XCTAssertNotEqual(panned.pan, Self.camera.pan, "the locked pan went nowhere")

        // And the same touch unlocked moves the camera NOT AT ALL, because it
        // took hold of the tile instead. So the pan above is a consequence of
        // the lock rather than of the point.
        let open = BoardGesture.Drag(
            at: Self.touch, in: fixture.board, camera: Self.camera, inputLocked: false
        )
        XCTAssertEqual(open.camera(Self.camera, translatedBy: travel).pan, Self.camera.pan)

        // Zoom and recenter never consult the lock at all — `BoardModel` holds
        // no camera, so there is nothing for them to consult. Both still move.
        let zoomed = Self.camera.magnified(by: 1.5, about: Self.touch)
        XCTAssertNotEqual(zoomed.cellSize, Self.camera.cellSize, "the zoom went nowhere")

        let framed = BoardGesture.recentered(Self.camera, over: fixture.board, in: Self.viewport)
        XCTAssertNotEqual(framed.pan, Self.camera.pan, "the recenter went nowhere")
    }

    // MARK: - Criterion 3 — a lock landing mid-drag returns the tile home

    func testALockLandingMidDragReturnsTheTileToTheCoordItStartedFrom() throws {
        let fixture = self.fixture()
        let feel = SessionHaptics()
        var model = BoardModel()

        let drag = BoardGesture.Drag(
            at: Self.touch, in: fixture.board, camera: Self.camera, inputLocked: model.inputLocked
        )
        model.began(drag.grab, haptics: feel)
        model.moved(to: Self.oneCell)

        // The lifted intermediate, asserted rather than assumed: without this
        // the lock could be "working" on a drag that never started.
        XCTAssertEqual(model.dragging, [Self.home])
        XCTAssertEqual(model.dragTranslation, Self.oneCell)
        let lifted = try cell(at: Self.home, fixture.board, model)
        XCTAssertEqual(lifted.state, .selected)
        XCTAssertEqual(lifted.tilePoint?.x, lifted.point.x + Self.oneCell.width)
        XCTAssertEqual(feel.events, [.pickup])

        // A bare assignment, with no second call to cancel anything.
        model.inputLocked = true

        XCTAssertTrue(model.dragging.isEmpty, "the lock left a tile held")
        XCTAssertEqual(model.dragTranslation, .zero, "the lock left the tile offset")
        XCTAssertEqual(feel.events, [.pickup], "the lock fired a feel of its own")

        // The tile is back on the coord it started from, drawn at its home
        // point with no lift and no ring.
        let home = try cell(at: Self.home, fixture.board, model)
        XCTAssertEqual(home.tile?.id, fixture.tile.id)
        XCTAssertEqual(home.tilePoint, home.point)
        XCTAssertEqual(home.state, .idle)
        XCTAssertNil(try cell(at: Self.target, fixture.board, model).tile)

        // And the release that follows commits nothing.
        let released = model.commit(
            translation: Self.oneCell, on: fixture.board,
            camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )
        XCTAssertEqual(released.placementList, fixture.board.placementList)
        XCTAssertEqual(feel.events, [.pickup])
    }

    func testCancelDropsTheHoldWithNoFeelAndWithoutTouchingTheBoard() throws {
        // The other caller of the one cancel path: a second finger taking the
        // gesture away. Same outcome as the lock, which is the point of there
        // being one path.
        let fixture = self.fixture()
        let feel = SessionHaptics()
        var model = BoardModel()
        model.began(.tile(fixture.tile, at: Self.home), haptics: feel)
        model.moved(to: Self.oneCell)
        XCTAssertEqual(model.dragging, [Self.home])

        model.cancel()

        XCTAssertTrue(model.dragging.isEmpty)
        XCTAssertEqual(model.dragTranslation, .zero)
        XCTAssertEqual(feel.events, [.pickup], "the cancel path fired a feel")

        // Cancelling drops the HOLD, never the lock: a `cancel()` that cleared
        // the flag would let the touch after a lock-cancelled one take a tile.
        model.inputLocked = true
        model.cancel()
        XCTAssertTrue(model.inputLocked, "cancelling cleared the lock")

        let released = model.commit(
            translation: Self.oneCell, on: fixture.board,
            camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )
        XCTAssertEqual(released.placementList, fixture.board.placementList)
    }

    func testFramesAfterALockLandsMidDragMoveNothingAndTheReleaseCommitsNothing() throws {
        // The finger never lifts. SwiftUI keeps reporting `onChanged` for the
        // same gesture, and the view reuses the carried `.tile` grab rather
        // than deciding again — so `began` never runs a second time and the
        // frames that follow the lock reach `moved` and `commit` alone.
        let fixture = self.fixture()
        let feel = SessionHaptics()
        var model = BoardModel()

        model.began(.tile(fixture.tile, at: Self.home), haptics: feel)
        model.moved(to: Self.oneCell)
        XCTAssertEqual(model.dragTranslation, Self.oneCell)

        model.inputLocked = true

        // Two more frames of a finger still down and still travelling.
        model.moved(to: CGSize(width: 96, height: 30))
        model.moved(to: CGSize(width: 144, height: 60))

        XCTAssertEqual(model.dragTranslation, .zero, "the tile started following the finger again")
        XCTAssertTrue(model.dragging.isEmpty, "the lock left a tile held")
        XCTAssertEqual(feel.events, [.pickup], "a second pickup fired under the lock")

        let home = try cell(at: Self.home, fixture.board, model)
        XCTAssertEqual(home.tilePoint, home.point)
        XCTAssertEqual(home.state, .idle)

        let released = model.commit(
            translation: CGSize(width: 144, height: 60), on: fixture.board,
            camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )
        XCTAssertEqual(released.placementList, fixture.board.placementList, "the release committed under the lock")
        XCTAssertEqual(feel.events, [.pickup], "the release fired a feel under the lock")
    }

    func testAGestureCaughtMidFlightMovesNeitherTileNorCameraWhileTheNextTouchStillPans() throws {
        // Deliberate: a finger already holding a tile when the lock lands goes
        // inert for the rest of ITS touch — the tile stops following it and the
        // board does not start following it either. Panning comes back on the
        // next touch down, which is the half that makes "panning stays live
        // while locked" true rather than a surface that is inert forever.
        let fixture = self.fixture()
        let feel = SessionHaptics()
        var model = BoardModel()

        let inFlight = BoardGesture.Drag(
            at: Self.touch, in: fixture.board, camera: Self.camera, inputLocked: model.inputLocked
        )
        XCTAssertEqual(inFlight.grab, .tile(fixture.tile, at: Self.home))
        model.began(inFlight.grab, haptics: feel)
        model.moved(to: Self.oneCell)

        model.inputLocked = true

        // The rest of that same touch: the view carries `inFlight` rather than
        // deciding again, so these are the only two things it can still do.
        let travel = CGSize(width: 144, height: 60)
        model.moved(to: travel)
        let carriedCamera = inFlight.camera(Self.camera, translatedBy: travel)

        XCTAssertTrue(model.dragging.isEmpty, "the caught gesture kept holding the tile")
        XCTAssertEqual(model.dragTranslation, .zero, "the caught gesture kept moving the tile")
        XCTAssertEqual(carriedCamera.pan, Self.camera.pan, "the caught gesture started panning mid-touch")
        XCTAssertEqual(carriedCamera.zoom, Self.camera.zoom)

        // The NEXT touch, still locked, on the very same tile: it pans.
        let next = BoardGesture.Drag(
            at: Self.touch, in: fixture.board, camera: Self.camera, inputLocked: model.inputLocked
        )
        XCTAssertEqual(next.grab, .pan, "a touch under the lock still took hold of a tile")
        let panned = next.camera(Self.camera, translatedBy: travel)
        XCTAssertEqual(panned.pan, CGSize(width: Self.camera.pan.width + travel.width,
                                          height: Self.camera.pan.height + travel.height),
                       "panning is dead while the lock is set")
    }

    func testMovedWritesNoOffsetWhileNothingIsHeld() {
        let fixture = self.fixture()
        let feel = SessionHaptics()
        var model = BoardModel()

        // A finger that took hold of the camera writes no tile offset...
        model.began(.pan, haptics: feel)
        XCTAssertTrue(model.dragging.isEmpty, "a pan grab took hold of a tile")
        model.moved(to: CGSize(width: 120, height: 90))
        XCTAssertEqual(model.dragTranslation, .zero)
        XCTAssertEqual(feel.events, [])

        // ...while one that took hold of a tile does, so the no-op above is the
        // absence of a hold and not a broken setter.
        model.began(.tile(fixture.tile, at: Self.home), haptics: feel)
        model.moved(to: CGSize(width: 120, height: 90))
        XCTAssertEqual(model.dragTranslation, CGSize(width: 120, height: 90))
    }

    // MARK: - Criterion 4 — clearing the lock restores dragging, with no residue

    func testClearingTheLockRestoresDraggingAndLandsARealMove() throws {
        let fixture = self.fixture()
        let feel = SessionHaptics()
        var model = BoardModel()

        // Lift a tile, then lock mid-flight.
        model.began(.tile(fixture.tile, at: Self.home), haptics: feel)
        model.moved(to: Self.oneCell)
        XCTAssertEqual(model.dragging, [Self.home])
        model.inputLocked = true
        XCTAssertTrue(model.dragging.isEmpty)

        model.inputLocked = false

        // Unlocking restores nothing by itself: no tile is still held, and no
        // cell anywhere reads `.selected`.
        XCTAssertTrue(model.dragging.isEmpty, "unlocking resurrected the cancelled hold")
        XCTAssertEqual(model.dragTranslation, .zero)
        XCTAssertNil(
            cells(fixture.board, model).first { $0.state == .selected },
            "a tile is left selected after the lock cleared"
        )

        // A fresh gesture now behaves exactly as an unlocked one always did —
        // and the board it lands on is a DIFFERENT board, which is what stops
        // this test passing on a model that quietly refuses everything.
        let drag = BoardGesture.Drag(
            at: Self.touch, in: fixture.board, camera: Self.camera, inputLocked: model.inputLocked
        )
        XCTAssertEqual(drag.grab, .tile(fixture.tile, at: Self.home))
        model.began(drag.grab, haptics: feel)
        model.moved(to: Self.oneCell)
        XCTAssertEqual(model.dragging, [Self.home])
        XCTAssertEqual(model.dragTranslation, Self.oneCell)

        let landed = model.commit(
            translation: Self.oneCell, on: fixture.board,
            camera: Self.camera, threshold: Self.threshold, against: Self.dictionary
        )
        XCTAssertNotEqual(landed.placementList, fixture.board.placementList, "the restored drag changed nothing")
        XCTAssertEqual(landed.tile(at: Self.target)?.id, fixture.tile.id)
        XCTAssertNil(landed.tile(at: Self.home))
        XCTAssertEqual(feel.events, [.pickup, .pickup, .snap])

        // The commit clears the session, so the next touch starts clean.
        XCTAssertTrue(model.dragging.isEmpty)
        XCTAssertEqual(model.dragTranslation, .zero)
        XCTAssertNil(cells(landed, model).first { $0.state == .selected })
    }

    func testLockingWithNothingHeldIsHarmlessHoweverManyTimesItIsSet() throws {
        let fixture = self.fixture()
        let feel = SessionHaptics()
        var model = BoardModel()

        model.inputLocked = true
        model.inputLocked = true
        XCTAssertTrue(model.dragging.isEmpty)
        XCTAssertEqual(feel.events, [])

        model.inputLocked = false
        model.began(.tile(fixture.tile, at: Self.home), haptics: feel)
        XCTAssertEqual(model.dragging, [Self.home], "a lock set twice left the surface inert after unlocking")
        XCTAssertEqual(feel.events, [.pickup])
    }
}
