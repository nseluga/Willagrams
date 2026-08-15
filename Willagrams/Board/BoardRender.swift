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
    public enum TileState: Equatable, Sendable {
        /// Loose: no orthogonal neighbor, so it keeps its drop shadow and
        /// reads as sitting on top of the surface.
        case idle
        /// Part of a run of two or more, so it seats flush into the surface.
        case placed
        /// Carried by a drag in flight. Outranks the other two for as long as
        /// the finger is down: the view maps it onto `BrandTile.State.selected`,
        /// which owns the ring and the `Motion.tileLift` offset, so nothing
        /// here or in the view knows how far a lifted tile rises.
        case selected
    }

    /// One visible grid cell. `tile` and `state` are nil together or set
    /// together — `state` describes `tile`, and an empty cell has no state.
    public struct Cell: Equatable, Sendable {
        public let coord: Coord
        /// Top-left corner of the CELL in view space, from
        /// `camera.point(for:)`. A dragged tile leaves its cell behind, so this
        /// is deliberately never offset — the grid hole stays where the tile
        /// came from.
        public let point: CGPoint
        public let tile: Tile?
        /// Top-left corner of the TILE, which is `point` for everything except
        /// a tile in flight, where it is `point` plus the live drag
        /// translation. Nil exactly when `tile` is nil.
        public let tilePoint: CGPoint?
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
    ///
    /// `dragging` is the coord set a `TileDrag` is carrying and `translation`
    /// is how far the finger has moved since it took hold; both default to
    /// nothing in flight. Those tiles read `.selected` and draw offset, and
    /// revert to `.idle`/`.placed` the moment the set is empty again.
    public static func cells(
        board: Board,
        camera: BoardCamera,
        in rect: CGRect,
        dragging: Set<Coord> = [],
        by translation: CGSize = .zero
    ) -> [Cell] {
        // A live `DragGesture` translation is an external float. A non-finite
        // one draws the tile where it was rather than at a position no renderer
        // can use — the drop that follows refuses on the same grounds.
        let offset = translation.width.isFinite && translation.height.isFinite ? translation : .zero
        return camera.visibleCoords(in: rect).map { coord in
            let tile = board.tile(at: coord)
            let point = camera.point(for: coord)
            let carried = tile != nil && dragging.contains(coord)
            return Cell(
                coord: coord,
                point: point,
                tile: tile,
                tilePoint: tile == nil ? nil : (
                    carried
                        ? CGPoint(x: point.x + offset.width, y: point.y + offset.height)
                        : point
                ),
                state: tile == nil ? nil : (carried ? .selected : state(of: coord, in: board))
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
