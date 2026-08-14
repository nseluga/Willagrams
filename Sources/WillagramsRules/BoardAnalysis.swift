import Foundation

/// The result of checking a board. Structured rather than a bool, because the
/// UI has to tell the player *why* Draw is refused.
public struct BoardValidation: Equatable, Sendable {
    /// Connected groups of tiles. Loose scratch tiles each count as their own.
    public let clusterCount: Int
    /// Runs of two or more tiles that are not in the word list.
    public let invalidWords: [BoardWord]
    /// Tiles on the board.
    public let tileCount: Int

    public init(clusterCount: Int, invalidWords: [BoardWord], tileCount: Int) {
        self.clusterCount = clusterCount
        self.invalidWords = invalidWords
        self.tileCount = tileCount
    }

    /// The Draw gate: one cluster, every word real, and an actual crossword.
    ///
    /// The `tileCount` floor is not redundant. A board holding a single tile
    /// is one cluster with no invalid words, but a lone tile spells nothing —
    /// it is not a grid, and it must not let a player Draw or win. Any cluster
    /// of two or more tiles necessarily forms at least one run, so two is the
    /// only floor needed. An empty board fails on `clusterCount` alone.
    public var isComplete: Bool {
        clusterCount == 1 && invalidWords.isEmpty && tileCount >= 2
    }
}

extension Board {

    /// Connected components over edge adjacency. Diagonal touching does not join.
    public var clusters: [Set<Coord>] {
        var unvisited = Set(placements.keys)
        var found: [Set<Coord>] = []

        while let seed = unvisited.first {
            var cluster: Set<Coord> = []
            var frontier = [seed]
            unvisited.remove(seed)

            while let coord = frontier.popLast() {
                cluster.insert(coord)
                for neighbor in coord.neighbors where unvisited.contains(neighbor) {
                    unvisited.remove(neighbor)
                    frontier.append(neighbor)
                }
            }
            found.append(cluster)
        }
        return found
    }

    /// Every maximal run of two or more tiles, across and down.
    ///
    /// A lone tile spells nothing. Sorted by origin so the order is stable
    /// across runs — dictionaries are unordered, and the UI lists these.
    public func words() -> [BoardWord] {
        var found: [BoardWord] = []

        for (coord, _) in placements {
            for direction in [Direction.across, Direction.down] {
                let back = direction == .across
                    ? Coord(row: coord.row, col: coord.col - 1)
                    : Coord(row: coord.row - 1, col: coord.col)
                // Only start a run at its first tile.
                guard placements[back] == nil else { continue }

                var letters = ""
                var cursor = coord
                while let tile = placements[cursor] {
                    letters.append(tile.letter)
                    cursor = direction == .across
                        ? Coord(row: cursor.row, col: cursor.col + 1)
                        : Coord(row: cursor.row + 1, col: cursor.col)
                }
                if letters.count >= 2 {
                    found.append(BoardWord(text: letters, origin: coord, direction: direction))
                }
            }
        }

        return found.sorted {
            ($0.origin.row, $0.origin.col, $0.direction == .across ? 0 : 1)
                < ($1.origin.row, $1.origin.col, $1.direction == .across ? 0 : 1)
        }
    }

    /// Checks the board against a word list.
    public func validate(against dictionary: some WordList) -> BoardValidation {
        BoardValidation(
            clusterCount: clusters.count,
            invalidWords: words().filter { !dictionary.contains($0.text) },
            tileCount: placements.count
        )
    }
}
