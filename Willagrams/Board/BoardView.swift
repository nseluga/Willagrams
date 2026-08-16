import SwiftUI
import WillagramsRules

/// The board surface: an empty-cell grid with the placed tiles sitting on it,
/// pannable, zoomable, and recenterable.
///
/// Deliberately dumb. Every decision about what to draw comes from
/// `BoardRender.cells(board:camera:in:)`, and every decision a gesture makes
/// comes from `BoardGesture` and `BoardCamera` — this file only wires SwiftUI's
/// gestures to them and holds the resulting camera.
public struct BoardView: View {

    /// The live board. Owned here for the same reason as the camera: a
    /// committed drag has to land somewhere, and nothing above this view exists
    /// yet to own it. The initializer's board is the starting value.
    @State private var board: Board

    /// The live camera. Owned here because nothing above this view exists yet
    /// to own it; the initializer's camera is the starting value.
    @State private var camera: BoardCamera

    /// The drag in flight, or nil between drags. Built once on the first
    /// change and kept until release, which is what makes the pan-or-tile
    /// decision unrepeatable inside one gesture.
    ///
    /// It carries its own touch-down point because `onEnded` is the only thing
    /// that clears this, and SwiftUI skips `onEnded` when a gesture is
    /// cancelled (a system edge swipe, backgrounding, the view going away).
    /// Reusing what a cancelled gesture left behind would leak both the grab
    /// decision and the pan origin into the next, unrelated touch.
    @State private var drag: BoardGesture.Drag?

    /// The pinch midpoint at touch-down and the camera as it stood there.
    /// `MagnifyGesture` reports a magnification cumulative from that moment, so
    /// it has to be applied to that camera rather than to the live one — and
    /// the anchor is stored beside it for the same staleness reason as `drag`.
    @State private var pinch: (anchor: CGPoint, camera: BoardCamera)?

    /// The tile-drag session: what is held, how far it has travelled, and
    /// whether the surface accepts a hold at all. Every decision it makes lives
    /// in `BoardModel`, which is pure and executable by `Tests/BoardTests`;
    /// this view only reports touches into it and draws what comes back.
    ///
    /// A second finger arriving is handled — the pinch path cancels the
    /// session on its first change, because with no minimum distance the first
    /// finger has usually picked a tile up by then.
    ///
    /// ponytail: the other cancellations (a system edge swipe, backgrounding)
    /// still never reach `onEnded`, so the lifted tile stays drawn where the
    /// finger left it until the next touch rebuilds or clears the session. The
    /// BOARD is untouched either way — only the drawing is stale. Give it its
    /// own reset when SwiftUI exposes a cancellation callback for `.gesture`,
    /// or when a real session shows it happening often enough to notice.
    @State private var model: BoardModel

    /// Real hardware. `TileDrag` only ever sees the protocol, so the decisions
    /// about which feel fires when are executed by the test package with a
    /// recording double in this slot.
    private let haptics = TileFeedback()

    /// The lock as the OWNER of this view sets it, kept apart from the model's
    /// copy because `@State`'s initial value is read once per view identity
    /// while this changes as often as the owner likes. `.onChange` below is
    /// what carries a later change across.
    ///
    /// What sets it, and why, is none of this view's business: it takes a
    /// boolean and asks no questions.
    private let inputLocked: Bool

    /// The word list every committed move is checked against. Held as an
    /// existential rather than making this view generic: the view never calls
    /// it, it only hands it to `BoardModel.commit`, which opens it.
    private let dictionary: any WordList

    public init(
        board: Board,
        camera: BoardCamera,
        dictionary: any WordList,
        inputLocked: Bool = false
    ) {
        _board = State(initialValue: board)
        _camera = State(initialValue: camera)
        // Deliberately the CHEAP init, not the seeding one. `State(initialValue:)`
        // takes a plain argument rather than an autoclosure, so whatever is
        // written here runs on every re-init of this view — as often as the
        // owner updates, per the note on `inputLocked` — and everything after
        // the first is thrown away. A check belongs on a commit or on an
        // appearance, not on a parent's body evaluation. `.onAppear` below
        // publishes the first answer, once.
        _model = State(initialValue: BoardModel(inputLocked: inputLocked))
        self.dictionary = dictionary
        self.inputLocked = inputLocked
    }

    public var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)

            BoardSurface(
                board: board,
                camera: camera,
                rect: rect,
                selected: model.selected,
                dragTranslation: model.dragTranslation,
                invalid: model.invalidCoords,
                offsets: model.tileOffsets
            )
                // The surface is a color and a Canvas, both of which are
                // already hit-testable, but the empty cells between tiles have
                // to be too or a pan could only start on the background.
                .contentShape(Rectangle())
                // Two attachments, not an exclusive chain. `.exclusively(before:)`
                // only runs its second gesture once the FIRST fails, and a pinch
                // recognizer holding a single touch never fails — it sits in
                // `.possible` for the life of the touch. Under that chain one
                // finger reached `DragGesture` never: on a device the board could
                // be pinched but not panned and no tile could be picked up at all.
                //
                // The fight `.exclusively` was there to prevent — two fingers
                // drifting far enough to feed the drag recognizer, so pan and zoom
                // alternate writing the camera from their own start snapshots — is
                // now refused by the `pinch` guard in `dragGesture.onChanged`,
                // which is checked state rather than an inferred recognizer
                // outcome.
                .gesture(dragGesture)
                // The pinch is a UIKit recognizer, not a SwiftUI gesture:
                // `MagnifyGesture` freezes its midpoint at the instant the
                // second finger lands, so a pinch could only ever zoom about
                // where it began. The reporter is inert and sits over the board
                // purely to name a coordinate space — it takes no touches away
                // from the drag beneath it.
                .overlay(
                    BoardPinchReporter(
                        onChange: { scale, midpoint in pinched(scale: scale, midpoint: midpoint) },
                        onEnd: { pinch = nil }
                    )
                )
                // Attached AFTER the camera gestures on purpose: the later
                // modifier is the outer one, so the double tap gets first look
                // and a single tap falls straight through to the drag. It is a
                // separate attachment rather than another arm of the exclusive
                // chain because the pinch must keep first refusal over
                // everything one finger does, and a double tap must not have to
                // fail before a drag can start.
                //
                // A device session DID show the drag swallowing the second tap:
                // double tap did nothing, and with it multi-select was
                // unreachable, since every path into the selection set is gated
                // on `isActive` and nothing else calls `enterSelection`.
                //
                // `.onTapGesture` attaches a COMPETING gesture, and
                // `DragGesture(minimumDistance: 0)` leaves `.possible` the
                // instant a finger lands, so the drag won every sequence and the
                // tap never completed. `.simultaneousGesture` lets both see the
                // touches, which is what this needs: the taps enter selection
                // while the drag keeps doing exactly what it already does.
                //
                // Deliberately NOT `.highPriorityGesture` or
                // `TapGesture.exclusively(before:)` — both make the drag wait out
                // the double-tap timeout, which is ~0.3s of dead time on every
                // single pickup. Removing that dead time is the whole reason
                // `minimumDistance: 0` is there.
                .simultaneousGesture(TapGesture(count: 2).onEnded { model.enterSelection() })
                .overlay(alignment: .topTrailing) { recenterControl(in: rect) }
                // The lock is a plain assignment: `BoardModel` cancels an
                // in-flight hold on its own when it lands, so there is no
                // second call here to forget. `initial: true` because a view
                // reconstructed around a live lock must not come back unlocked.
                .onChange(of: inputLocked, initial: true) { model.inputLocked = inputLocked }
                // The first and only unforced check: the starting board has
                // never been committed here, so without this a board that
                // arrives already refused would draw untinted until the player
                // moved something. `.onAppear` rather than `.task` — it is
                // synchronous work that runs before the surface is on screen,
                // so the first frame the player sees is already tinted, and
                // there is no async hop to schedule. Once per appearance, never
                // per body evaluation and never per gesture frame.
                .onAppear { model.seed(board, against: dictionary) }
        }
    }

    // MARK: - Gestures

    /// One finger. The hit test runs on `value.startLocation` — the touch-down
    /// point, not the current one — and only when no drag is in flight, so a
    /// finger that began on an empty cell keeps panning across every tile it
    /// crosses.
    /// A stored drag is reused only while its touch-down point is the one this
    /// event reports; a different `startLocation` means a new gesture, so the
    /// grab is decided again. That is the same "decide once" rule, scoped to
    /// one gesture rather than to whatever the last cancelled one left behind.
    ///
    /// The tile drag is built in the same breath, and only when the grab is
    /// freshly decided: constructing it fires the pickup feel, so one gesture
    /// gets exactly one pickup however many changes SwiftUI reports.
    /// `minimumDistance: 0`, not the default 10: the criterion is that TOUCHING
    /// a tile lifts it, and at the default the selection, the `tileLift` offset
    /// and the pickup feel all wait for 10pt of travel — a fifth of a cell of
    /// dead movement before the board admits the finger landed.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // The other half of dropping `.exclusively(before:)`: while two
                // fingers are down the pinch owns the camera outright, so the
                // drag frames a second finger produces are dropped rather than
                // writing a pan from a stale snapshot. Checked state, not a
                // recognizer failing.
                guard pinch == nil else { return }
                // ponytail: a lock landing mid-gesture leaves the carried grab
                // `.tile`, so that finger neither drags nor pans until it lifts
                // — the next touch down pans normally. Rebuilding the `Drag`
                // here would be worse, not better: `value.translation` is
                // cumulative from touch-down, so a fresh `Drag` would take the
                // current pan as its origin and then jump the board by all the
                // pre-lock travel at once. Upgrade when a real session shows the
                // inert finger mattering: give `Drag` a translation offset it
                // subtracts, so a mid-gesture rebuild can discount the travel
                // already spent.
                let carried = drag.flatMap { $0.startLocation == value.startLocation ? $0 : nil }
                let inFlight = carried ?? BoardGesture.Drag(
                    at: value.startLocation, in: board, selection: model.selection,
                    camera: camera, inputLocked: model.inputLocked,
                    // The grab is decided against where the tiles are DRAWN.
                    // Without this a scattered tile refuses to lift along the
                    // edge it overhangs, which is the dead-input bug back in
                    // geometric form.
                    offsets: model.tileOffsets
                )
                if carried == nil {
                    model.began(inFlight.grab, haptics: haptics)
                }
                drag = inFlight
                model.moved(to: value.translation)
                camera = inFlight.camera(camera, translatedBy: value.translation)
                // The sweep, on the decision already taken at touch-down. Two
                // points from SwiftUI and no arithmetic here: the session walks
                // the line between them, so a fast finger paints the tiles it
                // crossed rather than the ones two frames happened to land on.
                if case .paint = inFlight.grab {
                    model.painting(from: value.startLocation, to: value.location, on: board, camera: camera)
                }
            }
            .onEnded { value in
                if !model.dragging.isEmpty {
                    // The whole commit is one assignment of one value type:
                    // `commit` hands back either the moved board or the one it
                    // was given, so a refused drop cannot leave a partial move
                    // behind. The snap-or-refuse feel fires inside it, and it
                    // clears the session itself.
                    // The commit belongs INSIDE the animation: clearing the
                    // translation is what returns the tile from the finger to
                    // its cell, and outside the closure that half of the move
                    // would jump while the board's half slid.
                    withAnimation(DesignTokens.Motion.snap) {
                        board = model.commit(
                            translation: value.translation,
                            on: board,
                            camera: camera,
                            threshold: DesignTokens.Motion.snapThreshold,
                            against: dictionary
                        )
                    }
                } else if case .some(.paint) = drag?.grab {
                    // A sweep that crossed no tile is a tap on empty space, and
                    // that is the way out of selection mode. It runs on the
                    // release of the gesture that was decided a sweep, never on
                    // a pan or a hold, so nothing else can clear a selection by
                    // accident.
                    model.endedPainting()
                }
                drag = nil
            }
    }

    /// Two fingers. `startLocation` is the pinch midpoint at the moment the
    /// gesture began, and `BoardCamera.magnified(by:about:)` holds the board
    /// position under it fixed — through the camera's own cell-size clamp, so
    /// nothing here knows a zoom bound exists.
    ///
    /// The stored start is carried over only while the midpoint is unchanged,
    /// for the same cancelled-gesture reason as `drag`.
    /// Zoom and pan in one motion, composed from the live midpoint.
    ///
    /// `magnified(by:about:)` holds the board point under the midpoint the
    /// fingers STARTED at fixed, and the pan then carries that point to where
    /// the midpoint is now. So the board position the fingers landed on stays
    /// under the fingers however far they spread and however far they slide —
    /// which is "zoom and scroll together, about where the zoom happens".
    ///
    /// Both are computed from the snapshot taken when the pinch began, so the
    /// two never accumulate on each other: every frame is a whole answer.
    private func pinched(scale: CGFloat, midpoint: CGPoint) {
        // A second finger landing may arrive after the first has already lifted
        // a tile, and with no minimum distance it usually has. Drop that pickup
        // or the tile stays lifted under a pinch that has nothing to do with it.
        // No haptic: a pinch stealing the gesture is a cancellation, not a
        // refused drop.
        model.cancel()
        let start = pinch ?? (anchor: midpoint, camera: camera)
        if pinch == nil { pinch = start }
        camera = start.camera
            .magnified(by: scale, about: start.anchor)
            .panned(by: CGSize(
                width: midpoint.x - start.anchor.x,
                height: midpoint.y - start.anchor.y
            ))
    }

    // MARK: - Recenter

    /// Frames every placed tile. `BoardGesture.recentered` reads the
    /// placements; this view never does, so the draw path stays a function of
    /// the viewport.
    private func recenterControl(in rect: CGRect) -> some View {
        Button {
            withAnimation(DesignTokens.Motion.snap) {
                camera = BoardGesture.recentered(camera, over: board, in: rect)
            }
        } label: {
            Image(systemName: Self.recenterSymbol)
        }
        .buttonStyle(.brandQuiet)
        .padding(DesignTokens.Space.m)
        .accessibilityLabel(Self.recenterLabel)
    }

    /// Not a `Terminology` constant: that file is the fence around the game's
    /// vocabulary and is frozen, and recentering a camera is a control, not a
    /// game concept. Named here so there is still exactly one copy of it.
    private static let recenterLabel = "Recenter"
    private static let recenterSymbol = "scope"
}

/// The drawn surface, animatable as one piece.
///
/// `Canvas` contents do not interpolate under an implicit animation while an
/// offset `BrandTile` does, so a `withAnimation` recenter would slide the tiles
/// and snap the grid underneath them. Conforming to `Animatable` over the
/// camera's pan and zoom makes SwiftUI re-evaluate this body once per frame
/// with an interpolated camera instead — grid and tiles then derive from the
/// same numbers and move together.
private struct BoardSurface: View, Animatable {

    let board: Board
    var camera: BoardCamera
    let rect: CGRect
    /// The held tiles, or the swept-up ones when nothing is held. `BoardRender`
    /// turns these into `.selected` cells.
    let selected: Set<Coord>
    let dragTranslation: CGSize
    /// The coords the session published after the last committed move. This
    /// view checks nothing itself — it has no word list to check against.
    let invalid: Set<Coord>
    /// Where each tile sits inside its cell, in cell units. Published by the
    /// session and read straight through to `BoardRender` — this view decides
    /// no position of its own.
    let offsets: [UUID: CGSize]

    /// Pan width, pan height, zoom — the whole of what an animation between
    /// two cameras has to interpolate. `baseCellSize` is not in here: it is a
    /// fixed property of the surface, and `recenter` moves `zoom`, not it.
    /// `nonisolated` because `View` is main-actor isolated and `Animatable` is
    /// not — SwiftUI reads this off the animation's own thread. Safe: every
    /// stored property here is a Sendable value type.
    nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(camera.pan.width, camera.pan.height), camera.zoom) }
        set {
            camera.pan = CGSize(width: newValue.first.first, height: newValue.first.second)
            camera.zoom = newValue.second
        }
    }

    var body: some View {
        let cells = BoardRender.cells(
            board: board, camera: camera, in: rect,
            dragging: selected, by: dragTranslation, invalid: invalid, offsets: offsets
        )
        let cellSize = camera.cellSize

        ZStack(alignment: .topLeading) {
            // The whole surface. No cell is drawn: the lattice is how the
            // checker decides which letters form a word, and the player is
            // never shown it — they are looking at a bare table with letters
            // lying on it. Deleting the empty-cell Canvas that used to paint
            // one rounded rect per visible coord IS that change, and it takes
            // the ~2,400-fill-per-frame draw cost with it.
            DesignTokens.Palette.boardSurface

            // Real views, not Canvas drawing: BrandTile owns the face,
            // bevel, ring and lift, and this must not re-implement any of
            // it. Only cells carrying a tile reach here.
            // Keyed by tile id, not by coord: a released tile IS animated
            // from the finger to its new cell — `onEnded` clears the drag
            // offset inside the same `withAnimation` as the board change —
            // and that only interpolates while the moved tile stays the same
            // view. Keyed by coord, SwiftUI would destroy it and build a
            // fresh one at the destination, and the move would cut. `Tile.id`
            // is stable across a move for exactly this reason. The list is
            // already filtered to non-nil tiles, so no two keys are nil.
            // `cell.tilePoint`, not `cell.point`: a tile in flight has left its
            // cell, and the grid hole it came from must stay put under it.
            ForEach(cells.filter { $0.tile != nil }, id: \.tile?.id) { cell in
                if let tile = cell.tile, let tilePoint = cell.tilePoint {
                    BrandTile(
                        letter: tile.letter,
                        size: cellSize,
                        state: (cell.state ?? .idle).brandState
                    )
                    // The tint for a tile in a refused run: the same multiply,
                    // applied to the tile's own drawing rather than through an
                    // overlay layer blended against whatever sits behind it.
                    // That difference is the point — a square overlay blends
                    // over the four rounded corners too and tints the surface
                    // through them, while this multiplies BrandTile's own
                    // content and stops exactly where the tile does. `.white`
                    // is the identity of a multiply, so a valid tile is left
                    // as BrandTile drew it.
                    // Still an unconditional modifier, not an `if`: a branch
                    // would hand SwiftUI a new subtree the moment a run turns
                    // good or bad, and the released tile's slide into its cell
                    // would cut. The colour is the only decision here, and it
                    // is read from published state, never computed.
                    .colorMultiply(cell.isInvalid ? DesignTokens.Palette.danger : .white)
                    .offset(x: tilePoint.x, y: tilePoint.y)
                    // `cells` arrives in `visibleCoords` row-major order, so a
                    // tile dragged down or right would otherwise draw BEHIND
                    // every tile at a greater row and the lift would read as
                    // sunk. The tile under the finger belongs on top of the
                    // ones it is passing over.
                    .zIndex(cell.state == .selected ? 1 : 0)
                }
            }
        }
        .clipped()
    }
}

private extension BoardRender.TileState {
    /// The only place the pure render state becomes tile art.
    var brandState: BrandTile.State {
        switch self {
        case .idle: .idle
        case .placed: .placed
        // BrandTile applies `Motion.tileLift` and the ring itself for this
        // state, so the lift is named in exactly one place and not here.
        case .selected: .selected
        }
    }
}

/// A run of four plus one loose tile, so `.placed` and `.idle` are both on
/// screen — the pair of previews below is how the light/dark surface is checked.
///
/// The local is `fixture`, not `board`: `BoardSourceTests` pins that nothing
/// named `board` is mutated in this file, which is how the view is held to
/// committing every change through `TileDrag`.
private func previewBoard() -> Board {
    var fixture = Board()
    for (offset, letter) in "WILL".enumerated() {
        try? fixture.place(Tile(letter: letter), at: Coord(row: 0, col: offset))
    }
    try? fixture.place(Tile(letter: "Z"), at: Coord(row: 3, col: 6))
    return fixture
}

private let previewCamera = BoardCamera(pan: CGSize(width: DesignTokens.Space.xl, height: DesignTokens.Space.xl))

/// In-memory rather than the bundled list: a preview must not depend on a
/// resource load that can throw.
private let previewDictionary = EnableWordList(words: ["WILL"])

#Preview("Light") {
    BoardView(board: previewBoard(), camera: previewCamera, dictionary: previewDictionary)
}
#Preview("Dark") {
    BoardView(board: previewBoard(), camera: previewCamera, dictionary: previewDictionary)
        .preferredColorScheme(.dark)
}
/// The same board against a list that does not hold WILL, so the danger tint is
/// on screen next to an untinted loose tile.
#Preview("Refused") {
    BoardView(board: previewBoard(), camera: previewCamera, dictionary: EnableWordList(words: []))
}
