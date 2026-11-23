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

    /// Tiles delivered by a Draw. A tile lands where the player can see it:
    /// on a free cell drawn whole inside `rect` minus `insets` (the chrome),
    /// for as long as one exists. Among those, the cells nearest the player's
    /// largest connected cluster win: directly below it first, then beside
    /// it, then outward. Only a view with no free cell left sends a tile out
    /// of sight.
    ///
    /// A board with no cluster of two or more tiles — empty, or the loose
    /// opening deal — orders the same cells by ``viewportDelivered``.
    /// Never overwrites, never refuses, never throws.
    public static func delivered(
        _ tiles: [Tile],
        onto board: Board,
        camera: BoardCamera,
        in rect: CGRect,
        insets: BoardInsets = .zero
    ) -> Board {
        guard !tiles.isEmpty else { return board }
        // Every cell drawn whole inside the clear rect, in reading order. None
        // for a frame with no area left (a `GeometryReader`'s zero-size first
        // pass, or chrome wider than the frame).
        let clear = insets.inset(rect)
        let size = camera.cellSize
        let seen = clear.width > 0 && clear.height > 0
            ? camera.visibleCoords(in: clear).filter {
                clear.contains(CGRect(origin: camera.point(for: $0), size: CGSize(width: size, height: size)))
            }
            : []
        guard let cluster = largestCluster(on: board), cluster.count > 1 else {
            return viewportDelivered(tiles, onto: board, seen: seen)
        }

        let minRow = cluster.map(\.row).min()!, maxRow = cluster.map(\.row).max()!
        let minCol = cluster.map(\.col).min()!, maxCol = cluster.map(\.col).max()!
        // Rows and columns off the bounding box, 0 inside its span.
        func rowGap(_ c: Coord) -> Int { c.row > maxRow ? c.row - maxRow : max(0, minRow - c.row) }
        func colGap(_ c: Coord) -> Int { c.col > maxCol ? c.col - maxCol : max(0, minCol - c.col) }
        // Below the box (0), beside it (1), anything else (2); then nearest,
        // then reading order — a total order, so the answer is deterministic.
        func rank(_ c: Coord) -> (Int, Int, Int, Int) {
            let tier = c.row > maxRow && colGap(c) == 0 ? 0 : (rowGap(c) == 0 ? 1 : 2)
            return (tier, rowGap(c) + colGap(c), c.row, c.col)
        }

        let inView = Set(seen)
        // ponytail: a fixed ring of `step * (count + 1)` cells round the box
        // is searched, O(box area) per delivery — the fallback below still
        // places anything it could not. Widen when deliveries grow past a few.
        let reach = step * (tiles.count + 1)
        var candidates: [Coord] = []
        for row in (minRow - reach)...(maxRow + reach) {
            for col in (minCol - reach)...(maxCol + reach) { candidates.append(Coord(row: row, col: col)) }
        }
        candidates.sort { rank($0) < rank($1) }
        // Cells the player can see first: the ring's, then every other cell in
        // view (nearest the cluster first, which is the edge of the screen it
        // lies beyond when the camera has panned away). The ring's hidden
        // cells come last. Each part keeps its below/beside/outward order.
        candidates = candidates.filter(inView.contains)
            + seen.sorted { rank($0) < rank($1) }
            + candidates.filter { !inView.contains($0) }

        var next = board
        let rest = settle(tiles, on: &next, trying: candidates)
        guard !rest.isEmpty else { return next }
        // Every nearby cell was blocked: carry on down from under the box,
        // where the board is unbounded and so always has another free row.
        return laid(
            rest, on: next,
            from: Coord(row: maxRow + reach + step, col: minCol),
            across: (maxCol - minCol) / step + 1
        )
    }

    /// The largest connected group of tiles (edge neighbours), ties going to
    /// the group whose topmost-leftmost tile comes first in reading order.
    /// Nil on an empty board.
    static func largestCluster(on board: Board) -> [Coord]? {
        var unseen = Set(board.placementList.map(\.coord))
        var best: [Coord]?
        func first(_ group: [Coord]) -> Coord { group.min { ($0.row, $0.col) < ($1.row, $1.col) }! }
        while let seed = unseen.first {
            var group: [Coord] = []
            var frontier = [seed]
            unseen.remove(seed)
            while let coord = frontier.popLast() {
                group.append(coord)
                for n in coord.neighbors where unseen.remove(n) != nil { frontier.append(n) }
            }
            if let current = best {
                let a = first(group), b = first(current)
                if group.count > current.count
                    || (group.count == current.count && (a.row, a.col) < (b.row, b.col)) { best = group }
            } else {
                best = group
            }
        }
        return best
    }

    /// The rule for a board with no cluster yet: free cells below whatever is
    /// currently on screen, so the player sees them without moving the camera.
    ///
    /// `seen` is every cell in view. The lattice rows under the lowest tile in
    /// view go first, then any other cell in view, and the rows below the view
    /// only once those are used up. The board is unbounded downward, so there
    /// is always another free row.
    static func viewportDelivered(_ tiles: [Tile], onto board: Board, seen: [Coord]) -> Board {
        // Nothing in view (see `delivered`) leaves no cells to prefer. Falling
        // back to the row below the whole board still places every tile rather
        // than dropping the delivery on the floor.
        guard let firstCol = seen.map(\.col).min(),
              let lastCol = seen.map(\.col).max(),
              let top = seen.map(\.row).min(),
              let bottom = seen.map(\.row).max()
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

        var lattice: [Coord] = []
        for row in stride(from: start, through: bottom, by: step) {
            for col in stride(from: firstCol, through: lastCol, by: step) { lattice.append(Coord(row: row, col: col)) }
        }
        var next = board
        let rest = settle(tiles, on: &next, trying: lattice + seen)
        return laid(rest, on: next, from: Coord(row: start, col: firstCol), across: (lastCol - firstCol) / step + 1)
    }

    // MARK: - Framing

    /// `camera` framing every tile on `board` inside `rect` minus `insets` (the
    /// chrome drawn over the board), with `margin` points of clear viewport
    /// around the block. Never zooms in past the camera's default cell size.
    ///
    /// The framing itself is `BoardCamera.recenter` — this only hands it an
    /// inset rect, so there is no second implementation of fitting content to
    /// a viewport and no second copy of the cell-size clamp.
    public static func framing(
        _ board: Board,
        in rect: CGRect,
        camera: BoardCamera,
        margin: CGFloat = openingMargin,
        insets: BoardInsets = .zero
    ) -> BoardCamera {
        camera.recenter(
            over: board.placementList.map(\.coord),
            in: insets.inset(rect).insetBy(dx: margin, dy: margin),
            ceiling: camera.baseCellSize
        )
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

    /// Lands each tile on the first cell of `cells` that is still vacant, in
    /// order, and returns the tiles no cell was left for.
    private static func settle(_ tiles: [Tile], on board: inout Board, trying cells: [Coord]) -> [Tile] {
        var index = 0
        for coord in cells where index < tiles.count {
            guard isVacant(coord, on: board), (try? board.place(tiles[index], at: coord)) != nil else { continue }
            index += 1
        }
        return Array(tiles[index...])
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

/// Points of the viewport covered by chrome on each edge. SwiftUI-free
/// stand-in for `EdgeInsets`, so framing stays host-testable.
public struct BoardInsets: Equatable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static let zero = BoardInsets()

    /// `rect` with these edges taken off (left-to-right layout).
    public func inset(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + leading,
            y: rect.minY + top,
            width: rect.width - leading - trailing,
            height: rect.height - top - bottom
        )
    }
}
