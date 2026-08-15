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

    /// The tiles in flight, built once per gesture beside `drag` — building it
    /// is what fires the pickup feel, so it must not be rebuilt per frame.
    /// Nil whenever the finger took hold of the camera rather than a tile.
    ///
    /// A second finger arriving is handled — `magnifyGesture` clears this on its
    /// first change, because with no minimum distance the first finger has
    /// usually picked a tile up by then.
    ///
    /// ponytail: the other cancellations (a system edge swipe, backgrounding)
    /// still never reach `onEnded`, so the lifted tile stays drawn where the
    /// finger left it until the next touch rebuilds or clears this. The BOARD is
    /// untouched either way — only the drawing is stale. Give this its own reset
    /// when SwiftUI exposes a cancellation callback for `.gesture`, or when a
    /// real session shows it happening often enough to notice.
    @State private var tileDrag: TileDrag?

    /// How far the finger has moved since it took hold.
    ///
    /// Assigned, never accumulated: `DragGesture` already reports a translation
    /// cumulative from its own start, so each frame REPLACES this rather than
    /// adding to it and there is no stored quantity that can run away behind a
    /// clamped render. Both readers (`BoardRender.cells` and `TileDrag.drop`)
    /// handle a non-finite value themselves.
    @State private var dragTranslation: CGSize = .zero

    /// Real hardware. `TileDrag` only ever sees the protocol, so the decisions
    /// about which feel fires when are executed by the test package with a
    /// recording double in this slot.
    private let haptics = TileFeedback()

    public init(board: Board, camera: BoardCamera) {
        _board = State(initialValue: board)
        _camera = State(initialValue: camera)
    }

    public var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)

            BoardSurface(
                board: board,
                camera: camera,
                rect: rect,
                dragging: tileDrag?.origins ?? [],
                dragTranslation: dragTranslation
            )
                // The surface is a color and a Canvas, both of which are
                // already hit-testable, but the empty cells between tiles have
                // to be too or a pan could only start on the background.
                .contentShape(Rectangle())
                // One gesture, not two simultaneous ones. Two fingers drift
                // far enough to feed a drag recognizer, so under
                // `.simultaneousGesture` a pinch feeds BOTH recognizers and
                // they alternate writing the camera from their own start
                // snapshots — pan and zoom fight instead of composing.
                // `.exclusively(before:)` gives the pinch first refusal, so a
                // two-finger touch never reaches `DragGesture` at all. That
                // matters more now the drag has no minimum distance of its own
                // to filter the second finger out.
                .gesture(magnifyGesture.exclusively(before: dragGesture))
                .overlay(alignment: .topTrailing) { recenterControl(in: rect) }
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
                let carried = drag.flatMap { $0.startLocation == value.startLocation ? $0 : nil }
                let inFlight = carried ?? BoardGesture.Drag(
                    at: value.startLocation, in: board, camera: camera
                )
                if carried == nil {
                    tileDrag = TileDrag(grab: inFlight.grab, haptics: haptics)
                }
                drag = inFlight
                dragTranslation = value.translation
                camera = inFlight.camera(camera, translatedBy: value.translation)
            }
            .onEnded { value in
                if let tileDrag {
                    // The whole commit is one assignment of one value type:
                    // `drop` hands back either the moved board or the one it
                    // was given, so a refused drop cannot leave a partial move
                    // behind. The snap-or-refuse feel fires inside it.
                    // The resets belong INSIDE the animation with the board
                    // change: clearing the translation is what returns the tile
                    // from the finger to its cell, and outside the closure that
                    // half of the move would jump while the board's half slid.
                    withAnimation(DesignTokens.Motion.snap) {
                        board = tileDrag.drop(
                            translation: value.translation,
                            on: board,
                            camera: camera,
                            threshold: DesignTokens.Motion.snapThreshold
                        )
                        self.tileDrag = nil
                        dragTranslation = .zero
                    }
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
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // A second finger landing takes the gesture away from
                // `DragGesture`, which then never reaches `onEnded` — and with
                // no minimum distance the first finger may already have picked
                // a tile up. Drop that pickup here or the tile stays lifted
                // under a pinch that has nothing to do with it.
                //
                // No haptic fires on this path. A pinch stealing the gesture is
                // a cancellation, not a refused drop, and firing `.reject` here
                // would put a second reject in a count that must record exactly
                // one per rejected drop. The board is untouched either way.
                if tileDrag != nil {
                    tileDrag = nil
                    dragTranslation = .zero
                }
                let carried = pinch.flatMap { $0.anchor == value.startLocation ? $0.camera : nil }
                let start = carried ?? camera
                pinch = (anchor: value.startLocation, camera: start)
                camera = start.magnified(by: value.magnification, about: value.startLocation)
            }
            .onEnded { _ in pinch = nil }
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
    /// Empty between drags. `BoardRender` turns these into `.selected` cells.
    let dragging: Set<Coord>
    let dragTranslation: CGSize

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
            dragging: dragging, by: dragTranslation
        )
        let cellSize = camera.cellSize

        ZStack(alignment: .topLeading) {
            DesignTokens.Palette.boardSurface

            // One Canvas, not one view per cell: at the 24pt cell floor a
            // landscape iPad viewport holds ~2,400 cells, and 2,400 shape
            // views would make panning and zooming unusable. Canvas resolves
            // the asset-catalog Color in the current environment, so light
            // and dark still come from the catalog.
            Canvas { context, _ in
                let shading = GraphicsContext.Shading.color(DesignTokens.Palette.cellEmpty)
                for cell in cells {
                    context.fill(
                        Path(
                            roundedRect: CGRect(
                                origin: cell.point,
                                size: CGSize(width: cellSize, height: cellSize)
                            )
                            .insetBy(
                                dx: DesignTokens.Stroke.hairline,
                                dy: DesignTokens.Stroke.hairline
                            ),
                            cornerRadius: DesignTokens.Radius.cell
                        ),
                        with: shading
                    )
                }
            }

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

#Preview("Light") { BoardView(board: previewBoard(), camera: previewCamera) }
#Preview("Dark") { BoardView(board: previewBoard(), camera: previewCamera).preferredColorScheme(.dark) }
