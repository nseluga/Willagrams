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
        /// `camera.point(for:)`. The bare lattice position, never offset and
        /// never drawn: the surface is an empty table now, so nothing paints a
        /// cell. It stays because it is the exact answer the frozen engine
        /// reasons in, and telling it apart from `tilePoint` is what the whole
        /// free-placement model rests on.
        public let point: CGPoint
        public let tile: Tile?
        /// Top-left corner of the TILE, which is the cell corner plus the
        /// tile's sub-cell offset, plus the live drag translation while it is in
        /// flight. Nil exactly when `tile` is nil.
        ///
        /// This is the ONLY place the two diverge, and they always do now: a
        /// tile sits on its cell's lattice position offset by however far its
        /// cluster is scattered. `BoardHit.origin` owns that sum so the tile is
        /// grabbable across exactly the region this draws it over.
        public let tilePoint: CGPoint?
        public let state: TileState?
        /// The tile here is part of a run the checker refused. Read from the
        /// coord set the session published after the last committed move — this
        /// file never checks a word against anything, and never can: it has no
        /// word list to check one against.
        public let isInvalid: Bool

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
    ///
    /// `offsets` is the sub-cell scatter the session published, keyed by tile
    /// id — the table is READ here and never derived, so nothing on the draw
    /// path decides where a cluster sits. Defaulted to empty, which draws every
    /// tile flat on its cell, so a caller with no table yet still gets a board.
    public static func cells(
        board: Board,
        camera: BoardCamera,
        in rect: CGRect,
        dragging: Set<Coord> = [],
        by translation: CGSize = .zero,
        invalid: Set<Coord> = [],
        offsets: [UUID: CGSize] = [:]
    ) -> [Cell] {
        // A live `DragGesture` translation is an external float. A non-finite
        // one draws the tile where it was rather than at a position no renderer
        // can use — the drop that follows refuses on the same grounds.
        let travel = translation.width.isFinite && translation.height.isFinite ? translation : .zero
        return camera.visibleCoords(in: rect).map { coord in
            let tile = board.tile(at: coord)
            let point = camera.point(for: coord)
            let carried = tile != nil && dragging.contains(coord)
            return Cell(
                coord: coord,
                point: point,
                tile: tile,
                tilePoint: tile.map { tile in
                    // `BoardHit.origin`, never `point`: where the tile is drawn
                    // and where it can be grabbed are the same sum, computed in
                    // one place. A dict lookup per drawn tile, so this stays a
                    // function of the viewport and never of the board.
                    let origin = BoardHit.origin(
                        of: coord, tile: tile, offsets: offsets, camera: camera
                    )
                    return carried
                        ? CGPoint(x: origin.x + travel.width, y: origin.y + travel.height)
                        : origin
                },
                state: tile == nil ? nil : (carried ? .selected : state(of: coord, in: board)),
                // An empty cell is in no word, and a tile in flight has left the
                // alignment it was part of — it reads as carried, not as wrong.
                isInvalid: tile != nil && !carried && invalid.contains(coord)
            )
        }
    }

    /// Which insertion transition a drawn tile gets. Plain enum, no SwiftUI: a
    /// pan changes which coords `cells(board:camera:in:)` returns, so a tile
    /// that was already on the table can be re-inserted into the ForEach that
    /// draws it just by scrolling back into view — that is not an arrival, and
    /// must not replay the bag flight. Only an id the caller actually names as
    /// `arriving` gets one; everything else keeps whatever it already looked
    /// like.
    public enum ArrivalTransition: Equatable, Sendable {
        /// Flies in from the bag corner.
        case fromBag
        /// No transition at all — the tile simply reappears where it left off.
        case none
    }

    /// `arriving` is the caller's current, already-expired-if-played set (see
    /// `ArrivalGate`) — this function makes no clearing decision
    /// of its own, only the membership test.
    public static func arrivalTransition(for tileID: UUID, arriving: Set<UUID>) -> ArrivalTransition {
        arriving.contains(tileID) ? .fromBag : .none
    }

    /// Whether a delivery still has a flight owed to it.
    ///
    /// Lifted out of `BoardView` because the bug was in the seeding: an `Int`
    /// `@State` starting at 0 against an owner token already at 1 made every
    /// freshly built view re-fly a hand that had been on the table for
    /// minutes. `settled` is OPTIONAL, and nil means "this view has not seen a
    /// delivery yet" rather than "the owner has delivered nothing" — the two
    /// are indistinguishable at 0, which is the whole fault. The first
    /// `begin(token:arriving:)` seeds from whatever the owner is already at and
    /// flies nothing; only a token beyond that is a real arrival.
    public struct ArrivalGate: Equatable, Sendable {

        /// The last token whose flight is spent, or nil before the first
        /// `begin`. Not settable from outside: seeding is a decision, and it is
        /// made here rather than by an `if` in a view body.
        public private(set) var settled: Int?

        public init() {}

        /// The ids `BoardSurface` should treat as arriving this frame. Empty
        /// before the gate has been seeded, so the first frame of a fresh view
        /// never flies anything — including the opening hand a board screen
        /// inherits from a countdown that owned the previous view.
        public func active(_ arriving: Set<UUID>, token: Int) -> Set<UUID> {
            guard let settled else { return [] }
            return token > settled ? arriving : []
        }

        /// Answers whether `token`'s flight should run, seeding on the first
        /// call. True only for a delivery that landed while this gate was
        /// already watching and that actually names tiles.
        public mutating func begin(token: Int, arriving: Set<UUID>) -> Bool {
            guard let seen = settled else { settled = token; return false }
            guard token > seen, !arriving.isEmpty else { settled = max(seen, token); return false }
            return true
        }

        /// The flight has had its time; the batch expires as a whole, so a tile
        /// that was culled for the entire animation does not fly in later when
        /// a pan re-inserts it.
        public mutating func finish(token: Int) {
            settled = max(settled ?? token, token)
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
