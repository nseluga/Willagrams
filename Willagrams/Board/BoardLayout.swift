import Foundation
import CoreGraphics
import WillagramsRules

/// Where tiles arriving from outside go on the board.
///
/// Two arrivals, one rule: the opening set a new game starts with, and the set
/// a Draw delivers later. Both land on the same lattice — one empty cell
/// between tiles on BOTH axes — so nothing that arrives is ever edge-adjacent
/// to anything already there. Touching tiles would read as runs of random
/// letters and tint the whole surface refused before the player has moved.
///
/// Pure Foundation/CoreGraphics, like the rest of the decisions in this lane,
/// so `Tests/BoardTests` executes every one of them with no host app. Nothing
/// here checks the board — that stays the one call in `BoardModel`.
public enum BoardLayout {

    /// Cells between one tile and the next, on both axes. Two is the smallest
    /// step that leaves a gap; one would put every arrival edge to edge with
    /// its neighbour. No DesignTokens key covers a lattice pitch, and that file
    /// is SwiftUI-only anyway, so it is named here.
    public static let step = 2

    /// How many tiles deep the opening block is, before it wraps. The opening
    /// count is an INPUT — it travels on the wire and is about to be
    /// configurable — so the width is derived from it and only the depth is
    /// fixed.
    public static let openingRows = 3

    /// Points of clear viewport left around the opening block when it is
    /// framed, so the outermost tiles are not flush against the edge.
    public static let openingMargin: CGFloat = 24

    // MARK: - Arrival

    /// The board a game opens on: every tile in `tiles`, laid out
    /// `openingRows` deep on the shared lattice.
    ///
    /// The count comes from the array, never from a constant — hand it 21 and
    /// 21 land, hand it 30 and 30 do.
    public static func opening(_ tiles: [Tile]) -> Board {
        laid(tiles, on: Board(), from: Coord(row: 0, col: 0), across: openingWidth(for: tiles.count))
    }

    /// Tiles delivered by a Draw, landing in free cells below whatever is
    /// currently on screen so the player sees them without moving the camera.
    ///
    /// Prefers the rows still inside `rect` and carries on below it only once
    /// those are used up. Never overwrites, never refuses, never throws: the
    /// board is unbounded downward, so there is always another free row.
    public static func delivered(
        _ tiles: [Tile],
        onto board: Board,
        camera: BoardCamera,
        in rect: CGRect
    ) -> Board {
        guard !tiles.isEmpty else { return board }

        let visible = Array(camera.visibleCoords(in: rect))
        // A degenerate frame (a `GeometryReader`'s first zero-size pass) has no
        // cells to prefer. Falling back to the row below the whole board still
        // places every tile rather than dropping the delivery on the floor.
        guard let firstCol = visible.map(\.col).min(),
              let lastCol = visible.map(\.col).max(),
              let top = visible.map(\.row).min(),
              let bottom = visible.map(\.row).max()
        else {
            let below = (board.placementList.map(\.coord.row).max() ?? -step) + step
            return laid(tiles, on: board, from: Coord(row: below, col: 0), across: 1)
        }

        // The lowest tile the player can currently see, not the lowest on the
        // board: content far below the viewport must not push a delivery off
        // screen. `placementList` rather than the visible cells because a
        // viewport holds thousands of cells and a board holds tens of tiles.
        let onScreen = board.placementList.map(\.coord).filter {
            $0.row >= top && $0.row <= bottom && $0.col >= firstCol && $0.col <= lastCol
        }
        let start = (onScreen.map(\.row).max()).map { $0 + step } ?? top

        return laid(
            tiles,
            on: board,
            from: Coord(row: start, col: firstCol),
            across: (lastCol - firstCol) / step + 1
        )
    }

    // MARK: - Framing

    /// `camera` framing every tile on `board` with `margin` points of clear
    /// viewport around the block.
    ///
    /// The framing itself is `BoardCamera.recenter` — this only hands it an
    /// inset rect, so there is no second implementation of fitting content to
    /// a viewport and no second copy of the cell-size clamp.
    public static func framing(
        _ board: Board,
        in rect: CGRect,
        camera: BoardCamera,
        margin: CGFloat = openingMargin
    ) -> BoardCamera {
        camera.recenter(over: board.placementList.map(\.coord), in: rect.insetBy(dx: margin, dy: margin))
    }

    // MARK: - The one free-cell search

    /// Lays `tiles` onto `board` in reading order from `start`, `across`
    /// lattice columns wide, wrapping down a row at a time and never stopping
    /// until every tile is down.
    ///
    /// The ONE place either arrival decides a cell is usable, so the
    /// non-adjacency rule and the occupancy rule each have exactly one
    /// implementation. A cell that is taken, or that touches a taken one, is
    /// skipped rather than written over — and the tile index only advances on
    /// a landing that actually happened, so nothing is silently lost.
    private static func laid(
        _ tiles: [Tile],
        on board: Board,
        from start: Coord,
        across columns: Int
    ) -> Board {
        var board = board
        var index = 0
        var row = start.row
        let width = max(1, columns)

        while index < tiles.count {
            for column in 0..<width where index < tiles.count {
                let coord = Coord(row: row, col: start.col + column * step)
                guard isVacant(coord, on: board),
                      // Void? rather than a bare `try?`: the guard above already
                      // rules `occupied` out, and this makes that structural —
                      // a throw skips the cell instead of escaping or eating a
                      // tile.
                      (try? board.place(tiles[index], at: coord)) != nil
                else { continue }
                index += 1
            }
            // Down a whole lattice row. The board is unbounded below, so the
            // rows eventually run past everything on it and this terminates
            // however crowded the start was.
            row += step
        }
        return board
    }

    /// Free, and with all four edge neighbours free. Both halves are the
    /// guardrail: the first stops an overwrite, the second stops a run of
    /// random letters forming.
    private static func isVacant(_ coord: Coord, on board: Board) -> Bool {
        board.tile(at: coord) == nil && coord.neighbors.allSatisfy { board.tile(at: $0) == nil }
    }

    /// Lattice columns wide enough to hold `count` tiles in `openingRows` rows.
    private static func openingWidth(for count: Int) -> Int {
        max(1, Int((Double(count) / Double(openingRows)).rounded(.up)))
    }
}
