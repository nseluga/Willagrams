import SwiftUI
import WillagramsRules

/// The board surface: an empty-cell grid with the placed tiles sitting on it.
///
/// Deliberately dumb. Every decision about what to draw comes from
/// `BoardRender.cells(board:camera:in:)`, and both layers below consume that
/// one array — this view adds no geometry, no state derivation, and no gestures
/// (later lane items own pan/zoom and selection).
public struct BoardView: View {

    public let board: Board
    public let camera: BoardCamera

    public init(board: Board, camera: BoardCamera) {
        self.board = board
        self.camera = camera
    }

    public var body: some View {
        GeometryReader { proxy in
            let cells = BoardRender.cells(
                board: board,
                camera: camera,
                in: CGRect(origin: .zero, size: proxy.size)
            )
            let cellSize = camera.cellSize

            ZStack(alignment: .topLeading) {
                DesignTokens.Palette.boardSurface

                // One Canvas, not one view per cell: at the 24pt cell floor a
                // landscape iPad viewport holds ~2,400 cells, and 2,400 shape
                // views would make the pan/zoom item unusable. Canvas resolves
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
                ForEach(cells.filter { $0.tile != nil }, id: \.coord) { cell in
                    if let tile = cell.tile {
                        BrandTile(
                            letter: tile.letter,
                            size: cellSize,
                            state: (cell.state ?? .idle).brandState
                        )
                        .offset(x: cell.point.x, y: cell.point.y)
                    }
                }
            }
            .clipped()
        }
    }
}

private extension BoardRender.TileState {
    /// The only place the pure render state becomes tile art.
    var brandState: BrandTile.State {
        switch self {
        case .idle: .idle
        case .placed: .placed
        }
    }
}

/// A run of four plus one loose tile, so `.placed` and `.idle` are both on
/// screen — the pair of previews below is how the light/dark surface is checked.
private func previewBoard() -> Board {
    var board = Board()
    for (offset, letter) in "WILL".enumerated() {
        try? board.place(Tile(letter: letter), at: Coord(row: 0, col: offset))
    }
    try? board.place(Tile(letter: "Z"), at: Coord(row: 3, col: 6))
    return board
}

private let previewCamera = BoardCamera(pan: CGSize(width: DesignTokens.Space.xl, height: DesignTokens.Space.xl))

#Preview("Light") { BoardView(board: previewBoard(), camera: previewCamera) }
#Preview("Dark") { BoardView(board: previewBoard(), camera: previewCamera).preferredColorScheme(.dark) }
