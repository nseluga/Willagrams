import XCTest
import Foundation
import CoreGraphics
import WillagramsRules

private final class Feel: BoardHaptics, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BoardHapticEvent] = []
    var events: [BoardHapticEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    func fire(_ event: BoardHapticEvent) { lock.lock(); defer { lock.unlock() }; stored.append(event) }
}

/// The fast-drag-flies-home fix: the drop is measured from where the held tile
/// is DRAWN (lifted by `Motion.tileLift`, -8pt, which BrandTile applies to a
/// `.selected` tile), and a single tile released on an occupied cell lands on
/// the nearest free cell within one cell rather than flying home.
final class BoardDragLiftTests: XCTestCase {

    /// Mirrors `DesignTokens.Motion.tileLift`; `BoardSourceTests` pins that the
    /// view passes the real token.
    private static let lift: CGFloat = -8

    private static func board(_ entries: [(Coord, Tile)]) -> Board {
        var board = Board()
        for (coord, tile) in entries { try? board.place(tile, at: coord) }
        return board
    }

    private static func camera(cell size: CGFloat) -> BoardCamera {
        let camera = BoardCamera(pan: .zero, zoom: size / 48, baseCellSize: 48)
        precondition(camera.cellSize == size)
        return camera
    }

    // MARK: - Measured from the lifted centre

    func testATileWhoseLiftedCentreIsInsideAnEmptyCellLandsThereAtPhoneCellSizes() throws {
        for size: CGFloat in [16, 24, 48] {
            let camera = Self.camera(cell: size)
            let home = Coord(row: 0, col: 0)
            let x = Coord(row: 2, col: 0)
            let below = Coord(row: 3, col: 0)
            // Lifted drawn centre 1pt above X's bottom edge; the un-lifted
            // centre is 7pt into the cell below X.
            let translation = CGSize(width: 0, height: 3 * size - 1 - size / 2 - Self.lift)

            for belowOccupied in [false, true] {
                let tile = Tile(letter: "A")
                var entries = [(home, tile)]
                if belowOccupied { entries.append((below, Tile(letter: "B"))) }
                let board = Self.board(entries)
                let feel = Feel()
                let drag = try XCTUnwrap(TileDrag(origins: [home], anchor: home, haptics: feel))

                let after = drag.drop(
                    translation: translation, on: board, camera: camera,
                    threshold: 22, lift: Self.lift
                )
                XCTAssertEqual(
                    after.tile(at: x)?.id, tile.id,
                    "size \(size), below occupied \(belowOccupied): the tile did not land where it was drawn"
                )
                XCTAssertEqual(feel.events, [.pickup, .snap])
                XCTAssertEqual(
                    drag.landed(translation: translation, on: board, camera: camera, threshold: 22, lift: Self.lift),
                    [x]
                )
            }
        }
    }

    // MARK: - One-cell forgiveness

    private static let target = Coord(row: 5, col: 5)
    private static let neighbours: [Coord] = (-1...1).flatMap { dr in
        (-1...1).compactMap { dc in
            dr == 0 && dc == 0 ? nil : Coord(row: 5 + dr, col: 5 + dc)
        }
    }

    func testASingleTileOnAnOccupiedCellLandsOnItsOneFreeNeighbour() throws {
        let camera = Self.camera(cell: 48)
        let home = Coord(row: 0, col: 0)
        let free = Coord(row: 6, col: 6)
        let mover = Tile(letter: "A")
        let blockers = ([Self.target] + Self.neighbours.filter { $0 != free }).map { ($0, Tile(letter: "B")) }
        let board = Self.board([(home, mover)] + blockers)
        let feel = Feel()
        let drag = try XCTUnwrap(TileDrag(origins: [home], anchor: home, haptics: feel))

        let after = drag.drop(
            translation: CGSize(width: 5 * 48, height: 5 * 48), on: board, camera: camera, threshold: 22
        )
        XCTAssertEqual(after.tile(at: free)?.id, mover.id, "forgiveness did not land the tile on the free neighbour")
        XCTAssertNil(after.tile(at: home))
        XCTAssertEqual(after.placementList.count, board.placementList.count)
        XCTAssertEqual(feel.events, [.pickup, .snap])
    }

    func testForgivenessPicksTheFreeNeighbourNearestTheReleasePoint() throws {
        let camera = Self.camera(cell: 48)
        let home = Coord(row: 0, col: 0)
        let mover = Tile(letter: "A")
        let board = Self.board([(home, mover), (Self.target, Tile(letter: "B"))])
        let feel = Feel()
        let drag = try XCTUnwrap(TileDrag(origins: [home], anchor: home, haptics: feel))
        // 20pt right of the target's centre: (5, 6) is nearest.
        let after = drag.drop(
            translation: CGSize(width: 5 * 48 + 20, height: 5 * 48), on: board, camera: camera, threshold: 22
        )
        XCTAssertEqual(after.tile(at: Coord(row: 5, col: 6))?.id, mover.id)
    }

    func testASingleTileWithAllEightNeighboursOccupiedReturnsHomeWithAReject() throws {
        let camera = Self.camera(cell: 48)
        let home = Coord(row: 0, col: 0)
        let mover = Tile(letter: "A")
        let blockers = ([Self.target] + Self.neighbours).map { ($0, Tile(letter: "B")) }
        let board = Self.board([(home, mover)] + blockers)
        let feel = Feel()
        let drag = try XCTUnwrap(TileDrag(origins: [home], anchor: home, haptics: feel))

        let after = drag.drop(
            translation: CGSize(width: 5 * 48, height: 5 * 48), on: board, camera: camera, threshold: 22
        )
        XCTAssertEqual(after, board, "a release with no free cell within one cell changed the board")
        XCTAssertEqual(feel.events, [.pickup, .reject])
    }

    func testAGroupReleasedPartlyOntoAnOccupiedCellIsRefusedWhole() throws {
        let camera = Self.camera(cell: 48)
        let a = Coord(row: 0, col: 0), b = Coord(row: 0, col: 1)
        // The ANCHOR's destination is the taken one, so forgiveness would
        // have something to shift if it ever applied to a group.
        let board = Self.board([(a, Tile(letter: "A")), (b, Tile(letter: "B")), (Coord(row: 3, col: 0), Tile(letter: "C"))])
        let feel = Feel()
        let drag = try XCTUnwrap(TileDrag(origins: [a, b], anchor: a, haptics: feel))

        let after = drag.drop(
            translation: CGSize(width: 0, height: 3 * 48), on: board, camera: camera, threshold: 22
        )
        XCTAssertEqual(after, board, "a group landed although one target was taken")
        XCTAssertEqual(feel.events, [.pickup, .reject])
    }
}
