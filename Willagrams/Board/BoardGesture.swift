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

        /// The camera as it stood at touch-down. `DragGesture` reports a
        /// translation cumulative from that moment, so it is applied to this
        /// snapshot and never to the live camera — applying a cumulative
        /// translation to a camera that already moved would accelerate away
        /// from the finger.
        private let start: BoardCamera

        /// Hit-tests `startLocation` once. The cell comes from
        /// `camera.coord(at:)` — the same helper the renderer's visible range
        /// routes through — so a tile is grabbable across exactly the region
        /// it is drawn over, with no second boundary convention to disagree at
        /// a cell edge.
        public init(at startLocation: CGPoint, in board: Board, camera: BoardCamera) {
            let coord = camera.coord(at: startLocation)
            if let tile = board.tile(at: coord) {
                self.grab = .tile(tile, at: coord)
            } else {
                self.grab = .pan
            }
            self.start = camera
        }

        /// The camera after a cumulative `translation`: one-to-one with the
        /// finger for a pan, and the untouched start camera for a tile —
        /// moving the tile is the next item's job, not the camera's.
        public func camera(translatedBy translation: CGSize) -> BoardCamera {
            guard grab == .pan else { return start }
            return start.panned(by: translation)
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
