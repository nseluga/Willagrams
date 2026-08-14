// Frozen contracts. Every lane builds against these shapes.
// Changing anything in this file is an amendment — see FOUNDATION.md.

import Foundation

/// A cell on the tile lattice. Signed and unbounded: the table has no edges.
///
/// The board view drags tiles in continuous space and snaps on release, so
/// players never see this grid. It exists so "which letters form a word" has
/// an exact answer instead of a tolerance.
public struct Coord: Hashable, Codable, Sendable {
    public let row: Int
    public let col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    /// The four edge-adjacent neighbours. Diagonals never connect tiles.
    public var neighbors: [Coord] {
        [
            Coord(row: row - 1, col: col),
            Coord(row: row + 1, col: col),
            Coord(row: row, col: col - 1),
            Coord(row: row, col: col + 1),
        ]
    }
}

/// One lettered tile. Identity is stable across a move, so the board view can
/// animate a tile rather than swapping one out for another.
public struct Tile: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    /// Uppercase A–Z.
    public let letter: Character

    public init(id: UUID = UUID(), letter: Character) {
        self.id = id
        self.letter = letter
    }

    // Character is not Codable, so the wire form is a one-character string.
    // Decoding is a trust boundary: a peer can send anything.
    private enum CodingKeys: String, CodingKey { case id, letter }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let raw = try container.decode(String.self, forKey: .letter)
        guard raw.count == 1, let character = raw.first else {
            throw DecodingError.dataCorruptedError(
                forKey: .letter,
                in: container,
                debugDescription: "letter must be exactly one character, got \"\(raw)\""
            )
        }
        letter = character
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(String(letter), forKey: .letter)
    }
}

/// A tile bound to a cell. The wire form of a placed tile.
/// One tile at one square — the wire form of a board.
///
/// Carries the whole `Tile` rather than its id, so a board can be drawn from
/// placements alone. Sending ids beside a separate tile array meant the
/// receiver had to join the two, and nothing stopped them disagreeing.
public struct Placement: Hashable, Codable, Sendable {
    public let tile: Tile
    public let coord: Coord

    public var tileID: UUID { tile.id }

    public init(tile: Tile, coord: Coord) {
        self.tile = tile
        self.coord = coord
    }
}

/// A player, keyed by `GKPlayer.gamePlayerID`.
public struct PlayerID: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum Direction: Codable, Sendable, Equatable {
    case across
    case down
}

/// A maximal run of two or more tiles in one direction.
public struct BoardWord: Hashable, Sendable {
    public let text: String
    public let origin: Coord
    public let direction: Direction

    public init(text: String, origin: Coord, direction: Direction) {
        self.text = text
        self.origin = origin
        self.direction = direction
    }
}

public enum PlacementError: Error, Equatable, Sendable {
    case occupied(Coord)
    case tileNotInHand(UUID)
}

/// One player's private table of placed tiles.
///
/// Sparse and unbounded — only occupied cells are stored. Tiles may sit in
/// several disconnected clusters; that is legal scratch space, and it is the
/// `Draw` gate in `BoardValidation`, not `place`, that requires exactly one.
public struct Board: Codable, Sendable, Equatable {
    public private(set) var placements: [Coord: Tile]

    public init(placements: [Coord: Tile] = [:]) {
        self.placements = placements
    }

    public func tile(at coord: Coord) -> Tile? {
        placements[coord]
    }

    /// - Throws: `PlacementError.occupied` if the cell is taken. The board is
    ///   left unchanged in that case.
    public mutating func place(_ tile: Tile, at coord: Coord) throws {
        guard placements[coord] == nil else {
            throw PlacementError.occupied(coord)
        }
        placements[coord] = tile
    }

    @discardableResult
    public mutating func remove(at coord: Coord) -> Tile? {
        placements.removeValue(forKey: coord)
    }

    /// The board as a sendable list, in a fixed order.
    ///
    /// Dictionary iteration order is not stable between runs, so sending one
    /// unsorted would make two encodings of the same board differ. Sorted here
    /// once rather than in each lane that needs it.
    public var placementList: [Placement] {
        placements
            .map { Placement(tile: $0.value, coord: $0.key) }
            .sorted { ($0.coord.row, $0.coord.col) < ($1.coord.row, $1.coord.col) }
    }
}
