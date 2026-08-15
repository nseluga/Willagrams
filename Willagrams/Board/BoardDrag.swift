import Foundation
import CoreGraphics
import WillagramsRules

/// The three feels a tile drag asks for. Distinct cases rather than a single
/// "buzz" because the whole point is that pickup, a landed move and a refused
/// one are told apart by the hand alone.
public enum BoardHapticEvent: Equatable, Sendable, CaseIterable {
    /// A tile has been taken hold of.
    case pickup
    /// The tile landed on a free cell and the board changed.
    case snap
    /// The drop was refused and the board is exactly as it was.
    case reject
}

/// The seam between a drag's decisions and the hardware that buzzes.
///
/// One method over an enum rather than three methods: a recording double is
/// then a one-line append, and a fourth feel later touches no conformance. The
/// real `UIImpactFeedbackGenerator`/`UINotificationFeedbackGenerator` wiring
/// lives in `BoardFeedback.swift`, which imports UIKit — this file must stay
/// host-compilable or none of the drag logic below can be executed by a test.
public protocol BoardHaptics: Sendable {
    func fire(_ event: BoardHapticEvent)
}

/// Fires nothing. For previews and any caller with no opinion.
public struct SilentHaptics: BoardHaptics {
    public init() {}
    public func fire(_ event: BoardHapticEvent) {}
}

/// One tile drag, from pickup to release.
///
/// What is being dragged is a `Set<Coord>` from the outset, holding a single
/// coord in the ordinary case. A later item moves a whole word at once, and the
/// move it needs is the one written here: a single `(Δrow, Δcol)` lattice delta
/// applied to every origin, accepted or refused as one unit. A model written
/// for exactly one tile would have to be thrown away for that.
///
/// The board is never mutated in place. `drop` builds the result on a COPY and
/// hands back the ORIGINAL value on any refusal, so a `remove` that is not
/// followed by its `place` cannot reach a caller — that guarantee is
/// structural here rather than a sequencing rule someone has to remember.
public struct TileDrag: Sendable {

    /// Every coord this drag is carrying. Never empty.
    public let origins: Set<Coord>

    /// The coord the finger actually took hold of. The delta is measured from
    /// this one, so the tile under the finger is the one that lands where the
    /// finger let go.
    public let anchor: Coord

    private let haptics: any BoardHaptics

    /// Fires `.pickup` exactly once, on construction.
    ///
    /// Pickup lives here rather than on any update path because
    /// `DragGesture.onChanged` fires many times per drag: a caller that builds
    /// this once per gesture gets exactly one pickup for free, and a caller
    /// that builds it per frame has a bug this would only have hidden.
    public init?(origins: Set<Coord>, anchor: Coord, haptics: some BoardHaptics) {
        guard origins.contains(anchor) else { return nil }
        self.origins = origins
        self.anchor = anchor
        self.haptics = haptics
        haptics.fire(.pickup)
    }

    /// The drag a one-finger touch-down implies, or nil when the touch took
    /// hold of the camera rather than a tile.
    ///
    /// `BoardGesture.Drag` already hit-tested at touch-down and carried the
    /// result forward; this reads that decision instead of running a second hit
    /// test with a second boundary convention.
    public init?(grab: BoardGesture.Grab, haptics: some BoardHaptics) {
        guard case .tile(_, let coord) = grab else { return nil }
        self.init(origins: [coord], anchor: coord, haptics: haptics)
    }

    /// The board after releasing at `translation`, and the feel that goes with
    /// it: the moved board plus `.snap`, or `board` itself plus `.reject`.
    ///
    /// `threshold` is injected rather than read from a token because
    /// `DesignTokens` is a SwiftUI file this one cannot import. `BoardView`
    /// passes `DesignTokens.Motion.snapThreshold`, so the token stays the one
    /// source of truth and a test can still drive its own distance.
    public func drop(
        translation: CGSize,
        on board: Board,
        camera: BoardCamera,
        threshold: CGFloat
    ) -> Board {
        guard let next = landing(translation: translation, on: board, camera: camera, threshold: threshold)
        else {
            haptics.fire(.reject)
            return board
        }
        haptics.fire(.snap)
        return next
    }

    /// The moved board, or nil when the drop is refused for any reason at all.
    ///
    /// Every refusal returns nil before `next` is ever handed back, and `next`
    /// is a copy, so the caller above can only ever see a whole move or the
    /// untouched original.
    private func landing(
        translation: CGSize,
        on board: Board,
        camera: BoardCamera,
        threshold: CGFloat
    ) -> Board? {
        // Live gesture floats. A NaN sails through every comparison below as
        // "false", so it is refused up front rather than reasoned about.
        guard translation.width.isFinite, translation.height.isFinite,
              threshold.isFinite, threshold >= 0
        else { return nil }

        let size = camera.cellSize
        guard size > 0, size.isFinite else { return nil }
        let half = size / 2

        // Where the anchor cell's CENTRE ended up. Centre, not corner, because
        // the distance being measured is centre-to-centre.
        let start = camera.point(for: anchor)
        let dropped = CGPoint(
            x: start.x + translation.width + half,
            y: start.y + translation.height + half
        )
        guard dropped.x.isFinite, dropped.y.isFinite else { return nil }

        // `camera.coord(at:)` is the one sanctioned "which cell is this"
        // derivation, and it answers `Coord(0, 0)` for anything it cannot
        // index — non-finite, or so far out no `Int` cell index expresses it.
        // Putting the answer back through `point(for:)` separates a real cell
        // from that fallback without a second rounding rule living here, so an
        // astronomical drop is refused instead of quietly snapping to the
        // origin. The window is a whole cell rather than the exact half-open
        // one a correct hit lands in: it has to reject the non-finite and the
        // astronomical, and a slack window does that while leaving room for a
        // float ULP at a cell edge a thousand cells out.
        let target = camera.coord(at: dropped)
        let corner = camera.point(for: target)
        guard (dropped.x - corner.x).magnitude <= size,
              (dropped.y - corner.y).magnitude <= size
        else { return nil }

        let centre = CGPoint(x: corner.x + half, y: corner.y + half)
        let reach = hypot(dropped.x - centre.x, dropped.y - centre.y)
        guard reach.isFinite, reach <= threshold else { return nil }

        // The lattice delta, once, from the anchor. `Coord` is unbounded and
        // signed in all four directions, so the only bound worth guarding is
        // `Int` itself.
        let (deltaRow, rowOver) = target.row.subtractingReportingOverflow(anchor.row)
        let (deltaCol, colOver) = target.col.subtractingReportingOverflow(anchor.col)
        guard !rowOver, !colOver else { return nil }

        var steps: [(from: Coord, to: Coord)] = []
        steps.reserveCapacity(origins.count)
        for origin in origins {
            let (row, rowWrap) = origin.row.addingReportingOverflow(deltaRow)
            let (col, colWrap) = origin.col.addingReportingOverflow(deltaCol)
            guard !rowWrap, !colWrap else { return nil }
            let destination = Coord(row: row, col: col)
            // Free means empty, or held by a tile this drag is already
            // carrying — the second half is what lets a group slide along its
            // own row without colliding with itself.
            guard board.tile(at: destination) == nil || origins.contains(destination) else { return nil }
            steps.append((from: origin, to: destination))
        }

        // A copy. Nothing below can leave the caller's board half-moved.
        var next = board
        var carried: [(tile: Tile, to: Coord)] = []
        carried.reserveCapacity(steps.count)
        // Every remove first, then every place: a group sliding onto cells it
        // currently occupies needs those cells vacated before anything lands.
        for step in steps {
            guard let tile = next.remove(at: step.from) else { return nil }
            carried.append((tile: tile, to: step.to))
        }
        for step in carried {
            // The SAME `Tile` value goes back down, never a rebuilt one, so the
            // tile's `id` is the id it had before the drag.
            do { try next.place(step.tile, at: step.to) } catch { return nil }
        }
        return next
    }
}
