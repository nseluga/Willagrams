import Foundation
import CoreGraphics
import WillagramsRules

/// Where a tile is actually DRAWN, and which tile a finger landed on.
///
/// The lattice is exact and the drawing is not. A tile sits at its `Coord`'s
/// cell plus a sub-cell offset, so "which cell is this point in" and "which tile
/// is under this point" stopped being the same question the moment offsets
/// arrived — and every hit test in the lane was asking the first one while
/// meaning the second. This file answers the second, once, and
/// `BoardGesture.Drag`, `BoardSelection` and `BoardRender` all route through it
/// so a tile is grabbable across exactly the region it is drawn over.
///
/// Pure Foundation/CoreGraphics like the rest of the decisions in this lane, so
/// `Tests/BoardTests` executes it with no host app.
public enum BoardHit {

    /// Top-left corner of the DRAWN tile: its cell's corner plus its offset,
    /// measured in cells so the same table holds at every zoom.
    ///
    /// The offset is in CELL units, not points. A table in points would have to
    /// be rebuilt on every pinch frame, and a stale one would slide the tiles
    /// off their cells as the camera zoomed.
    ///
    /// A tile with no entry sits exactly on its cell. That is the honest answer
    /// for a board drawn before the session has published a table, and it means
    /// no caller has to hold a default of its own.
    public static func origin(
        of coord: Coord,
        tile: Tile,
        offsets: [UUID: CGSize],
        camera: BoardCamera
    ) -> CGPoint {
        let base = camera.point(for: coord)
        // A non-finite offset would put the tile at a point no renderer can use
        // and, worse, make every hit-test comparison below false — so the tile
        // would be drawn nowhere and grabbable nowhere. Its cell is the answer.
        guard let offset = offsets[tile.id],
              offset.width.isFinite, offset.height.isFinite
        else { return base }
        let size = camera.cellSize
        guard size > 0, size.isFinite else { return base }
        return CGPoint(x: base.x + offset.width * size, y: base.y + offset.height * size)
    }

    /// The tile drawn under `point`, or nil when the finger landed on bare
    /// surface.
    ///
    /// Walks the placements rather than indexing a cell. It has to: with
    /// offsets in play a tile can be drawn over a neighbouring cell, and
    /// `camera.coord(at:)` would answer with that neighbour — empty — and the
    /// tile would refuse to lift along whichever edge it overhangs. The walk is
    /// O(placements) and runs once per touch-down and once per sweep sample,
    /// never per drawn frame, against a board that holds tens of tiles.
    ///
    /// Nearest centre wins a tie. Offsets are shared within a cluster and
    /// bounded well inside a cell, so drawn tiles do not overlap in practice —
    /// but a tie needs one answer rather than whichever placement sorted first.
    public static func tile(
        under point: CGPoint,
        on board: Board,
        offsets: [UUID: CGSize],
        camera: BoardCamera
    ) -> Placement? {
        // Live gesture floats. Every comparison against a NaN is false, so a
        // non-finite point would land on nothing anyway — refused here so that is
        // a stated rule rather than an accident of the arithmetic below.
        guard point.x.isFinite, point.y.isFinite else { return nil }

        let size = camera.cellSize
        guard size > 0, size.isFinite else { return nil }
        let half = size / 2

        var best: (placement: Placement, distance: CGFloat)?
        for placement in board.placementList {
            let origin = origin(
                of: placement.coord, tile: placement.tile, offsets: offsets, camera: camera
            )
            // Half-open, the same convention `BoardCamera` uses for cells, so
            // two tiles drawn edge to edge never both claim the shared edge.
            guard point.x >= origin.x, point.x < origin.x + size,
                  point.y >= origin.y, point.y < origin.y + size
            else { continue }
            let distance = hypot(point.x - (origin.x + half), point.y - (origin.y + half))
            if best.map({ distance < $0.distance }) ?? true {
                best = (placement, distance)
            }
        }
        return best?.placement
    }
}
