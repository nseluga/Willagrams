import Foundation
import CoreGraphics
import WillagramsRules

/// Maps the unbounded `Coord` lattice onto a viewport, in points.
///
/// Pure geometry: no SwiftUI/UIKit, so this is fully testable with no host
/// app. `pan`, `zoom`, and `baseCellSize` are the only state — `cellSize` is
/// always derived fresh from them, so nothing here goes stale across a pan
/// or zoom change.
public struct BoardCamera: Sendable {

    /// Rendered cell size never drops below this, however far zoomed out.
    /// Named per the lane spec's 24...72pt zoom range (no DesignTokens key
    /// covers cell size — DesignTokens is a SwiftUI-only file this pure
    /// geometry type cannot import).
    public static let minCellSize: CGFloat = 24
    /// Rendered cell size never exceeds this, however far zoomed in.
    public static let maxCellSize: CGFloat = 72

    /// Screen-space offset applied before scaling.
    public var pan: CGSize
    /// Requested zoom. Not itself clamped — `cellSize` is, so an
    /// out-of-range zoom just saturates at the effective size floor/ceiling.
    public var zoom: CGFloat
    /// Cell size at zoom == 1.
    public var baseCellSize: CGFloat

    public init(pan: CGSize = .zero, zoom: CGFloat = 1, baseCellSize: CGFloat = 48) {
        self.pan = pan
        self.zoom = zoom
        self.baseCellSize = baseCellSize
    }

    /// The single source of truth `point(for:)`, `coord(at:)`, and
    /// `visibleCoords(in:)` all derive from — never cache this elsewhere.
    public var cellSize: CGFloat {
        min(max(baseCellSize * zoom, Self.minCellSize), Self.maxCellSize)
    }

    /// The one place a position turns into a cell index.
    ///
    /// `coord(at:)` and `visibleCoords(in:)` both route through this so they
    /// can never drift to different boundary conventions: cells are half-open
    /// (`[i*size, (i+1)*size)`) and the bias is a plain rounding rule with no
    /// epsilon. An epsilon here was measured to be a no-op for the
    /// `point(for:)` round trip (real float error is ~1e-13) while making the
    /// two methods disagree about who owns an exact boundary — so there is
    /// none.
    ///
    /// Returns `nil` rather than trapping on non-finite or out-of-range input:
    /// `Int(floor(.nan))`, and `Int(_:)` past `Int.max`, are runtime crashes in
    /// Swift, not clamps — and `localValue` comes from live gesture
    /// translations and geometry-proxy rects.
    private static func index(
        _ localValue: CGFloat,
        size: CGFloat,
        rule: FloatingPointRoundingRule
    ) -> Int? {
        let scaled = (localValue / size).rounded(rule)
        guard scaled.isFinite, scaled >= -9e18, scaled <= 9e18 else { return nil }
        return Int(scaled)
    }

    public func point(for coord: Coord) -> CGPoint {
        let size = cellSize
        return CGPoint(
            x: CGFloat(coord.col) * size + pan.width,
            y: CGFloat(coord.row) * size + pan.height
        )
    }

    /// Falls back to the origin coord on non-finite input rather than trapping.
    public func coord(at point: CGPoint) -> Coord {
        let size = cellSize
        // .down (floor), not Int(): Int() truncates toward zero, which would
        // collapse row/col -1 and 0 onto the same cell for negative input.
        guard size > 0,
              let col = Self.index(point.x - pan.width, size: size, rule: .down),
              let row = Self.index(point.y - pan.height, size: size, rule: .down)
        else { return Coord(row: 0, col: 0) }
        return Coord(row: row, col: col)
    }

    /// Every coord whose cell intersects `rect`, cells treated half-open
    /// (`[col*size, (col+1)*size)`) so adjacent cells never double-count a
    /// shared edge.
    public func visibleCoords(in rect: CGRect) -> some Sequence<Coord> {
        let size = cellSize
        // Empty rather than a trap on a non-finite rect; same half-open
        // convention as `coord(at:)`, via the same `index` helper.
        //
        // `!rect.isEmpty` is load-bearing, not defensive noise: a rect with no
        // area still has a `minX` and a `maxX`, and when that shared edge falls
        // *inside* a cell rather than on a boundary, floor and ceil land on
        // different indices and the range enumerates a phantom cell. A
        // `GeometryReader` reports `.zero` on its first layout pass, so this is
        // a real frame, not a hypothetical one. `CGRect.isEmpty` is true for
        // zero or collapsed extents and false for a mirrored (negative-size)
        // rect, which describes a real region and still enumerates.
        guard size > 0, !rect.isEmpty,
              let minCol = Self.index(rect.minX - pan.width, size: size, rule: .down),
              let maxColEnd = Self.index(rect.maxX - pan.width, size: size, rule: .up),
              let minRow = Self.index(rect.minY - pan.height, size: size, rule: .down),
              let maxRowEnd = Self.index(rect.maxY - pan.height, size: size, rule: .up)
        else { return [Coord]() }

        let maxCol = maxColEnd - 1
        let maxRow = maxRowEnd - 1

        guard minCol <= maxCol, minRow <= maxRow else { return [Coord]() }
        return (minRow...maxRow).flatMap { row in
            (minCol...maxCol).map { col in Coord(row: row, col: col) }
        }
    }

    /// The camera translated one-to-one with a finger.
    ///
    /// Never clamped, in any direction: the board is unbounded, so there is no
    /// maximum extent to stop at and no "edge" to rubber-band against. A
    /// non-finite translation leaves the camera alone rather than poisoning
    /// `pan` with a NaN every later `Int` conversion would have to survive.
    public func panned(by translation: CGSize) -> BoardCamera {
        guard translation.width.isFinite, translation.height.isFinite else { return self }
        var camera = self
        camera.pan = CGSize(
            width: pan.width + translation.width,
            height: pan.height + translation.height
        )
        return camera
    }

    /// Zoomed by `magnification` about `anchor`, keeping whatever board
    /// position sits under `anchor` exactly where it is.
    ///
    /// `magnification` is cumulative from a pinch's start, so callers apply it
    /// to a camera snapshotted at that start rather than to the live one.
    ///
    /// Both halves of the anchor math read the CLAMPED `cellSize`. That is
    /// what lets the 24...72pt clamp stay here and out of the gesture code:
    /// the board position under the anchor is measured in whatever cell size
    /// is actually rendered and restored in whatever cell size is actually
    /// rendered next, so the anchor still holds exactly once the clamp
    /// saturates and the gesture never has to know a bound exists.
    ///
    /// A pinch can report a zero, negative or non-finite magnification;
    /// each of those leaves the camera untouched.
    ///
    /// The STORED zoom is clamped here, not just the derived `cellSize`. It has
    /// to be: each pinch snapshots the live camera, so an unbounded `zoom`
    /// carries every frame of overshoot into the next gesture and the user pays
    /// it all back before anything on screen moves. Five ordinary 3x pinches
    /// reached zoom 243 against a 1.5 ceiling — 162x of dead travel, which no
    /// single physical pinch can unwind. This is the one place in the type
    /// where the state itself is clamped rather than the value derived from it,
    /// and the reason is that `zoom` is driven by a cumulative gesture.
    public func magnified(by magnification: CGFloat, about anchor: CGPoint) -> BoardCamera {
        let size = cellSize
        // `baseCellSize > 0` is not covered by `size > 0`: `cellSize` floors at
        // minCellSize, so it is 24 even when `baseCellSize` is 0 — and the zoom
        // bounds below divide by `baseCellSize`.
        guard size > 0, size.isFinite,
              baseCellSize > 0, baseCellSize.isFinite,
              magnification.isFinite, magnification > 0,
              anchor.x.isFinite, anchor.y.isFinite
        else { return self }

        // Where the anchor sits on the board, in cells, fractional.
        let boardX = (anchor.x - pan.width) / size
        let boardY = (anchor.y - pan.height) / size

        var camera = self
        camera.zoom = min(
            max(zoom * magnification, Self.minCellSize / baseCellSize),
            Self.maxCellSize / baseCellSize
        )
        let zoomedSize = camera.cellSize
        camera.pan = CGSize(
            width: anchor.x - boardX * zoomedSize,
            height: anchor.y - boardY * zoomedSize
        )

        guard camera.zoom.isFinite, camera.pan.width.isFinite, camera.pan.height.isFinite
        else { return self }
        return camera
    }

    /// Pan and zoom that frame `coords` inside `rect`, centered, with the
    /// resulting cell size still inside `minCellSize...maxCellSize`.
    ///
    /// Framing and the cell-size floor genuinely conflict once the span is
    /// wider than `rect` measured in floor-sized cells — about 42 columns
    /// across a 1024pt viewport at 24pt — and a late-game board reaches that.
    /// The floor wins and the content is CENTERED rather than contained, so
    /// the outermost tiles sit off screen. That is the deliberate degradation:
    /// honouring the frame instead would render cells too small to read or to
    /// hit with a finger. Pinned by
    /// `testRecenterCentersContentTooLargeToFitAtTheCellSizeFloor`.
    ///
    /// `rect` is standardized first, so this and `visibleCoords(in:)` hold the
    /// same view of a mirrored rect — a negative width describes a real region
    /// and is framed, while only a genuinely area-less rect is refused. Before
    /// this line the two disagreed: `visibleCoords` enumerated a mirrored rect
    /// (its `minX`/`maxX` reads already standardize) while `recenter`'s
    /// `width > 0` rejected it.
    public func recenter(over coords: [Coord], in rect: CGRect) -> BoardCamera {
        let rect = rect.standardized
        // `baseCellSize` is public and unclamped, so a zero-size first layout
        // pass can make it 0. Dividing by it would give `zoom == .infinity`,
        // and the next `cellSize` read `0 * .infinity == .nan` — which the
        // min/max clamp does NOT filter, because every NaN comparison is
        // false. Unchanged camera is the honest answer for a degenerate frame.
        guard !coords.isEmpty,
              baseCellSize > 0,
              rect.width > 0, rect.height > 0,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite
        else { return self }

        let rows = coords.map(\.row)
        let cols = coords.map(\.col)
        let minRow = rows.min()!
        let maxRow = rows.max()!
        let minCol = cols.min()!
        let maxCol = cols.max()!
        let contentCols = CGFloat(maxCol - minCol + 1)
        let contentRows = CGFloat(maxRow - minRow + 1)

        let fitSize = min(rect.width / contentCols, rect.height / contentRows)
        let size = min(max(fitSize, Self.minCellSize), Self.maxCellSize)

        var camera = self
        camera.zoom = size / baseCellSize

        let contentWidth = contentCols * size
        let contentHeight = contentRows * size
        camera.pan = CGSize(
            width: rect.minX + (rect.width - contentWidth) / 2 - CGFloat(minCol) * size,
            height: rect.minY + (rect.height - contentHeight) / 2 - CGFloat(minRow) * size
        )
        return camera
    }
}
