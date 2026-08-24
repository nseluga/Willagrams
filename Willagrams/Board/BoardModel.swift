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
    /// A lock landing also drops the selection, not just the hold. A selection
    /// that survived the lock would keep painting the moment the finger moved
    /// again, and "no selection may begin or continue while locked" would be
    /// true of beginning only. It is two statements in one `didSet` rather than
    /// a second cancel path: `cancel` is taken by a pinch stealing the gesture
    /// too, and a pinch must NOT cost the player what they have swept up —
    /// zooming is how they see it.
    public var inputLocked: Bool {
        didSet { if inputLocked { cancel(); selection.clear() } }
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

    /// What the player has swept up, and whether the surface is sweeping.
    /// Written only through the transitions below, so a caller cannot put a
    /// selection here while the surface is locked.
    public private(set) var selection = BoardSelection()

    /// Every coord that reads `.selected` right now: the hold if there is one,
    /// otherwise the swept-up set. One property rather than two handed to the
    /// draw list, because they are never both wanted — a hold taken in
    /// selection mode IS the selection, and outside it the selection is empty.
    /// `BoardRender` offsets exactly these by `dragTranslation`, which is
    /// `.zero` unless a hold is in flight, so a swept-up tile nobody is
    /// dragging sits still.
    public var selected: Set<Coord> { tileDrag?.origins ?? selection.coords }

    /// Where the last painted sample was, so a sweep paints the line between
    /// two reported positions rather than the two positions themselves.
    private var paintCursor: CGPoint?

    /// Whether this sweep has crossed a tile at all. A sweep that crossed none
    /// is a tap on empty space, which is the way out of selection mode.
    private var paintedAny = false

    /// What the frozen checker said about the board after the last committed
    /// move. Published state, never recomputed by a reader: `BoardRender` and
    /// the view read `invalidCoords` and `canDraw` off this, so nothing on the
    /// draw path calls `validate` — and nothing calls it per gesture frame.
    public private(set) var validation: BoardValidation
    /// Straight off the frozen `isComplete`. The completeness rule lives in
    /// `BoardValidation` and this must never restate any part of it.
    public var canDraw: Bool { validation.isComplete }

    /// One coord set per word in `validation.invalidWords`, expanded once per
    /// commit so the draw path is a set lookup rather than a walk of the word
    /// list per drawn cell. Kept per WORD rather than flattened because the
    /// tint has to be dropped a whole run at a time — see `invalidCoords`.
    private var invalidRuns: [Set<Coord>] = []

    /// The runs as the board reads them WITH the held tiles gone, computed once
    /// at pickup by `began(_:on:against:haptics:)`. `nil` whenever nothing is
    /// held — and also for the whole of a hold begun through the plain `began`,
    /// which has no board to take the letters out of.
    private var liftedRuns: [Set<Coord>]?

    /// The coords the surface is tinting right now, and empty almost always.
    ///
    /// Nothing goes red for putting a word down. A bad word is only news when
    /// the player claims to be done with it, so this is written by
    /// `attemptedCompletion` and cleared again — by `clearFlash` when the flash
    /// has run its course, and by `revalidate` the moment any tile moves, so a
    /// flash can never outlive the board it was an answer about.
    public private(set) var flashedInvalid: Set<Coord> = []

    /// The player pressed Draw or claimed the win. Lights the bad runs when the
    /// board is not finished, and returns whether the claim stands.
    ///
    /// The gate is `canDraw`, the same published answer the button's enabled
    /// state reads — no completeness rule is restated here. A caller that acts
    /// on the `true` and ignores the `false` gets the flash for free.
    @discardableResult
    public mutating func attemptedCompletion() -> Bool {
        flashedInvalid = canDraw ? [] : blockedCoords
        return canDraw
    }

    /// Ends a flash. Whoever started one owns the timing; this type holds no
    /// clock — a pure value type that scheduled its own fade would be a second
    /// source of truth about what is on screen.
    public mutating func clearFlash() { flashedInvalid = [] }

    /// Every coord that reads as part of a bad word right now.
    ///
    /// Not what the surface draws — `flashedInvalid` is. This is the standing
    /// truth a flash is taken FROM, and the answer a lift changes as it goes.
    ///
    /// While a letter is held this is the tint of the board the lift LEAVES
    /// BEHIND, not the tint of the last commit. Both directions matter and only
    /// a real check gets both: lifting the letter that spoiled a word clears the
    /// rest of that word, and lifting the `e` out of `cue` turns the `cu` red —
    /// the second is a word the board has never seen before and no amount of
    /// arithmetic over the previous answer can discover it.
    ///
    /// Computed rather than stored so it follows the hold with no write site of
    /// its own; `revalidate` stays the ONE place *published* validation and
    /// `canDraw` are written, and a hold never touches either. A board with a
    /// hole in it is not a board anyone may draw from.
    public var invalidCoords: Set<Coord> {
        (liftedRuns ?? invalidRuns).reduce(into: Set()) { $0.formUnion($1) }
    }

    /// Every tile standing between the board and a Draw.
    ///
    /// A bad word is not the only way to be unfinished, and on the opening deal
    /// it is not even the common one: twenty-one tiles scattered across the
    /// surface spell nothing wrong — they spell nothing at all. `isComplete`
    /// refuses them on `clusterCount`, and a flash of `invalidCoords` alone
    /// would light up nothing whatsoever, which is exactly the silence a player
    /// reads as a broken button.
    ///
    /// So both reasons flash: the words that are wrong, and the tiles that are
    /// not yet part of the one grid the rest of them form.
    public var blockedCoords: Set<Coord> { invalidCoords.union(strandedCoords) }

    /// The tiles outside the biggest cluster, as of the last commit. Stored
    /// beside `invalidRuns` and written in the same one place, so the two halves
    /// of ``blockedCoords`` can never answer about different boards.
    private var strandedCoords: Set<Coord> = []

    /// Which tiles are not part of the main grid.
    ///
    /// The biggest cluster is taken to be the board the player is building and
    /// everything else is what they have left to place. On the opening deal
    /// every cluster is one tile, so an arbitrary one survives and the other
    /// twenty flash — which reads correctly: nearly everything is still loose.
    ///
    /// A board of one tile is a single cluster with no bad word and still not a
    /// grid, so the whole of it flashes. That is `isComplete`'s `tileCount`
    /// floor, seen from the other side.
    private static func stranded(_ board: Board) -> Set<Coord> {
        let all = Set(board.placementList.map(\.coord))
        guard all.count >= 2 else { return all }
        let clusters = board.clusters
        guard clusters.count > 1 else { return [] }
        // Anchored, not a bare `max(by:)` on count: two clusters of the same
        // size must resolve the same way every run, and `board.clusters` comes
        // out of a `Set`. Ties fall to the lowest coord in reading order.
        let anchor = { (cluster: Set<Coord>) in
            cluster.min(by: { ($0.row, $0.col) < ($1.row, $1.col) }) ?? Coord(row: 0, col: 0)
        }
        let main = clusters.max(by: {
            ($0.count, anchor($1).row, anchor($1).col)
                < ($1.count, anchor($0).row, anchor($0).col)
        }) ?? []
        return all.subtracting(main)
    }

    /// Where each tile sits INSIDE its cell, in cell units, keyed by tile id.
    ///
    /// This is what makes the surface a table rather than a spreadsheet. The
    /// lattice stays exact — the frozen checker still reads whole `Coord`s, so
    /// which letters form a word has the same answer it always had — and this
    /// is the only thing between that lattice and the screen.
    ///
    /// One rule holds the whole model up: **every tile in a connected cluster
    /// carries the same offset.** So a loose tile is a cluster of one and
    /// scatters on its own, while letters that touch share one offset and read
    /// as a single aligned block. Connecting two letters IS the snap — no
    /// animation decides it and no code special-cases it.
    ///
    /// Rebuilt whole on each commit rather than edited, so it can never
    /// disagree with the board it was derived from, and a tile that left the
    /// board leaves no entry behind.
    public private(set) var tileOffsets: [UUID: CGSize] = [:]

    /// How far a cluster may sit from its lattice position, in cells, on each
    /// axis. Bounded well inside the `BoardLayout.step` gap between arrivals, so
    /// scattered tiles never touch and the eye is never shown two letters
    /// adjacent that the checker reads as separate.
    public static let scatter: CGFloat = 0.4

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
    /// Takes hold of the WHOLE selection when the grab landed on a tile the
    /// selection already holds, and of the one tile otherwise. `TileDrag`
    /// carries a set and one lattice delta either way, so a group move is the
    /// ordinary move with more coords in it — there is no second commit path
    /// here for a batch, and so no second place for a batch to land half done.
    public mutating func began(_ grab: BoardGesture.Grab, haptics: some BoardHaptics) {
        guard !inputLocked else { return }
        if case .tile(_, let coord) = grab, selection.isActive, selection.contains(coord) {
            tileDrag = TileDrag(origins: selection.coords, anchor: coord, haptics: haptics)
        } else {
            tileDrag = TileDrag(grab: grab, haptics: haptics)
        }
        dragTranslation = .zero
        paintCursor = nil
        paintedAny = false
        liftedRuns = nil
    }

    /// Takes hold exactly as above, and re-reads the board the hold leaves
    /// behind so the tint is honest for the whole gesture.
    ///
    /// This is the one dictionary pass a gesture makes, and it is made ONCE, at
    /// touch-down, over a board of at most 144 tiles — not per frame. Nothing
    /// here writes `validation` or `canDraw`: the answer is a drawing decision
    /// about a board that is missing letters, and it lives only as long as the
    /// fingers do.
    public mutating func began(
        _ grab: BoardGesture.Grab,
        on board: Board,
        against dictionary: some WordList,
        haptics: some BoardHaptics
    ) {
        began(grab, haptics: haptics)
        guard let held = tileDrag?.origins else { return }
        let lifted = TileDrag.lifting(held, from: board)
        liftedRuns = Self.runs(of: lifted.validate(against: dictionary))
    }

    /// Enters selection mode, keeping whatever is already swept up. Refused
    /// while locked: a mode entered behind a lock would be a selection begun
    /// while locked, one finger-move later.
    public mutating func enterSelection() {
        guard !inputLocked else { return }
        selection.enter()
    }

    /// Sweeps the tiles between the last reported position and this one into
    /// the selection. `board` is read, never written — a painted selection is a
    /// drawing decision, and the board does not change until a group drag
    /// commits through `commit` below.
    ///
    /// A no-op outside selection mode and while locked, so the ordinary drag
    /// path can call it unguarded.
    public mutating func painting(
        from start: CGPoint,
        to point: CGPoint,
        on board: Board,
        camera: BoardCamera
    ) {
        guard !inputLocked, selection.isActive else { return }
        let crossed = selection.paint(
            from: paintCursor ?? start, to: point, on: board, camera: camera,
            // The published table, not one derived here. The sweep has to hit
            // the tiles the player can SEE, which is where the offsets put them.
            offsets: tileOffsets
        )
        if crossed > 0 { paintedAny = true }
        paintCursor = point
    }

    /// Ends a sweep. One that crossed no tile at all is a tap on empty space,
    /// and that clears the selection and leaves the mode.
    ///
    /// Crossed, not newly selected: sweeping back over tiles already swept up
    /// must not read as a tap. This is the way out, and it costs no tile move,
    /// which is why it is answered here rather than by any board state.
    public mutating func endedPainting() {
        if !paintedAny { selection.clear() }
        paintCursor = nil
        paintedAny = false
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
        // The offsets as they stand BEFORE this commit, which is what the tiles
        // were drawn at while the finger was down — read once here because
        // `revalidate` below overwrites the table with the offsets of the board
        // that results from this very move.
        let drawn = tileOffsets
        let next = tileDrag.drop(
            translation: translation, on: board, camera: camera,
            threshold: threshold, offsets: drawn
        )
        // The selection follows the tiles it was holding. Asked of the drag
        // rather than derived from the board that came back: the drag is the
        // one place the delta is decided, and it answers nil on exactly the
        // refusals that left the board alone, so a refused group move leaves
        // the selection on the cells the tiles are still standing on.
        if selection.isActive, tileDrag.origins == selection.coords,
           let landed = tileDrag.landed(
               translation: translation, on: board, camera: camera,
               threshold: threshold, offsets: drawn
           ) {
            selection.replace(with: landed)
        }
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
        invalidRuns = Self.runs(of: validation)
        strandedCoords = Self.stranded(board)
        // Any commit ends a flash: it was an answer about the board as it stood
        // when the player claimed to be done, and that board no longer exists.
        flashedInvalid = []
        tileOffsets = Self.offsets(for: board, carrying: tileOffsets)
    }

    /// One coord set per bad word. Shared by the committed tint and the tint of
    /// a board with letters lifted out of it, so the two can never expand the
    /// same answer two different ways.
    private static func runs(of validation: BoardValidation) -> [Set<Coord>] {
        validation.invalidWords.map { word in
            Set(
                // `text.count` letters from `origin` along `direction`. Every
                // one of those coords holds a tile by construction — the word
                // was read off the board — so no overflow guard is needed that
                // `Board` itself did not already need to place them.
                (0..<word.text.count).map { step in
                    word.direction == .across
                        ? Coord(row: word.origin.row, col: word.origin.col + step)
                        : Coord(row: word.origin.row + step, col: word.origin.col)
                }
            )
        }
    }

    /// One offset per cluster, handed to every tile in it.
    ///
    /// The offset a cluster ALREADY had wins, so a blob does not move because
    /// something joined it. Offsets are history, not a function of the board:
    /// where a word sits on the table is where the player last put it, and a
    /// rule derived from the board alone would slide the whole blob sideways
    /// every time a letter landed on its edge.
    ///
    /// The offset most of the cluster is already carrying wins the merge — so
    /// the big blob holds its place and the joining letter is the one that
    /// snaps flush into it, which is the "connect letters and they grid"
    /// behaviour seen from the other side. Ties, and clusters made only of
    /// tiles no table has ever held, fall back to the deterministic scatter
    /// below, seeded from the cluster's lowest coord in reading order.
    private static func offsets(
        for board: Board, carrying previous: [UUID: CGSize]
    ) -> [UUID: CGSize] {
        var table: [UUID: CGSize] = [:]
        for cluster in board.clusters {
            guard let anchor = cluster.min(by: { ($0.row, $0.col) < ($1.row, $1.col) }),
                  let seed = board.tile(at: anchor)
            else { continue }

            let tiles = cluster.compactMap { board.tile(at: $0) }
            // A linear tally rather than a dictionary: `CGSize` only conforms
            // to `Hashable` on macOS 15, which the test package predates, and a
            // cluster holds a handful of tiles.
            var tally: [(offset: CGSize, count: Int)] = []
            for tile in tiles {
                guard let held = previous[tile.id] else { continue }
                if let seen = tally.firstIndex(where: { $0.offset == held }) {
                    tally[seen].count += 1
                } else {
                    tally.append((offset: held, count: 1))
                }
            }
            // A tie falls to the scatter rather than to whichever tile the set
            // happened to iterate first, so two loose letters meeting land the
            // same way every time — and so this answer does not depend on
            // `Set` ordering, which the offsets must never do.
            let leaders = tally.filter { $0.count == (tally.map(\.count).max() ?? 0) }
            let offset = leaders.count == 1 ? leaders[0].offset : Self.scattered(seed.id)

            for tile in tiles { table[tile.id] = offset }
        }
        return table
    }

    /// A stable ±`scatter` cells, read straight out of the id's own bytes.
    ///
    /// Not `hashValue`: Swift seeds that per process, so the same board would
    /// scatter differently on every launch and no test could pin it. The bytes
    /// of a `UUID` are fixed for the life of the tile, so a board laid out twice
    /// looks identical both times and a tile keeps its place across a relaunch.
    private static func scattered(_ id: UUID) -> CGSize {
        let bytes = id.uuid
        return CGSize(
            width: (CGFloat(bytes.0) / 255 - 0.5) * 2 * scatter,
            height: (CGFloat(bytes.1) / 255 - 0.5) * 2 * scatter
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
        liftedRuns = nil
    }
}
