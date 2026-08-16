import XCTest
import Foundation
import CoreGraphics
import WillagramsRules

/// Free placement: tiles lie anywhere on a bare table, and letters snap flush
/// into one block the moment they connect.
///
/// The whole model is one rule — every tile in a connected cluster carries the
/// same sub-cell offset — so these assert that rule and the two things that
/// break if it is only half wired: that a scattered tile is still grabbable
/// across the face it is DRAWN over, and that the engine's lattice is untouched
/// underneath.
final class BoardPlacementTests: XCTestCase {

    private static let dictionary = EnableWordList(words: ["WILL", "AM"])

    /// A tile whose scatter is known, because the offset is read out of the
    /// id's first two bytes. `Tile(letter:)` alone would make every assertion
    /// below depend on a random UUID: "these two offsets differ" would pass on
    /// luck, and the overhang the hit-test regression needs might not happen at
    /// all. `seed` and `255 - seed` also put the two axes on opposite sides.
    private static func tile(_ letter: Character, _ seed: UInt8) -> Tile {
        Tile(
            id: UUID(uuid: (seed, 255 &- seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            letter: letter
        )
    }

    /// A run of four, a separate pair, and two lone tiles — three clusters plus
    /// one, so "shared within a cluster, independent between them" has
    /// something to be true of. Every seed distinct, so no two clusters can
    /// scatter alike by accident.
    private static func board() -> Board {
        var board = Board()
        for (index, letter) in "WILL".enumerated() {
            try? board.place(tile(letter, UInt8(10 + index * 20)), at: Coord(row: 0, col: index))
        }
        try? board.place(tile("A", 130), at: Coord(row: 4, col: 0))
        try? board.place(tile("M", 150), at: Coord(row: 5, col: 0))
        try? board.place(tile("Z", 200), at: Coord(row: 8, col: 8))
        try? board.place(tile("Q", 240), at: Coord(row: 8, col: 12))
        return board
    }

    private static func model(_ board: Board) -> BoardModel {
        BoardModel(board: board, against: dictionary)
    }

    private static func offset(_ model: BoardModel, _ board: Board, _ coord: Coord) throws -> CGSize {
        let tile = try XCTUnwrap(board.tile(at: coord), "no tile at \(coord)")
        return try XCTUnwrap(model.tileOffsets[tile.id], "no offset published for \(coord)")
    }

    // MARK: - The one rule

    func testEveryTileInAClusterCarriesTheSameOffset() throws {
        let board = Self.board()
        let model = Self.model(board)

        let run = try (0..<4).map { try Self.offset(model, board, Coord(row: 0, col: $0)) }
        for (index, offset) in run.enumerated() {
            XCTAssertEqual(offset, run[0], "letter \(index) of the run sits off its own word")
        }

        XCTAssertEqual(
            try Self.offset(model, board, Coord(row: 4, col: 0)),
            try Self.offset(model, board, Coord(row: 5, col: 0)),
            "a vertical pair does not share one offset"
        )
    }

    /// The other half of the same rule, and the one that makes the surface read
    /// as a table: unconnected tiles must NOT line up with each other.
    func testSeparateClustersScatterIndependently() throws {
        let board = Self.board()
        let model = Self.model(board)

        let run = try Self.offset(model, board, Coord(row: 0, col: 0))
        let pair = try Self.offset(model, board, Coord(row: 4, col: 0))
        let lone = try Self.offset(model, board, Coord(row: 8, col: 8))
        let other = try Self.offset(model, board, Coord(row: 8, col: 12))

        // Pairwise distinct, not merely "not all equal": the fixture seeds every
        // cluster differently on purpose, so anything less would let three of
        // the four line up and still pass.
        XCTAssertEqual(
            Set([run, pair, lone, other].map { "\($0.width),\($0.height)" }).count, 4,
            "two clusters landed on the same offset, so the board still reads as a grid"
        )
    }

    /// Connecting two letters IS the snap. Nothing animates it and nothing
    /// special-cases it — the loose tile simply joins a cluster and adopts its
    /// offset, which is the visible "letters get forced into a grid".
    func testAJoiningTileAdoptsTheClusterOffset() throws {
        var board = Self.board()
        let loose = try XCTUnwrap(board.tile(at: Coord(row: 8, col: 8)))
        let before = try Self.offset(Self.model(board), board, Coord(row: 8, col: 8))

        // Move it up against the run's last letter.
        XCTAssertNotNil(board.remove(at: Coord(row: 8, col: 8)))
        try board.place(loose, at: Coord(row: 0, col: 4))

        let after = Self.model(board)
        XCTAssertEqual(
            after.tileOffsets[loose.id],
            try Self.offset(after, board, Coord(row: 0, col: 0)),
            "a tile that joined a word did not settle into the word's alignment"
        )
        XCTAssertNotEqual(after.tileOffsets[loose.id], before, "the join changed nothing")
    }

    /// The offsets have to be a function of the board alone: `Set` iteration
    /// order is not stable, and a per-process hash seed would re-scatter the
    /// same board on every launch.
    func testTheSameBoardScattersIdenticallyEveryTime() throws {
        let board = Self.board()
        XCTAssertEqual(Self.model(board).tileOffsets, Self.model(board).tileOffsets)
    }

    /// Bounded well inside the `BoardLayout.step` gap. If two clusters could
    /// each drift half a cell they could be drawn touching while the checker
    /// reads them as separate — the engine would then refuse a word the player
    /// can plainly see, with nothing on screen to explain it.
    func testTheScatterNeverCarriesATileIntoItsNeighbour() throws {
        XCTAssertLessThan(BoardModel.scatter, 0.5)
        let model = Self.model(Self.board())
        for offset in model.tileOffsets.values {
            XCTAssertLessThanOrEqual(abs(offset.width), BoardModel.scatter)
            XCTAssertLessThanOrEqual(abs(offset.height), BoardModel.scatter)
        }
    }

    /// The engine never sees any of this. Words, connectivity and the Draw gate
    /// are decided on whole `Coord`s exactly as before.
    func testTheLatticeUnderneathIsUntouched() throws {
        let board = Self.board()
        let model = Self.model(board)
        XCTAssertEqual(model.validation.tileCount, 8)
        XCTAssertTrue(model.validation.invalidWords.isEmpty, "WILL and AM are both in the list")
        XCTAssertEqual(board.tile(at: Coord(row: 0, col: 0))?.letter, "W")
    }

    // MARK: - Grabbable where it is drawn

    /// The regression this whole file exists for. A scattered tile overhangs a
    /// neighbouring cell; a hit test that indexed by cell would answer with that
    /// empty neighbour and the tile would refuse to lift along that edge —
    /// dead input exactly where the board looks solid.
    func testATouchOnTheOverhangingFaceStillGrabsTheTile() throws {
        let camera = BoardCamera()
        let size = camera.cellSize
        var board = Board()
        // Alone, and seeded so it leans the full scatter right and up — the
        // worst case, and the one a cell-indexed hit test gets wrong.
        let tile = Self.tile("Z", 255)
        try board.place(tile, at: Coord(row: 0, col: 0))
        let model = Self.model(board)
        let offset = try XCTUnwrap(model.tileOffsets[tile.id])
        XCTAssertEqual(offset.width, BoardModel.scatter, accuracy: 0.001)
        XCTAssertEqual(offset.height, -BoardModel.scatter, accuracy: 0.001)

        // A point just inside the drawn face on the side it leans toward. With
        // a non-zero offset this lies outside the tile's own CELL.
        let leanX = offset.width >= 0 ? size - 1 : 1.0
        let leanY = offset.height >= 0 ? size - 1 : 1.0
        let point = CGPoint(
            x: camera.point(for: Coord(row: 0, col: 0)).x + offset.width * size + leanX,
            y: camera.point(for: Coord(row: 0, col: 0)).y + offset.height * size + leanY
        )

        // The teeth: this point is on the tile's face but NOT in its cell, so
        // the old cell-indexed hit test answered with an empty neighbour and
        // decided `.pan`. If this ever stops holding, the two assertions below
        // pass without exercising anything.
        XCTAssertNotEqual(
            camera.coord(at: point), Coord(row: 0, col: 0),
            "the fixture no longer overhangs its cell, so this test proves nothing"
        )

        let hit = BoardHit.tile(under: point, on: board, offsets: model.tileOffsets, camera: camera)
        XCTAssertEqual(hit?.coord, Coord(row: 0, col: 0), "the drawn face of the tile is not grabbable")

        let drag = BoardGesture.Drag(
            at: point, in: board, camera: camera, offsets: model.tileOffsets
        )
        XCTAssertEqual(drag.grab, .tile(tile, at: Coord(row: 0, col: 0)), "the grab decided pan on a tile's face")
    }

    /// And the converse: bare table is still a pan, so scattering does not make
    /// the whole surface grabby.
    func testBareSurfaceIsStillAPan() throws {
        let camera = BoardCamera()
        let board = Self.board()
        let model = Self.model(board)
        // Two lattice cells clear of anything, which no 0.4-cell scatter reaches.
        let empty = CGPoint(
            x: camera.point(for: Coord(row: 2, col: 2)).x,
            y: camera.point(for: Coord(row: 2, col: 2)).y
        )
        XCTAssertNil(BoardHit.tile(under: empty, on: board, offsets: model.tileOffsets, camera: camera))
        XCTAssertEqual(
            BoardGesture.Drag(at: empty, in: board, camera: camera, offsets: model.tileOffsets).grab,
            .pan
        )
    }

    func testANonFiniteTouchGrabsNothing() throws {
        let board = Self.board()
        let model = Self.model(board)
        for bad in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity)] {
            XCTAssertNil(
                BoardHit.tile(under: bad, on: board, offsets: model.tileOffsets, camera: BoardCamera())
            )
        }
    }

    // MARK: - Drawn where the offset says

    /// The offset is in CELL units, so the scatter holds its shape through a
    /// zoom instead of sliding the tiles off their cells.
    func testTheOffsetIsInCellUnitsSoItScalesWithTheZoom() throws {
        var board = Board()
        let tile = Tile(letter: "Z")
        try board.place(tile, at: Coord(row: 0, col: 0))
        let offsets = [tile.id: CGSize(width: 0.25, height: -0.25)]

        for zoom in [CGFloat(1), 1.5, 0.5] {
            let camera = BoardCamera(zoom: zoom)
            let size = camera.cellSize
            let origin = BoardHit.origin(
                of: Coord(row: 0, col: 0), tile: tile, offsets: offsets, camera: camera
            )
            let base = camera.point(for: Coord(row: 0, col: 0))
            XCTAssertEqual(origin.x - base.x, 0.25 * size, accuracy: 0.001)
            XCTAssertEqual(origin.y - base.y, -0.25 * size, accuracy: 0.001)
        }
    }

    /// A tile with no published offset sits exactly on its cell, so a board
    /// drawn before the session has seeded still renders.
    func testAnUnknownTileSitsOnItsCell() throws {
        let tile = Tile(letter: "Z")
        let camera = BoardCamera()
        XCTAssertEqual(
            BoardHit.origin(of: Coord(row: 3, col: 4), tile: tile, offsets: [:], camera: camera),
            camera.point(for: Coord(row: 3, col: 4))
        )
    }

    /// A non-finite offset would put the tile at a point no renderer can use
    /// AND make every hit-test comparison false — drawn nowhere, grabbable
    /// nowhere. Its cell is the honest fallback.
    func testANonFiniteOffsetFallsBackToTheCell() throws {
        let tile = Tile(letter: "Z")
        let camera = BoardCamera()
        let offsets = [tile.id: CGSize(width: CGFloat.nan, height: 0)]
        XCTAssertEqual(
            BoardHit.origin(of: Coord(row: 0, col: 0), tile: tile, offsets: offsets, camera: camera),
            camera.point(for: Coord(row: 0, col: 0))
        )
    }

    /// The draw list carries the offset, and `point` stays the bare lattice
    /// position — telling those two apart is the whole model.
    func testTheDrawListSeparatesTheCellFromTheTile() throws {
        var board = Board()
        let tile = Tile(letter: "Z")
        try board.place(tile, at: Coord(row: 0, col: 0))
        let camera = BoardCamera()
        let offsets = [tile.id: CGSize(width: 0.3, height: 0.3)]

        let cells = BoardRender.cells(
            board: board, camera: camera,
            in: CGRect(x: 0, y: 0, width: 200, height: 200),
            offsets: offsets
        )
        let cell = try XCTUnwrap(cells.first { $0.tile?.id == tile.id })
        XCTAssertEqual(cell.point, camera.point(for: Coord(row: 0, col: 0)))
        XCTAssertEqual(
            cell.tilePoint,
            BoardHit.origin(of: Coord(row: 0, col: 0), tile: tile, offsets: offsets, camera: camera)
        )
        XCTAssertNotEqual(cell.tilePoint, cell.point)
    }

    /// A tile in flight draws from its OFFSET position plus the finger's
    /// travel, so picking one up does not snap it to its cell first.
    func testACarriedTileDragsFromWhereItWasDrawn() throws {
        var board = Board()
        let tile = Tile(letter: "Z")
        try board.place(tile, at: Coord(row: 0, col: 0))
        let camera = BoardCamera()
        let offsets = [tile.id: CGSize(width: 0.3, height: 0.3)]
        let travel = CGSize(width: 17, height: -9)

        let cells = BoardRender.cells(
            board: board, camera: camera,
            in: CGRect(x: 0, y: 0, width: 200, height: 200),
            dragging: [Coord(row: 0, col: 0)], by: travel, offsets: offsets
        )
        let cell = try XCTUnwrap(cells.first { $0.tile?.id == tile.id })
        let resting = BoardHit.origin(
            of: Coord(row: 0, col: 0), tile: tile, offsets: offsets, camera: camera
        )
        XCTAssertEqual(cell.tilePoint?.x, resting.x + travel.width)
        XCTAssertEqual(cell.tilePoint?.y, resting.y + travel.height)
    }

    // MARK: - Sweeping hits drawn tiles

    /// The sweep has to cross the tiles the player can SEE. Sampling by cell
    /// would sweep up an empty cell a tile leans over and miss the tile itself.
    func testASweepPicksUpTheTileUnderTheFingerNotTheCell() throws {
        var board = Board()
        let tile = Tile(letter: "Z")
        try board.place(tile, at: Coord(row: 0, col: 0))
        let camera = BoardCamera()
        let size = camera.cellSize
        let offsets = [tile.id: CGSize(width: 0.4, height: 0)]
        let base = camera.point(for: Coord(row: 0, col: 0))

        var selection = BoardSelection()
        selection.enter()
        // A short sweep across the drawn face, which begins beyond the cell's
        // own right edge.
        let y = base.y + size / 2
        let crossed = selection.paint(
            from: CGPoint(x: base.x + size * 0.9, y: y),
            to: CGPoint(x: base.x + size * 1.3, y: y),
            on: board, camera: camera, offsets: offsets
        )
        XCTAssertGreaterThan(crossed, 0, "the sweep crossed the drawn tile and picked up nothing")
        XCTAssertTrue(selection.contains(Coord(row: 0, col: 0)))
    }
}

/// Tuning follow-up: the two reasons a drag reverted or landed a cell wide of
/// where it looked, both of which arrived WITH the offsets and neither of which
/// any existing test covered.
final class BoardPlacementDropTests: XCTestCase {

    private final class SilentHaptics: BoardHaptics, @unchecked Sendable {
        func fire(_ event: BoardHapticEvent) {}
    }


    /// The real `DesignTokens.Motion.snapThreshold`, read out of the source.
    ///
    /// `DesignTokens` is a SwiftUI file this package cannot import, and a
    /// literal copied here would let the token drift back to a value that
    /// reverts drops while these stayed green. Parsing it keeps the token the
    /// one source of truth for the number these tests depend on.
    private static let snapThreshold: CGFloat = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Cases
            .deletingLastPathComponent()   // BoardTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Willagrams/Style/DesignTokens.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let match = try? NSRegularExpression(pattern: #"snapThreshold:\s*CGFloat\s*=\s*([0-9.]+)"#)
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let value = Double(text[range])
        else { return 0 }
        return CGFloat(value)
    }()

    private static func tile(_ letter: Character, _ seed: UInt8) -> Tile {
        Tile(
            id: UUID(uuid: (seed, 255 &- seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            letter: letter
        )
    }

    /// The reported "some letters won't let me connect".
    ///
    /// Two clusters leaning opposite ways: the target sits 0.4 cells right of
    /// its lattice, the carried tile 0.4 cells left of its own. Releasing the
    /// carried tile where it LOOKS flush against the target therefore leaves it
    /// 0.8 cells off its own lattice position — and measuring that from the
    /// bare cell puts the drop 1.3 cells along, so it indexes the cell BEYOND
    /// the one the player aimed at. The tile lands with a gap and does not join
    /// the word, which is the bug seen by hand.
    func testATileReleasedWhereItLooksFlushLandsInTheCellItLooksFlushWith() throws {
        let target = Self.tile("W", 10)
        let carried = Self.tile("E", 200)
        var board = Board()
        try board.place(target, at: Coord(row: 0, col: 0))
        try board.place(carried, at: Coord(row: 0, col: 5))

        let camera = BoardCamera()
        let size = camera.cellSize
        let offsets: [UUID: CGSize] = [
            target.id: CGSize(width: 0.4, height: 0),
            carried.id: CGSize(width: -0.4, height: 0),
        ]

        // Where the finger has to let go for the carried tile to be DRAWN
        // exactly one cell right of the target, sharing its lean.
        let from = BoardHit.origin(of: Coord(row: 0, col: 5), tile: carried, offsets: offsets, camera: camera)
        let to = BoardHit.origin(of: Coord(row: 0, col: 1), tile: target, offsets: offsets, camera: camera)
        let translation = CGSize(width: to.x - from.x, height: to.y - from.y)

        let drag = try XCTUnwrap(
            TileDrag(origins: [Coord(row: 0, col: 5)], anchor: Coord(row: 0, col: 5), haptics: SilentHaptics())
        )
        let landed = drag.landed(
            translation: translation, on: board, camera: camera,
            threshold: Self.snapThreshold, offsets: offsets
        )
        XCTAssertEqual(
            landed, [Coord(row: 0, col: 1)],
            "a tile released looking flush against a word did not land beside it"
        )

        // Teeth: the same release measured from the bare lattice — what the
        // drag did before the offsets were threaded through — lands somewhere
        // else entirely. If this ever stops differing, the assertion above has
        // stopped testing the fix.
        let blind = drag.landed(
            translation: translation, on: board, camera: camera,
            threshold: Self.snapThreshold, offsets: [:]
        )
        XCTAssertNotEqual(blind, [Coord(row: 0, col: 1)])
        XCTAssertGreaterThan(size, 0)
    }

    /// The reported "dragging quickly reverts to where it started".
    ///
    /// Nothing about the drop is wrong here — it is simply released nearer a
    /// cell's corner than its centre. The old 22pt window against a 48pt cell
    /// accepted an acceptance circle covering two thirds of the cell's area, so
    /// a release anywhere in the remaining third reverted, and the faster the
    /// drag the likelier it fell there.
    func testAReleaseNearACellsCornerStillLands() throws {
        let moving = Self.tile("W", 10)
        var board = Board()
        try board.place(moving, at: Coord(row: 0, col: 0))

        let camera = BoardCamera()
        let size = camera.cellSize
        // 0.45 of a cell along both axes: reach ≈ 30pt, inside the cell and
        // well outside the old 22pt window.
        let translation = CGSize(width: size * 1.45, height: size * 0.45)
        let reach = hypot(size * 0.45, size * 0.45)
        XCTAssertGreaterThan(reach, 22, "this release no longer sits in the band that used to revert")
        XCTAssertLessThan(reach, size / 2 * 2.squareRoot(), "this release is not inside the cell")

        let drag = try XCTUnwrap(
            TileDrag(origins: [Coord(row: 0, col: 0)], anchor: Coord(row: 0, col: 0), haptics: SilentHaptics())
        )
        let landed = drag.landed(
            translation: translation, on: board, camera: camera,
            threshold: Self.snapThreshold, offsets: [:]
        )
        XCTAssertEqual(landed, [Coord(row: 0, col: 1)], "a release inside the cell reverted")
    }

    /// A blob must not move because something joined it.
    ///
    /// The offset used to be derived from the cluster's lowest coord in reading
    /// order, so a letter landing above or left of a word renamed the whole
    /// cluster and slid every letter in it to a new offset — the word visibly
    /// jumped at the instant it was completed. The offset the cluster already
    /// carries wins instead, and the joining letter adopts it.
    func testAWordDoesNotMoveWhenALetterJoinsItFromTheLeft() throws {
        let dictionary = EnableWordList(words: ["WILL", "AM"])
        var board = Board()
        // "ILL" at cols 1...3, so a "W" joining at col 0 becomes the cluster's
        // new lowest coord — exactly the case that used to rename it.
        for (index, letter) in "ILL".enumerated() {
            try board.place(Self.tile(letter, UInt8(60 + index * 20)), at: Coord(row: 0, col: index + 1))
        }
        let joiner = Self.tile("W", 250)
        try board.place(joiner, at: Coord(row: 4, col: 1))

        var model = BoardModel(board: board, against: dictionary)
        let before = model.tileOffsets
        let word = try (1...3).map { try XCTUnwrap(board.tile(at: Coord(row: 0, col: $0))) }
        let settled = try XCTUnwrap(before[word[0].id])

        let camera = BoardCamera()
        let size = camera.cellSize
        model.began(.tile(joiner, at: Coord(row: 4, col: 1)), haptics: SilentHaptics())
        let next = model.commit(
            translation: CGSize(width: -size, height: -4 * size),
            on: board, camera: camera,
            threshold: Self.snapThreshold, against: dictionary
        )

        XCTAssertNotNil(next.tile(at: Coord(row: 0, col: 0)), "the joining letter did not land beside the word")
        for tile in word {
            XCTAssertEqual(
                model.tileOffsets[tile.id], settled,
                "the word moved because a letter joined it"
            )
        }
        XCTAssertEqual(
            model.tileOffsets[joiner.id], settled,
            "the joining letter did not adopt the word's offset"
        )
    }
}
