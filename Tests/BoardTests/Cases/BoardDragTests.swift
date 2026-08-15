import XCTest
import Foundation
import CoreGraphics
import WillagramsRules

/// Records what a drag asked the hardware for, in order.
///
/// `@unchecked Sendable` over a lock rather than an actor: `BoardHaptics.fire`
/// is synchronous by design (a buzz a frame late is a buzz in the wrong place),
/// so the double has to be too.
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

final class BoardDragTests: XCTestCase {

    // MARK: - Fixtures

    /// 48pt cells at the origin, so a whole cell step is a translation of 48
    /// and a cell centre sits 24 in from its corner.
    private static let camera = BoardCamera(pan: .zero, zoom: 1, baseCellSize: 48)

    /// Mirrors `DesignTokens.Motion.snapThreshold`. It is a local constant on
    /// purpose: `DesignTokens` is SwiftUI and unreachable here, the threshold is
    /// a `drop` PARAMETER precisely so a test can drive its own distance, and
    /// `BoardSourceTests` pins that the view passes the real token.
    private static let threshold: CGFloat = 22

    private static let viewport = CGRect(x: 0, y: 0, width: 480, height: 320)

    private static func board(_ entries: [(Coord, Tile)]) -> Board {
        var board = Board()
        for (coord, tile) in entries {
            try? board.place(tile, at: coord)
        }
        return board
    }

    private func drag(
        _ origins: Set<Coord>,
        anchor: Coord,
        _ haptics: RecordedHaptics
    ) throws -> TileDrag {
        try XCTUnwrap(TileDrag(origins: origins, anchor: anchor, haptics: haptics))
    }

    // MARK: - Criterion 1 — a touched tile reads .selected, and reverts on release

    func testATileInFlightReadsSelectedAndOffsetAndRevertsOnRelease() throws {
        // A lone tile: its resting state is `.idle`, so `.selected` cannot be
        // mistaken for the neighbour-driven state.
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])
        let haptics = RecordedHaptics()
        let inFlight = try drag([home], anchor: home, haptics)

        let resting = BoardRender.cells(board: board, camera: Self.camera, in: Self.viewport)
        let atHome = try XCTUnwrap(resting.first { $0.coord == home })
        XCTAssertEqual(atHome.state, .idle)
        XCTAssertEqual(atHome.tilePoint, atHome.point)

        let lifted = BoardRender.cells(
            board: board, camera: Self.camera, in: Self.viewport,
            dragging: inFlight.origins, by: CGSize(width: 30, height: -12)
        )
        let carried = try XCTUnwrap(lifted.first { $0.coord == home })
        XCTAssertEqual(carried.state, .selected)
        // The CELL never moves — only the tile drawn on it.
        XCTAssertEqual(carried.point, atHome.point)
        XCTAssertEqual(carried.tilePoint?.x, atHome.point.x + 30)
        XCTAssertEqual(carried.tilePoint?.y, atHome.point.y - 12)

        // Release: the drag ends, the set empties, the state is a board fact again.
        _ = inFlight.drop(translation: .zero, on: board, camera: Self.camera, threshold: Self.threshold)
        let released = BoardRender.cells(board: board, camera: Self.camera, in: Self.viewport)
        XCTAssertEqual(released.first { $0.coord == home }?.state, .idle)
    }

    func testAReleasedTileWithANeighbourRevertsToPlacedNotIdle() throws {
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile), (Coord(row: 0, col: 1), Tile(letter: "B"))])
        let inFlight = try drag([home], anchor: home, RecordedHaptics())

        let lifted = BoardRender.cells(
            board: board, camera: Self.camera, in: Self.viewport, dragging: inFlight.origins
        )
        XCTAssertEqual(lifted.first { $0.coord == home }?.state, .selected)

        let released = BoardRender.cells(board: board, camera: Self.camera, in: Self.viewport)
        XCTAssertEqual(released.first { $0.coord == home }?.state, .placed)
    }

    func testAnEmptyCellNamedByTheDragSetStillDrawsAsAnEmptyCell() {
        let empty = Coord(row: 2, col: 2)
        let cells = BoardRender.cells(
            board: Board(), camera: Self.camera, in: Self.viewport,
            dragging: [empty], by: CGSize(width: 40, height: 40)
        )
        let cell = cells.first { $0.coord == empty }
        XCTAssertNotNil(cell)
        XCTAssertNil(cell?.state)
        XCTAssertNil(cell?.tilePoint)
        XCTAssertEqual(cell?.point, Self.camera.point(for: empty))
    }

    // MARK: - Criterion 2 — a snap moves the tile and keeps its UUID

    func testASnapMovesTheTileAndKeepsItsIdentity() throws {
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])
        let haptics = RecordedHaptics()
        let inFlight = try drag([home], anchor: home, haptics)

        // Exactly one cell to the right: the drop lands on that cell's centre.
        let after = inFlight.drop(
            translation: CGSize(width: 48, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )

        let landed = try XCTUnwrap(after.tile(at: Coord(row: 0, col: 1)))
        XCTAssertEqual(landed.id, tile.id, "the move recreated the tile instead of moving it")
        XCTAssertEqual(landed.letter, tile.letter)
        XCTAssertNil(after.tile(at: home), "the tile is still at the cell it left")
        XCTAssertEqual(after.placementList.count, 1)
        XCTAssertEqual(haptics.events, [.pickup, .snap])
    }

    func testTheIdentityCheckHasTeeth() {
        // Two tiles of the same letter are different tiles. Without this, the
        // assertion above would pass against an implementation that rebuilt the
        // tile at its destination.
        XCTAssertNotEqual(Tile(letter: "A").id, Tile(letter: "A").id)
    }

    func testASnapWorksAtNegativeRowsAndColumns() throws {
        let tile = Tile(letter: "Q")
        let home = Coord(row: -7, col: -13)
        let board = Self.board([(home, tile)])
        let inFlight = try drag([home], anchor: home, RecordedHaptics())

        let after = inFlight.drop(
            translation: CGSize(width: -48, height: -48),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        let landed = try XCTUnwrap(after.tile(at: Coord(row: -8, col: -14)))
        XCTAssertEqual(landed.id, tile.id)
        XCTAssertNil(after.tile(at: home))
    }

    func testADropOnItsOwnCellSnapsAndChangesNothing() throws {
        let tile = Tile(letter: "A")
        let home = Coord(row: 3, col: 4)
        let board = Self.board([(home, tile)])
        let haptics = RecordedHaptics()
        let inFlight = try drag([home], anchor: home, haptics)

        let after = inFlight.drop(
            translation: .zero, on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(after, board)
        XCTAssertEqual(after.tile(at: home)?.id, tile.id)
        // Nothing was refused, so this is a landing, not a rejection.
        XCTAssertEqual(haptics.events, [.pickup, .snap])
    }

    // MARK: - Criterion 3 — a refused drop leaves the board exactly as it was

    func testADropOnAnOccupiedCellIsRefusedAndTheBoardIsUntouched() throws {
        let mover = Tile(letter: "A")
        let sitter = Tile(letter: "B")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, mover), (Coord(row: 0, col: 1), sitter)])
        let before = board.placementList
        let haptics = RecordedHaptics()
        let inFlight = try drag([home], anchor: home, haptics)

        let after = inFlight.drop(
            translation: CGSize(width: 48, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )

        XCTAssertEqual(after, board)
        XCTAssertEqual(after.placementList, before)
        XCTAssertEqual(after.tile(at: Coord(row: 0, col: 1))?.id, sitter.id)
        XCTAssertEqual(after.tile(at: home)?.id, mover.id)
        XCTAssertEqual(haptics.events, [.pickup, .reject])
    }

    func testADropBeyondTheThresholdIsRefusedAndTheBoardIsUntouched() throws {
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])
        let before = board.placementList
        let haptics = RecordedHaptics()
        let inFlight = try drag([home], anchor: home, haptics)

        // Halfway between two cell centres: 24pt from either, past a 22 reach.
        let after = inFlight.drop(
            translation: CGSize(width: 24, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(after, board)
        XCTAssertEqual(after.placementList, before)
        XCTAssertEqual(haptics.events, [.pickup, .reject])
    }

    func testJustInsideTheThresholdLandsAndJustOutsideIsRefused() throws {
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])
        let target = Coord(row: 0, col: 1)

        // Cell centres are 48 apart. A translation of 27 leaves the anchor
        // centre 21 short of the next centre; 25 leaves it 23 short.
        let inside = try drag([home], anchor: home, RecordedHaptics())
        let landed = inside.drop(
            translation: CGSize(width: 27, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(landed.tile(at: target)?.id, tile.id, "21pt is inside a 22pt reach")

        let outside = try drag([home], anchor: home, RecordedHaptics())
        let refused = outside.drop(
            translation: CGSize(width: 25, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(refused, board, "23pt is outside a 22pt reach")
    }

    func testTheThresholdIsActuallyConsulted() throws {
        // Teeth for the pair above: the same translation has to flip on the
        // threshold alone, or `drop` is ignoring the parameter and both
        // assertions are being carried by something else.
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])
        let translation = CGSize(width: 27, height: 0)

        let generous = try drag([home], anchor: home, RecordedHaptics())
        XCTAssertNotEqual(
            generous.drop(translation: translation, on: board, camera: Self.camera, threshold: 22),
            board
        )
        let strict = try drag([home], anchor: home, RecordedHaptics())
        XCTAssertEqual(
            strict.drop(translation: translation, on: board, camera: Self.camera, threshold: 1),
            board
        )
    }

    func testANonFiniteTranslationIsRefusedRatherThanTrapping() throws {
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])

        for bad: CGSize in [CGSize(width: CGFloat.nan, height: 0), CGSize(width: 0, height: CGFloat.nan),
                    CGSize(width: CGFloat.infinity, height: 0), CGSize(width: 0, height: -CGFloat.infinity)] {
            let haptics = RecordedHaptics()
            let inFlight = try drag([home], anchor: home, haptics)
            let after = inFlight.drop(
                translation: bad, on: board, camera: Self.camera, threshold: Self.threshold
            )
            XCTAssertEqual(after, board, "a non-finite translation changed the board")
            XCTAssertEqual(haptics.events, [.pickup, .reject])
        }
    }

    func testAnAstronomicalTranslationIsRefusedRatherThanSnappingToTheOrigin() throws {
        // `camera.coord(at:)` answers Coord(0, 0) for anything it cannot index.
        // A tile parked away from the origin, dropped a billion cells out, must
        // be refused — not teleported home on that fallback.
        let mover = Tile(letter: "A")
        let home = Coord(row: 5, col: 5)
        let board = Self.board([(home, mover)])

        for bad: CGSize in [CGSize(width: 1e300, height: 0), CGSize(width: -1e300, height: 1e300),
                    CGSize(width: CGFloat.greatestFiniteMagnitude, height: 0)] {
            let haptics = RecordedHaptics()
            let inFlight = try drag([home], anchor: home, haptics)
            let after = inFlight.drop(
                translation: bad, on: board, camera: Self.camera, threshold: Self.threshold
            )
            XCTAssertEqual(after, board)
            XCTAssertNil(after.tile(at: Coord(row: 0, col: 0)), "the drop snapped to the origin fallback")
            XCTAssertEqual(haptics.events, [.pickup, .reject])
        }
    }

    func testAGenerousThresholdStillWillNotSnapToTheUnindexableFallbackCell() throws {
        // The reach check alone does NOT cover this: the fallback cell really
        // is 1e300 away and this threshold really is larger than that, so a
        // drop measured on distance alone would accept it and teleport the tile
        // to Coord(0, 0). The cell-proximity guard is the only thing refusing
        // it, which is what makes that guard load-bearing rather than a
        // second copy of the reach check.
        let mover = Tile(letter: "A")
        let home = Coord(row: 5, col: 5)
        let board = Self.board([(home, mover)])
        let inFlight = try drag([home], anchor: home, RecordedHaptics())

        let after = inFlight.drop(
            translation: CGSize(width: 1e300, height: 1e300),
            on: board, camera: Self.camera, threshold: .greatestFiniteMagnitude
        )
        XCTAssertEqual(after, board)
        XCTAssertNil(after.tile(at: Coord(row: 0, col: 0)), "the drop snapped to the origin fallback")
        XCTAssertEqual(after.tile(at: home)?.id, mover.id)
    }

    func testANonFiniteCameraPanIsRefusedRatherThanTrapping() throws {
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])
        let broken = BoardCamera(pan: CGSize(width: CGFloat.nan, height: 0), zoom: 1, baseCellSize: 48)
        let inFlight = try drag([home], anchor: home, RecordedHaptics())

        XCTAssertEqual(
            inFlight.drop(translation: .zero, on: board, camera: broken, threshold: Self.threshold),
            board
        )
    }

    func testANonFiniteThresholdIsRefused() throws {
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])

        for bad: CGFloat in [.nan, .infinity, -1] {
            let inFlight = try drag([home], anchor: home, RecordedHaptics())
            XCTAssertEqual(
                inFlight.drop(
                    translation: CGSize(width: 48, height: 0),
                    on: board, camera: Self.camera, threshold: bad
                ),
                board
            )
        }
    }

    func testADropThatWouldOverflowACoordIsRefusedWholeAndTheBoardIsUntouched() throws {
        let edge = Coord(row: Int.max, col: 0)
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(edge, Tile(letter: "Z")), (home, Tile(letter: "A"))])
        let before = board.placementList
        let haptics = RecordedHaptics()
        // Both tiles travel together, so the whole move has to fail on the one
        // origin that cannot be stepped down a row.
        let inFlight = try drag([edge, home], anchor: home, haptics)

        let after = inFlight.drop(
            translation: CGSize(width: 0, height: 48),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(after, board)
        XCTAssertEqual(after.placementList, before)
        XCTAssertEqual(haptics.events, [.pickup, .reject])
    }

    // MARK: - Criterion 4 — one pickup, and one landing-or-refusal, per drag

    func testPickupFiresOnceHoweverManyUpdatesArrive() throws {
        let tile = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, tile)])
        let haptics = RecordedHaptics()

        // The view's own loop shape: the drag object is built the first time
        // and carried after that, and the render is recomputed every frame.
        var inFlight: TileDrag?
        for step in 0..<64 {
            if inFlight == nil {
                inFlight = TileDrag(origins: [home], anchor: home, haptics: haptics)
            }
            _ = BoardRender.cells(
                board: board, camera: Self.camera, in: Self.viewport,
                dragging: inFlight?.origins ?? [], by: CGSize(width: CGFloat(step), height: 0)
            )
        }
        XCTAssertEqual(haptics.events, [.pickup], "pickup fired off the update path")

        _ = try XCTUnwrap(inFlight).drop(
            translation: CGSize(width: 48, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(haptics.events, [.pickup, .snap])
        XCTAssertEqual(haptics.events.filter { $0 == .pickup }.count, 1)
        XCTAssertEqual(haptics.events.filter { $0 == .snap }.count, 1)
        XCTAssertEqual(haptics.events.filter { $0 == .reject }.count, 0)
    }

    func testTheRecordingDoubleHasTeeth() {
        // If the double dropped events on the floor, every haptic assertion
        // above would pass vacuously.
        let haptics = RecordedHaptics()
        XCTAssertEqual(haptics.events, [])
        for event in BoardHapticEvent.allCases { haptics.fire(event) }
        XCTAssertEqual(haptics.events, [.pickup, .snap, .reject])
        haptics.fire(.pickup)
        XCTAssertEqual(haptics.events.count, 4)
    }

    func testTheThreeKindsOfDragEachFireTheirOwnPairOfEvents() throws {
        let mover = Tile(letter: "A")
        let home = Coord(row: 0, col: 0)
        let board = Self.board([(home, mover), (Coord(row: 0, col: 1), Tile(letter: "B"))])

        let landing = RecordedHaptics()
        _ = try drag([home], anchor: home, landing).drop(
            translation: CGSize(width: 0, height: 48),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(landing.events, [.pickup, .snap])

        let onTaken = RecordedHaptics()
        _ = try drag([home], anchor: home, onTaken).drop(
            translation: CGSize(width: 48, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(onTaken.events, [.pickup, .reject])

        let tooFar = RecordedHaptics()
        _ = try drag([home], anchor: home, tooFar).drop(
            translation: CGSize(width: 0, height: 24),
            on: board, camera: Self.camera, threshold: Self.threshold
        )
        XCTAssertEqual(tooFar.events, [.pickup, .reject])
    }

    func testAPanGrabBuildsNoDragAndFiresNothing() {
        let haptics = RecordedHaptics()
        XCTAssertNil(TileDrag(grab: .pan, haptics: haptics))
        XCTAssertEqual(haptics.events, [])
    }

    func testATileGrabBuildsAOneCoordDragAtTheGrabbedCell() throws {
        let tile = Tile(letter: "A")
        let coord = Coord(row: -4, col: 9)
        let haptics = RecordedHaptics()
        let inFlight = try XCTUnwrap(TileDrag(grab: .tile(tile, at: coord), haptics: haptics))

        XCTAssertEqual(inFlight.origins, [coord])
        XCTAssertEqual(inFlight.anchor, coord)
        XCTAssertEqual(haptics.events, [.pickup])
    }

    func testAnAnchorOutsideTheCarriedSetBuildsNothingAndFiresNothing() {
        let haptics = RecordedHaptics()
        XCTAssertNil(
            TileDrag(
                origins: [Coord(row: 0, col: 0)],
                anchor: Coord(row: 5, col: 5),
                haptics: haptics
            )
        )
        XCTAssertNil(TileDrag(origins: [], anchor: Coord(row: 0, col: 0), haptics: haptics))
        XCTAssertEqual(haptics.events, [])
    }

    // MARK: - The set-of-coords model, which item 8 widens

    func testEveryCarriedCoordMovesByTheOneDeltaAndKeepsItsIdentity() throws {
        let tiles = [Tile(letter: "W"), Tile(letter: "I"), Tile(letter: "N")]
        let homes = (0..<3).map { Coord(row: 0, col: $0) }
        let board = Self.board(Array(zip(homes, tiles)))
        let haptics = RecordedHaptics()
        // Anchored on the leftmost tile, sliding right by one: two of the three
        // destinations are cells this same drag is vacating.
        let inFlight = try drag(Set(homes), anchor: homes[0], haptics)

        let after = inFlight.drop(
            translation: CGSize(width: 48, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )

        XCTAssertEqual(after.placementList.count, 3)
        XCTAssertNil(after.tile(at: homes[0]))
        for (offset, tile) in tiles.enumerated() {
            XCTAssertEqual(after.tile(at: Coord(row: 0, col: offset + 1))?.id, tile.id)
        }
        XCTAssertEqual(haptics.events, [.pickup, .snap])
    }

    func testAGroupIsRefusedWholeWhenAnySingleDestinationIsTaken() throws {
        let tiles = [Tile(letter: "W"), Tile(letter: "I"), Tile(letter: "N")]
        let homes = (0..<3).map { Coord(row: 0, col: $0) }
        let blocker = Tile(letter: "X")
        let board = Self.board(Array(zip(homes, tiles)) + [(Coord(row: 0, col: 3), blocker)])
        let before = board.placementList
        let haptics = RecordedHaptics()
        let inFlight = try drag(Set(homes), anchor: homes[0], haptics)

        let after = inFlight.drop(
            translation: CGSize(width: 48, height: 0),
            on: board, camera: Self.camera, threshold: Self.threshold
        )

        XCTAssertEqual(after, board, "a group move landed partially")
        XCTAssertEqual(after.placementList, before)
        XCTAssertEqual(haptics.events, [.pickup, .reject])
    }

    func testEveryCarriedCoordReadsSelectedWhileTheGroupIsInFlight() throws {
        let homes = (0..<3).map { Coord(row: 0, col: $0) }
        let board = Self.board(homes.map { ($0, Tile(letter: "A")) })
        let loose = Coord(row: 6, col: 6)
        var withStranger = board
        try withStranger.place(Tile(letter: "Z"), at: loose)
        let inFlight = try drag(Set(homes), anchor: homes[1], RecordedHaptics())

        let cells = BoardRender.cells(
            board: withStranger, camera: Self.camera, in: Self.viewport,
            dragging: inFlight.origins, by: CGSize(width: 10, height: 10)
        )
        for home in homes {
            XCTAssertEqual(cells.first { $0.coord == home }?.state, .selected)
        }
        // A tile the drag is not carrying is untouched by it.
        let stranger = try XCTUnwrap(cells.first { $0.coord == loose })
        XCTAssertEqual(stranger.state, .idle)
        XCTAssertEqual(stranger.tilePoint, stranger.point)
    }

    // MARK: - The draw list survives the same degenerate geometry the drop does

    func testANonFiniteDragTranslationDrawsTheTileWhereItStartedRatherThanNowhere() throws {
        let home = Coord(row: 1, col: 1)
        let board = Self.board([(home, Tile(letter: "A"))])
        let inFlight = try drag([home], anchor: home, RecordedHaptics())

        for bad: CGSize in [CGSize(width: CGFloat.nan, height: 0), CGSize(width: 0, height: CGFloat.infinity)] {
            let cells = BoardRender.cells(
                board: board, camera: Self.camera, in: Self.viewport,
                dragging: inFlight.origins, by: bad
            )
            let cell = try XCTUnwrap(cells.first { $0.coord == home })
            XCTAssertEqual(cell.state, .selected)
            XCTAssertEqual(cell.tilePoint, cell.point)
        }
    }

    func testAnEmptyDragSetLeavesTheDrawListExactlyAsItWasBeforeThisItem() {
        let board = Self.board([
            (Coord(row: 0, col: 0), Tile(letter: "A")),
            (Coord(row: 0, col: 1), Tile(letter: "B")),
            (Coord(row: 4, col: 4), Tile(letter: "C")),
        ])
        XCTAssertEqual(
            BoardRender.cells(board: board, camera: Self.camera, in: Self.viewport),
            BoardRender.cells(
                board: board, camera: Self.camera, in: Self.viewport,
                dragging: [], by: CGSize(width: 99, height: 99)
            )
        )
    }
}
