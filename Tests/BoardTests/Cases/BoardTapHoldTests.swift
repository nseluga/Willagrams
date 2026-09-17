import XCTest
import Foundation
import CoreGraphics
import WillagramsRules

/// Records what the session asked the hardware for, in order. `@unchecked
/// Sendable` over a lock rather than an actor, as elsewhere in this package:
/// `BoardHaptics.fire` is synchronous by design.
private final class RecordedHaptics: BoardHaptics, @unchecked Sendable {
    private let guardLock = NSLock()
    private var stored: [BoardHapticEvent] = []

    var events: [BoardHapticEvent] {
        guardLock.lock(); defer { guardLock.unlock() }
        return stored
    }

    var pickups: Int { events.filter { $0 == .pickup }.count }

    func fire(_ event: BoardHapticEvent) {
        guardLock.lock(); defer { guardLock.unlock() }
        stored.append(event)
    }
}

/// A TAP on a letter must write nothing.
///
/// `DragGesture(minimumDistance: 0)` sees a tap as a drag of zero distance, and
/// that zero distance is load-bearing: pan and paint have to begin at
/// touch-down, and a competing tap gesture loses every sequence to a
/// zero-distance drag, which is why the double tap is attached
/// `.simultaneousGesture`. So the first half of the double tap that enters
/// selection mode used to lift a tile, buzz, and commit a zero-translation drop
/// — writing the model between the two taps, so the pair never completed over a
/// letter and a sweep from a letter could not multi-select.
///
/// The fix is `BoardGesture.Drag.shouldBegin`, and it is exercised here rather
/// than inspected: `BoardGesture` and `BoardModel` are symlinked into this
/// package, so the files the app compiles are the ones under test. The SwiftUI
/// gesture graph is unreachable headlessly, so each case below REPLAYS what
/// `BoardView.dragGesture` does frame by frame — including the `begunAt`
/// bookkeeping — and one structural check pins that the view really routes
/// through the predicate.
final class BoardTapHoldTests: XCTestCase {

    // MARK: - Fixtures

    /// 48pt cells at the origin: a whole cell step is a translation of 48 and a
    /// cell centre sits 24 in from its corner.
    private static let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)

    /// Mirrors `DesignTokens.Motion.snapThreshold`, which is SwiftUI and
    /// unreachable here; wide enough to accept any release inside a cell.
    private static let snapThreshold: CGFloat = 96

    private static let dictionary = EnableWordList(words: [])

    private static let home = Coord(row: 0, col: 0)
    private static let bystander = Coord(row: 4, col: 6)

    /// The centre of `home`'s cell.
    private static let touch = CGPoint(x: 24, y: 24)

    /// Both fixture ids are LITERAL, and every tile built in this file uses one.
    ///
    /// `BoardModel` scatters each tile up to ±0.4 of a cell off its lattice
    /// position, and derives that offset from the first two bytes of the tile's
    /// id — deterministic for a given id, and a fresh ±19pt at cell 48 for every
    /// `UUID()`. A drop is measured from where the tile is DRAWN, so with random
    /// ids the same finger travel landed in a different cell run to run: this
    /// file was red on about one full-suite run in six. `0x80` in both bytes is
    /// the middle of that range, so these two tiles sit within 0.1pt of their
    /// lattice positions and a travel of one cell means one cell.
    private static let homeID = UUID(uuidString: "80800000-0000-0000-0000-000000000001")!
    private static let bystanderID = UUID(uuidString: "80800000-0000-0000-0000-000000000002")!

    private struct Fixture {
        let board: Board
        let tile: Tile
    }

    private func fixture() -> Fixture {
        var board = Board()
        let tile = Tile(id: Self.homeID, letter: "A")
        try? board.place(tile, at: Self.home)
        try? board.place(Tile(id: Self.bystanderID, letter: "B"), at: Self.bystander)
        return Fixture(board: board, tile: tile)
    }

    /// One whole gesture, replayed exactly as `BoardView.dragGesture` runs it.
    ///
    /// `onChanged` per translation in `translations` (the first is the
    /// touch-down frame, where `carried` is nil), then `onEnded` with the last
    /// of them. `begunAt` is the view's own `@State`, kept here the same way —
    /// the fact that this gesture has begun, not an inference from what the
    /// model is holding. `perFrame` runs after each frame, standing in for what
    /// the rest of the view can do to the model mid-gesture.
    @discardableResult
    private func replay(
        from start: CGPoint,
        translations: [CGSize],
        board: inout Board,
        model: inout BoardModel,
        selection: BoardSelection = BoardSelection(),
        camera: BoardCamera? = nil,
        haptics: RecordedHaptics,
        perFrame: ((Int, inout BoardModel) -> Void)? = nil
    ) -> BoardGesture.Drag {
        let camera = camera ?? Self.camera
        var drag: BoardGesture.Drag?
        var begunAt: CGPoint?
        for (index, translation) in translations.enumerated() {
            let carried = drag.flatMap { $0.startLocation == start ? $0 : nil }
            let inFlight = carried ?? BoardGesture.Drag(
                at: start, in: board, selection: selection, camera: camera,
                inputLocked: model.inputLocked, offsets: model.tileOffsets
            )
            XCTAssertEqual(index == 0, carried == nil, "the replay lost the carried drag")
            if inFlight.shouldBegin(
                firstFrame: carried == nil,
                begun: begunAt == start,
                after: translation
            ) {
                model.began(inFlight.grab, on: board, against: Self.dictionary, haptics: haptics)
                begunAt = start
            }
            drag = inFlight
            model.moved(to: translation)
            if case .paint = inFlight.grab {
                let point = CGPoint(x: start.x + translation.width, y: start.y + translation.height)
                model.painting(from: start, to: point, on: board, camera: camera)
            }
            perFrame?(index, &model)
        }
        let final = translations.last ?? .zero
        if !model.dragging.isEmpty {
            model.moved(to: final)
            board = model.commit(
                translation: model.dragTranslation, on: board, camera: camera,
                threshold: Self.snapThreshold, lift: 6, against: Self.dictionary
            )
        } else if case .some(.paint) = drag?.grab {
            model.endedPainting()
        }
        return drag!
    }

    /// The two cameras every threshold case runs at. The threshold is a
    /// distance in POINTS on the screen, not a fraction of a cell, so the same
    /// finger travels must decide the same way at either zoom — a threshold
    /// written in cells would pass at exactly one scale.
    private static let cameras = [camera, BoardCamera(pan: .zero, zoom: 2, baseCellSize: 48)]

    /// The centre of `home`'s cell as `camera` draws it.
    private func touch(in camera: BoardCamera) -> CGPoint {
        CGPoint(
            x: camera.point(for: Self.home).x + camera.cellSize / 2,
            y: camera.point(for: Self.home).y + camera.cellSize / 2
        )
    }

    // MARK: - Criterion 1 — a tap on a letter commits nothing

    func testATapOnALetterTakesNoHoldWritesNoStateAndFiresNoFeel() throws {
        let fixture = self.fixture()
        var board = fixture.board
        let feel = RecordedHaptics()
        var model = BoardModel(board: board, against: Self.dictionary)

        let beforeValidation = model.validation
        let beforeSelected = model.selected
        let beforeSparkles = model.willaSparkles

        // The control: this point really is on the letter, so the assertions
        // below are not passing on a touch that simply missed.
        let drag = replay(
            from: Self.touch,
            // A touch-down frame and a second frame with the hand's own jitter,
            // well inside UIKit's tap slop — a real tap is never exactly zero.
            translations: [.zero, CGSize(width: 1.5, height: -2)],
            board: &board, model: &model, haptics: feel
        )
        XCTAssertEqual(drag.grab, .tile(fixture.tile, at: Self.home), "the tap missed the letter")

        XCTAssertEqual(feel.events, [], "a tap on a letter fired \(feel.events)")
        XCTAssertTrue(model.dragging.isEmpty, "a tap on a letter took hold of it")
        XCTAssertEqual(board.placementList, fixture.board.placementList, "a tap on a letter moved the board")
        XCTAssertEqual(model.validation, beforeValidation, "a tap on a letter rewrote validation")
        XCTAssertEqual(model.selected, beforeSelected, "a tap on a letter changed what reads as held")
        XCTAssertEqual(model.willaSparkles, beforeSparkles, "a tap on a letter re-announced a run")
        XCTAssertEqual(model.dragTranslation, .zero, "a tap on a letter left a translation behind")
    }

    // MARK: - Criterion 1 — both sides AND the exact boundary, at two zooms

    /// A threshold is a number, a unit and a comparison. The unit is pinned by
    /// running at two cell sizes; the comparison is pinned by asserting the
    /// EXACT boundary magnitude, not only a tenth of a point either side of it —
    /// `>=` quietly becoming `>` moves only that one value, and a pair of ±0.1
    /// probes never visits it.
    func testTheHoldIsTakenAtExactlyTheThresholdAndJustOverItButNotJustUnderIt() throws {
        let threshold = BoardGesture.Drag.tileHoldThreshold
        let under = threshold - 0.1
        let over = threshold + 0.1

        for camera in Self.cameras {
            let fixture = self.fixture()
            let point = touch(in: camera)
            let drag = BoardGesture.Drag(at: point, in: fixture.board, camera: camera)
            XCTAssertEqual(drag.grab, .tile(fixture.tile, at: Self.home), "the fixture touch missed at \(camera.cellSize)")

            func begins(_ translation: CGSize) -> Bool {
                drag.shouldBegin(firstFrame: true, begun: false, after: translation)
            }
            // Straight along either axis, and on the diagonal where the
            // MAGNITUDE — not the larger component — is what has to be
            // measured: a diagonal of `under` per axis is over the threshold in
            // distance, and a per-axis comparison would refuse it.
            XCTAssertFalse(begins(.zero), "a still finger took hold at cell \(camera.cellSize)")
            XCTAssertFalse(begins(CGSize(width: under, height: 0)), "\(under)pt took hold at cell \(camera.cellSize)")
            XCTAssertFalse(begins(CGSize(width: 0, height: -under)), "\(under)pt up took hold at cell \(camera.cellSize)")
            // The boundary itself, which the threshold is defined to INCLUDE.
            // Exact in binary: the magnitude of an axis-only travel is that
            // travel, with no square root error to leave it a hair short.
            XCTAssertTrue(
                begins(CGSize(width: threshold, height: 0)),
                "exactly \(threshold)pt did not take hold at cell \(camera.cellSize)"
            )
            XCTAssertTrue(
                begins(CGSize(width: 0, height: -threshold)),
                "exactly \(threshold)pt up did not take hold at cell \(camera.cellSize)"
            )
            XCTAssertTrue(begins(CGSize(width: over, height: 0)), "\(over)pt did not take hold at cell \(camera.cellSize)")
            XCTAssertTrue(begins(CGSize(width: under, height: under)), "a diagonal past the threshold did not take hold")

            // And the same three decisions end to end, through the model: just
            // under buzzes nothing, exactly on it and just over it both lift.
            for (travel, expected) in [(under, false), (threshold, true), (over, true)] {
                var board = fixture.board
                var model = BoardModel(board: board, against: Self.dictionary)
                let feel = RecordedHaptics()
                replay(
                    from: point,
                    translations: [.zero, CGSize(width: travel, height: 0)],
                    board: &board, model: &model, camera: camera, haptics: feel
                )
                XCTAssertEqual(
                    feel.events.contains(.pickup), expected,
                    "a travel of \(travel)pt at cell \(camera.cellSize) fired \(feel.events)"
                )
                XCTAssertEqual(
                    board.placementList, fixture.board.placementList,
                    "a travel of \(travel)pt at cell \(camera.cellSize) moved a tile a whole cell"
                )
            }
        }
    }

    // MARK: - A real drag is unchanged

    func testADragPastTheThresholdLiftsOnceAndStillCommitsItsMove() throws {
        let fixture = self.fixture()
        var board = fixture.board
        var model = BoardModel(board: board, against: Self.dictionary)
        let feel = RecordedHaptics()

        // Many frames, as a real finger produces: the hold is taken on the frame
        // that clears the threshold and never again, or a pickup would fire per
        // frame for the rest of the drag.
        let travel = (1...12).map { CGSize(width: CGFloat($0) * 4, height: 0) }
        replay(
            from: Self.touch, translations: [.zero] + travel,
            board: &board, model: &model, haptics: feel
        )

        XCTAssertEqual(feel.pickups, 1, "the drag fired \(feel.events)")
        XCTAssertEqual(board.placementList.count, fixture.board.placementList.count)
        XCTAssertEqual(
            board.tile(at: Coord(row: 0, col: 1)), fixture.tile,
            "a drag of a whole cell did not land the tile"
        )
        XCTAssertNil(board.tile(at: Self.home), "the tile is in two places")
        XCTAssertTrue(model.dragging.isEmpty, "the drag was never released")
    }

    // MARK: - One pickup per gesture, even when the hold is cancelled under it

    /// The hold being dropped mid-gesture is NOT "this gesture has not begun".
    ///
    /// Two things cancel a live hold while the finger is still down: a second
    /// finger landing (`BoardView.pinched` calls `BoardModel.cancel`) and the
    /// input lock landing (`BoardModel.inputLocked`'s didSet does the same).
    /// Read "has this begun?" off the model still carrying tiles and both of
    /// them re-arm the threshold — with a translation by then far past it, so
    /// the very next frame fires a SECOND pickup and re-lifts the tile inside
    /// one touch, which the old `if carried == nil` could never do.
    func testASecondFingerOrALockLandingMidDragDoesNotFireASecondPickup() throws {
        // The pinch: `pinched()` cancels the hold on its first frame. The frames
        // it then swallows (`guard pinch == nil`) are simply not in this list;
        // what matters is the frame after the fingers sort themselves out.
        do {
            let fixture = self.fixture()
            var board = fixture.board
            var model = BoardModel(board: board, against: Self.dictionary)
            let feel = RecordedHaptics()
            replay(
                from: Self.touch,
                translations: [.zero, CGSize(width: 40, height: 0), CGSize(width: 60, height: 8)],
                board: &board, model: &model, haptics: feel,
                perFrame: { index, model in if index == 1 { model.cancel() } }
            )
            XCTAssertEqual(feel.pickups, 1, "a second finger re-lifted the tile: \(feel.events)")
        }

        // The lock, landing and lifting again under the same finger.
        do {
            let fixture = self.fixture()
            var board = fixture.board
            var model = BoardModel(board: board, against: Self.dictionary)
            let feel = RecordedHaptics()
            replay(
                from: Self.touch,
                translations: [.zero, CGSize(width: 40, height: 0), CGSize(width: 60, height: 8)],
                board: &board, model: &model, haptics: feel,
                perFrame: { index, model in
                    if index == 1 { model.inputLocked = true; model.inputLocked = false }
                }
            )
            XCTAssertEqual(feel.pickups, 1, "an unlock re-lifted the tile: \(feel.events)")
        }
    }

    // MARK: - Pan and paint are untouched

    func testPanAndPaintStillBeginAtTouchDownAndOnlyThere() throws {
        let fixture = self.fixture()
        // Far from any tile, so this is a bare cell either way.
        let empty = CGPoint(x: 24 + 48 * 8, y: 24 + 48 * 8)

        let pan = BoardGesture.Drag(at: empty, in: fixture.board, camera: Self.camera)
        XCTAssertEqual(pan.grab, .pan)

        var selection = BoardSelection()
        selection.enter()
        let paint = BoardGesture.Drag(
            at: empty, in: fixture.board, selection: selection, camera: Self.camera
        )
        guard case .paint = paint.grab else { return XCTFail("a bare cell in selection mode is not a sweep") }

        // Neither takes a `TileDrag`, so neither may be gated on travel: they
        // begin on the first frame and never again — for a sweep, beginning
        // twice would reset the paint cursor mid-stroke.
        for drag in [pan, paint] {
            XCTAssertTrue(drag.shouldBegin(firstFrame: true, begun: false, after: .zero))
            XCTAssertFalse(drag.shouldBegin(firstFrame: false, begun: false, after: .zero))
            XCTAssertFalse(drag.shouldBegin(firstFrame: false, begun: false, after: CGSize(width: 200, height: 200)))
            XCTAssertFalse(drag.shouldBegin(firstFrame: true, begun: true, after: .zero), "began twice in one gesture")
        }
        // And a tile grab past the threshold is refused once it has begun, which
        // is the only thing standing between a held tile and a pickup per frame.
        let tile = BoardGesture.Drag(at: Self.touch, in: fixture.board, camera: Self.camera)
        XCTAssertFalse(
            tile.shouldBegin(firstFrame: false, begun: true, after: CGSize(width: 200, height: 200)),
            "a held tile was picked up a second time"
        )
    }

    /// The sweep the whole item is for: in selection mode, a finger starting on
    /// a LETTER the selection does not hold paints rather than lifting, and the
    /// deferred hold leaves that untouched — the sweep still begins at
    /// touch-down and still collects the tiles it crosses.
    func testASweepStartingOnALetterStillPaintsFromTheFirstFrame() throws {
        let fixture = self.fixture()
        var board = fixture.board
        var model = BoardModel(board: board, against: Self.dictionary)
        model.enterSelection()
        let feel = RecordedHaptics()

        let drag = replay(
            from: Self.touch,
            translations: [.zero, CGSize(width: 48 * 6, height: 48 * 4)],
            board: &board, model: &model, selection: model.selection, haptics: feel
        )
        guard case .paint = drag.grab else { return XCTFail("a letter the selection does not hold is not a sweep") }
        XCTAssertTrue(model.selection.contains(Self.home), "the sweep missed the letter it started on")
        XCTAssertTrue(model.selection.contains(Self.bystander), "the sweep missed the letter it crossed")
    }

    // MARK: - The view routes through the predicate

    func testBoardViewGatesTheHoldOnTheThresholdPredicateAndRecordsThatItBegan() throws {
        // `BoardView` imports SwiftUI and cannot be compiled here, and the
        // predicate above would be dead code if the view did not call it. One
        // contiguous whole-call literal, matched over source with its
        // indentation normalized away — several independent fragments would pass
        // on a file where the call had been taken apart.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Willagrams/Board/BoardView.swift")
        let normalized = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        XCTAssertTrue(
            normalized.contains(
                "if inFlight.shouldBegin( firstFrame: carried == nil, begun: begunAt == value.startLocation, after: value.translation ) { model.began(inFlight.grab, on: board, against: dictionary, haptics: haptics) begunAt = value.startLocation }"
            ),
            "BoardView no longer gates the tile hold on the travel threshold"
        )
        // The fact it keeps must be put down again on BOTH ends of a gesture,
        // or the next touch at the same point never begins at all.
        XCTAssertTrue(
            normalized.contains("if !now { landInterrupted(); settledIfPanned(); drag = nil; begunAt = nil }"),
            "BoardView does not forget the begun gesture when one is cancelled"
        )
        XCTAssertTrue(
            normalized.contains("settledIfPanned() drag = nil begunAt = nil }"),
            "BoardView does not forget the begun gesture when one is released"
        )
    }
}
