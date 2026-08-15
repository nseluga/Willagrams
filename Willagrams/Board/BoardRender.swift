import Foundation
import CoreGraphics
import WillagramsRules

/// Every draw decision `BoardView` makes, with none of the drawing.
///
/// SwiftUI cannot be unit-tested headlessly in this repo, so the view is kept
/// dumb and this file owns the choices worth asserting on: which cells exist,
/// where they sit, which of them carry a tile, and how that tile reads. Pure
/// Foundation/CoreGraphics, so it compiles into both the app target and
/// `Tests/BoardTests` off one symlinked file.
public enum BoardRender {

    /// How a placed tile reads on the surface. Mirrors the subset of
    /// `BrandTile.State` the board itself decides — `BrandTile.State` is
    /// SwiftUI and unreachable from here, so the view maps this across.
    /// Selection is not a board fact and is deliberately absent.
    public enum TileState: Equatable, Sendable {
        /// Loose: no orthogonal neighbor, so it keeps its drop shadow and
        /// reads as sitting on top of the surface.
        case idle
        /// Part of a run of two or more, so it seats flush into the surface.
        case placed
    }

    /// One visible grid cell. `tile` and `state` are nil together or set
    /// together — `state` describes `tile`, and an empty cell has no state.
    public struct Cell: Equatable, Sendable {
        public let coord: Coord
        /// Top-left corner of the cell in view space, from `camera.point(for:)`.
        public let point: CGPoint
        public let tile: Tile?
        public let state: TileState?

        // No hand-written init: `cells(_:_:in:)` is the only producer, and the
        // synthesized memberwise one already covers the tests. A public init
        // would just be a second way to build a `Cell` with a state that
        // describes no tile.
    }

    /// The draw list for `rect`, one entry per visible coord.
    ///
    /// Cost is a function of the viewport, never of `board.placements.count`:
    /// the range comes from `camera.visibleCoords(in:)` and each coord's tile
    /// is an O(1) dict lookup, so a board living at row/col ±500 draws exactly
    /// what the same board at the origin draws. `placements` is never iterated.
    ///
    /// A degenerate or non-finite `rect` (a `GeometryReader`'s first layout
    /// pass reports `.zero`) yields an empty list rather than trapping —
    /// `BoardCamera` already guards the `Int` conversions.
    public static func cells(board: Board, camera: BoardCamera, in rect: CGRect) -> [Cell] {
        camera.visibleCoords(in: rect).map { coord in
            let tile = board.tile(at: coord)
            return Cell(
                coord: coord,
                point: camera.point(for: coord),
                tile: tile,
                state: tile == nil ? nil : state(of: coord, in: board)
            )
        }
    }

    /// `.placed` when the tile at `coord` has any orthogonal neighbor — one
    /// neighbor is already a run of two in that direction. Four dict lookups,
    /// so this stays O(1) per drawn tile no matter how large the board is.
    /// `Coord.neighbors` is edge-adjacent only and never clamps, so this is
    /// correct at negative coords too.
    private static func state(of coord: Coord, in board: Board) -> TileState {
        coord.neighbors.contains { board.tile(at: $0) != nil } ? .placed : .idle
    }
}
