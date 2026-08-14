import Foundation
import Testing
@testable import WillagramsRules

@Suite("Placement contracts")
struct ContractsTests {
    @Test("A board round-trips through JSON, negative coords included")
    func boardRoundTrips() throws {
        var board = Board()
        try board.place(Tile(letter: "C"), at: Coord(row: 0, col: 0))
        try board.place(Tile(letter: "A"), at: Coord(row: 0, col: 1))
        try board.place(Tile(letter: "T"), at: Coord(row: -4, col: -7))

        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(Board.self, from: data)

        #expect(decoded == board)
        #expect(decoded.tile(at: Coord(row: -4, col: -7))?.letter == "T")
    }

    @Test("Placing into an occupied cell throws and leaves the board unchanged")
    func placeIntoOccupiedThrows() throws {
        let coord = Coord(row: 2, col: 3)
        var board = Board()
        let first = Tile(letter: "Q")
        try board.place(first, at: coord)

        #expect(throws: PlacementError.occupied(coord)) {
            try board.place(Tile(letter: "Z"), at: coord)
        }
        #expect(board.placements.count == 1)
        #expect(board.tile(at: coord)?.id == first.id)
    }

    @Test("remove returns the tile and empties the cell")
    func removeReturnsTile() throws {
        let coord = Coord(row: 1, col: 1)
        var board = Board()
        let tile = Tile(letter: "W")
        try board.place(tile, at: coord)

        #expect(board.remove(at: coord)?.id == tile.id)
        #expect(board.tile(at: coord) == nil)
        #expect(board.remove(at: coord) == nil)
    }

    @Test("A multi-character letter from the wire is rejected, not truncated")
    func malformedLetterIsRejected() throws {
        let json = Data(#"{"id":"\#(UUID().uuidString)","letter":"CAT"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Tile.self, from: json)
        }
    }

    @Test("Neighbours are the four edges, never diagonals")
    func neighborsAreEdgesOnly() {
        let center = Coord(row: 5, col: 5)
        let neighbors = Set(center.neighbors)

        #expect(neighbors.count == 4)
        #expect(neighbors.contains(Coord(row: 4, col: 5)))
        #expect(!neighbors.contains(Coord(row: 4, col: 4)))
    }
}
