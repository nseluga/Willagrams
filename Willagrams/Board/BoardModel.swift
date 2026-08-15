import Foundation
import CoreGraphics
import WillagramsRules

/// What the surface is holding right now, and whether it accepts a hold at all.
///
/// `BoardView` keeps this as its only piece of tile-drag state, so every
/// decision about a hold — taking one, moving it, landing it, dropping it — is
/// made in a pure Foundation/CoreGraphics file `Tests/BoardTests` can execute
/// with no host app. Same reason `BoardGesture` and `BoardRender` exist.
///
/// The camera is deliberately NOT in here. Panning, zooming and recentering are
/// a separate concern that the lock below must not reach, and the cleanest way
/// to guarantee that is for this type to have no camera to lock.
public struct BoardModel: Sendable {

    /// Set from outside to make the surface inert to tile handling.
    ///
    /// A plain `Bool` that knows nothing about why it was set: whatever owns
    /// this view decides that, and nothing here may know or ask. While it is
    /// set, no tile can be taken hold of, moved, or landed, and no feel fires
    /// on touch — the tiles simply hold their positions. The camera is
    /// untouched, so a locked player can still look around their own board.
    ///
    /// The `didSet` is what makes a bare assignment enough. A lock arriving
    /// mid-hold drops the hold on the spot, so no caller has to remember a
    /// second call to make the surface actually inert.
    public var inputLocked: Bool {
        didSet { if inputLocked { cancel() } }
    }

    /// The hold in flight, or nil when nothing is held.
    ///
    /// Private: building one is what fires the pickup feel, so the transitions
    /// below are the only ways in and a caller cannot manufacture a hold that
    /// never buzzed — or one that buzzed twice.
    private var tileDrag: TileDrag?

    /// How far the finger has moved since it took hold.
    ///
    /// Assigned, never accumulated: `DragGesture` reports a translation
    /// cumulative from its own start, so each frame REPLACES this and there is
    /// no stored quantity that can run away behind a clamped render.
    public private(set) var dragTranslation: CGSize = .zero

    /// The coords a hold is carrying, empty when nothing is held — exactly what
    /// `BoardRender.cells(dragging:)` takes. `TileDrag.origins` is never empty,
    /// so an empty set here means no hold, with no second flag to disagree.
    public var dragging: Set<Coord> { tileDrag?.origins ?? [] }

    public init(inputLocked: Bool = false) {
        self.inputLocked = inputLocked
    }

    /// Takes hold of whatever `grab` decided at touch-down, firing pickup once.
    ///
    /// Refused outright while locked, before `TileDrag` is ever built — so
    /// there is nothing lifted to revert and no feel to swallow.
    /// `BoardGesture.Drag` refuses one step earlier by deciding `.pan`; this is
    /// the same rule restated where the hold actually lives, so the hold cannot
    /// be created behind the gesture layer's back.
    ///
    /// Call once per gesture. Calling it per frame would fire a pickup per
    /// frame, which is the caller's bug and is not papered over here.
    public mutating func began(_ grab: BoardGesture.Grab, haptics: some BoardHaptics) {
        guard !inputLocked else { return }
        tileDrag = TileDrag(grab: grab, haptics: haptics)
        dragTranslation = .zero
    }

    /// A no-op when nothing is held, so a finger that took hold of the camera
    /// writes no tile offset — and neither does one whose hold was cancelled
    /// out from under it mid-gesture.
    public mutating func moved(to translation: CGSize) {
        guard tileDrag != nil else { return }
        dragTranslation = translation
    }

    /// The board after releasing at `translation`: the moved board and a snap
    /// feel, or the given board and a reject. The hold is cleared either way.
    ///
    /// Hands `board` straight back when nothing is held, which covers both a
    /// released pan and a release after a lock landed mid-hold. `Board` is a
    /// value and `TileDrag.drop` builds on a copy, so a refused or absent
    /// commit cannot leave a half-move behind.
    public mutating func commit(
        translation: CGSize,
        on board: Board,
        camera: BoardCamera,
        threshold: CGFloat
    ) -> Board {
        guard let tileDrag else { return board }
        let next = tileDrag.drop(
            translation: translation, on: board, camera: camera, threshold: threshold
        )
        cancel()
        return next
    }

    /// Drops the hold with no feel and no commit — the ONE cancel path, taken
    /// both by the lock above and by a second finger taking the gesture away.
    /// Two cancels would be two chances to forget half of one.
    ///
    /// Never touches `Board`. This drops view-side state only, and dropping it
    /// is exactly what returns the tile to the coord it started from:
    /// `BoardRender` then draws it at its home point with no selected state.
    /// No haptic fires — a cancellation is not a refused drop, and a feel here
    /// would land in a count that must record one per rejected drop.
    public mutating func cancel() {
        tileDrag = nil
        dragTranslation = .zero
    }
}
