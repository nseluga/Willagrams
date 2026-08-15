import Foundation
import CoreGraphics
import WillagramsRules

/// Every decision the surface's camera gestures make, with none of the gesture
/// plumbing.
///
/// `BoardView` owns the `DragGesture`/`MagnifyGesture` wiring and nothing
/// else. What a touch took hold of, where a pan lands, and what the recenter
/// control frames are all decided here in pure Foundation/CoreGraphics, so
/// `Tests/BoardTests` can execute them with no host app — the same reason
/// `BoardRender` exists for the draw list.
public enum BoardGesture {

    /// What a one-finger touch took hold of.
    public enum Grab: Equatable, Sendable {
        /// The touch landed on an empty cell, so the finger moves the camera.
        case pan
        /// The touch landed on a tile. This item stops at the decision — the
        /// drag item below owns actually moving it — but the tile and its
        /// coord travel with the decision so that item needs no second
        /// hit test.
        case tile(Tile, at: Coord)
    }

    /// One one-finger drag, from touch-down to release.
    ///
    /// The decision and the camera it was taken against are captured in `init`
    /// and are both `let`: re-deciding mid-gesture would take building a
    /// second `Drag`, which is the "decided once at gesture start" guardrail
    /// written as a type rather than as a comment. A finger that began panning
    /// keeps panning however many tiles it crosses on the way.
    public struct Drag: Sendable {

        /// Decided at touch-down and never revisited.
        public let grab: Grab

        /// The touch-down point, kept so a caller can tell this drag from the
        /// next one. SwiftUI skips `onEnded` for a cancelled gesture, so a
        /// stored `Drag` outlives the gesture that made it; comparing this
        /// against the incoming `startLocation` is how the caller notices and
        /// rebuilds rather than reusing a stale decision.
        public let startLocation: CGPoint

        /// Only the PAN as it stood at touch-down — deliberately not a whole
        /// camera. `DragGesture` reports a cumulative translation, so the
        /// origin of that translation has to be remembered; the zoom must not
        /// be, or a drag frame arriving between two pinch frames would write a
        /// stale zoom back and the two gestures would fight over the camera
        /// every event.
        private let startPan: CGSize

        /// Hit-tests `startLocation` once. The cell comes from
        /// `camera.coord(at:)` — the same helper the renderer's visible range
        /// routes through — so a tile is grabbable across exactly the region
        /// it is drawn over, with no second boundary convention to disagree at
        /// a cell edge.
        public init(at startLocation: CGPoint, in board: Board, camera: BoardCamera) {
            self.startLocation = startLocation
            self.startPan = camera.pan

            // `coord(at:)` answers `Coord(0, 0)` for any point it cannot index
            // — non-finite, or so far out that no `Int` cell index expresses it
            // — which would otherwise let a stray touch grab whatever tile sits
            // at the origin. Putting the coord back through `point(for:)` tells
            // a real hit from that fallback without re-deriving the boundary
            // convention here, which stays `coord(at:)`'s alone.
            //
            // The window is a whole cell either side rather than the exact
            // `0..<size` a correct hit lands in: what has to be rejected is
            // non-finite (every comparison against a NaN is false) and the
            // astronomically-out-of-range, and a slack window rejects both
            // while leaving no room for a float ULP at a cell edge a thousand
            // cells from the origin to read as a rejection.
            let coord = camera.coord(at: startLocation)
            let cellOrigin = camera.point(for: coord)
            let size = camera.cellSize
            guard (startLocation.x - cellOrigin.x).magnitude <= size,
                  (startLocation.y - cellOrigin.y).magnitude <= size
            else {
                self.grab = .pan
                return
            }

            self.grab = board.tile(at: coord).map { .tile($0, at: coord) } ?? .pan
        }

        /// `camera` after a cumulative `translation`: the LIVE camera with its
        /// pan moved one-to-one with the finger, or the live camera untouched
        /// for a tile grab — moving the tile is the next item's job, not the
        /// camera's.
        ///
        /// Taking the live camera rather than a snapshot is what stops a drag
        /// reverting a zoom that a pinch changed underneath it. Only `pan` is
        /// ever written, and it is written through `BoardCamera.panned(by:)`
        /// so the one non-finite guard covers this path too.
        public func camera(_ camera: BoardCamera, translatedBy translation: CGSize) -> BoardCamera {
            guard grab == .pan else { return camera }
            var moved = camera
            moved.pan = startPan
            return moved.panned(by: translation)
        }
    }

    /// The camera framing every tile on `board` inside `rect`, or the camera
    /// unchanged when there is nothing to frame.
    ///
    /// This is the one place the whole placement dictionary is read, and it is
    /// read on a control press rather than per frame — the draw path still
    /// costs the viewport, never the board.
    public static func recentered(
        _ camera: BoardCamera,
        over board: Board,
        in rect: CGRect
    ) -> BoardCamera {
        camera.recenter(over: Array(board.placements.keys), in: rect)
    }
}
