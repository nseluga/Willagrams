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

    /// What the frozen checker said about the board after the last committed
    /// move. Published state, never recomputed by a reader: `BoardRender` and
    /// the view read `invalidCoords` and `canDraw` off this, so nothing on the
    /// draw path calls `validate` — and nothing calls it per gesture frame.
    public private(set) var validation: BoardValidation
    /// Straight off the frozen `isComplete`. The completeness rule lives in
    /// `BoardValidation` and this must never restate any part of it.
    public var canDraw: Bool { validation.isComplete }

    /// Every coord covered by a word in `validation.invalidWords`, expanded once
    /// per commit so the draw path is a set lookup rather than a walk of the
    /// word list per drawn cell. A tile in two words, one of them bad, is in
    /// here — a run is wrong as a whole and every letter in it is part of it.
    public private(set) var invalidCoords: Set<Coord> = []

    public init(inputLocked: Bool = false) {
        self.inputLocked = inputLocked
        self.validation = BoardValidation(clusterCount: 0, invalidWords: [], tileCount: 0)
    }

    /// Seeds the published state from the board the surface starts on, so a
    /// caller gating on `canDraw` is not reading a bare-empty answer about a
    /// board that already has tiles on it before the first move lands.
    ///
    /// Kept for the test package and any caller that builds a model around a
    /// board it already has. `BoardView` must NOT use it: `State(initialValue:)`
    /// takes a plain argument, so this would run a full check on every re-init
    /// of the view and throw all but the first away. That view calls `seed`
    /// once, on appear, instead.
    public init(board: Board, against dictionary: some WordList, inputLocked: Bool = false) {
        self.init(inputLocked: inputLocked)
        seed(board, against: dictionary)
    }

    /// Publishes the first answer about a board that was never committed to
    /// here. Idempotent and the same cost as one commit's recompute, so a
    /// surface that appears twice pays it twice and lands on the same state
    /// both times — but it belongs on an appearance, never on a body
    /// evaluation and never on a gesture frame.
    public mutating func seed(_ board: Board, against dictionary: some WordList) {
        revalidate(board, against: dictionary)
    }

    /// The board a game opens on, with the published state already answering
    /// for it. `tiles` is the whole input: hand it 21 and 21 land, hand it 30
    /// and 30 do — nothing here knows a starting count.
    ///
    /// The tiles go onto the BOARD. There is no rack in this game, so nothing
    /// on this path routes a tile through one and the rules type's own tile
    /// store is left empty.
    public mutating func opening(_ tiles: [Tile], against dictionary: some WordList) -> Board {
        let board = BoardLayout.opening(tiles)
        seed(board, against: dictionary)
        return board
    }

    /// The board after a Draw delivers `tiles`, landed in free cells below what
    /// the player can currently see and published in one pass — the same one
    /// check a commit pays, not a second one.
    ///
    /// `camera` and `rect` are read, never stored: this decides where the
    /// arrival lands and hands the board back, and the surface's own camera is
    /// untouched.
    public mutating func delivered(
        _ tiles: [Tile],
        onto board: Board,
        camera: BoardCamera,
        in rect: CGRect,
        against dictionary: some WordList
    ) -> Board {
        let next = BoardLayout.delivered(tiles, onto: board, camera: camera, in: rect)
        seed(next, against: dictionary)
        return next
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
    /// `dictionary` is a parameter rather than a stored property: the checker is
    /// only ever needed at the instant a move lands, and holding one here would
    /// be a second place for it to go stale.
    public mutating func commit(
        translation: CGSize,
        on board: Board,
        camera: BoardCamera,
        threshold: CGFloat,
        against dictionary: some WordList
    ) -> Board {
        guard let tileDrag else { return board }
        let next = tileDrag.drop(
            translation: translation, on: board, camera: camera, threshold: threshold
        )
        // On the committed board, not on the one handed in — and on the refused
        // path too, where `drop` hands the original straight back and this is
        // therefore the same answer recomputed rather than a different one.
        revalidate(next, against: dictionary)
        cancel()
        return next
    }

    /// The ONE place published validation is written, and the only call to the
    /// frozen checker in this lane. Everything here is read back out of
    /// `BoardValidation` — no cluster, run or completeness rule is restated.
    private mutating func revalidate(_ board: Board, against dictionary: some WordList) {
        validation = board.validate(against: dictionary)
        invalidCoords = Set(
            validation.invalidWords.flatMap { word in
                // `text.count` letters from `origin` along `direction`. Every
                // one of those coords holds a tile by construction — the word
                // was read off the board — so no overflow guard is needed that
                // `Board` itself did not already need to place them.
                (0..<word.text.count).map { step in
                    word.direction == .across
                        ? Coord(row: word.origin.row, col: word.origin.col + step)
                        : Coord(row: word.origin.row + step, col: word.origin.col)
                }
            }
        )
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
