import Foundation
import Testing
@testable import WillagramsRules

@Suite("Board analysis")
struct BoardAnalysisTests {

    /// Builds a board from an ASCII sketch. `.` is empty; row 0 is the top line.
    static func board(_ rows: [String]) throws -> Board {
        var board = Board()
        for (r, row) in rows.enumerated() {
            for (c, character) in row.enumerated() where character != "." {
                try board.place(Tile(letter: character), at: Coord(row: r, col: c))
            }
        }
        return board
    }

    static let dictionary = EnableWordList(words: ["cat", "cot", "at", "ot", "to"])

    @Test("CAT across and COT down sharing the C is one cluster of two valid words")
    func crossedWordsValidate() throws {
        let board = try Self.board([
            "CAT",
            "O..",
            "T..",
        ])

        let words = board.words()
        #expect(words.count == 2)
        #expect(Set(words.map(\.text)) == ["CAT", "COT"])

        let result = board.validate(against: Self.dictionary)
        #expect(result.clusterCount == 1)
        #expect(result.invalidWords.isEmpty)
        #expect(result.isComplete)
    }

    @Test("A detached tile is a second cluster and blocks Draw")
    func detachedTileBlocksDraw() throws {
        let board = try Self.board([
            "CAT...",
            "......",
            "....Z.",
        ])

        let result = board.validate(against: Self.dictionary)
        #expect(result.clusterCount == 2)
        #expect(!result.isComplete)
        // The loose Z spells nothing on its own.
        #expect(result.invalidWords.isEmpty)
    }

    @Test("A single tile spells no word")
    func loneTileSpellsNothing() throws {
        let board = try Self.board(["Q"])

        #expect(board.words().isEmpty)
        #expect(board.clusters.count == 1)
        #expect(!board.validate(against: Self.dictionary).isComplete)
    }

    @Test("An unknown run is reported as invalid, with its origin and direction")
    func unknownWordIsReported() throws {
        let board = try Self.board([
            "XQ",
        ])

        let result = board.validate(against: Self.dictionary)
        #expect(result.clusterCount == 1)
        #expect(result.invalidWords.count == 1)
        #expect(result.invalidWords[0].text == "XQ")
        #expect(result.invalidWords[0].origin == Coord(row: 0, col: 0))
        #expect(result.invalidWords[0].direction == .across)
        #expect(!result.isComplete)
    }

    @Test("Diagonal contact does not join two clusters")
    func diagonalsDoNotConnect() throws {
        let board = try Self.board([
            "AT.",
            "..T",
            "..O",
        ])

        #expect(board.clusters.count == 2)
    }

    @Test("An empty board is not complete")
    func emptyBoardIsNotComplete() {
        let result = Board().validate(against: Self.dictionary)

        #expect(result.clusterCount == 0)
        #expect(!result.isComplete)
    }

    @Test("Word order is stable across runs")
    func wordOrderIsStable() throws {
        let board = try Self.board([
            "CAT",
            "O..",
            "T..",
        ])

        let first = board.words().map(\.text)
        for _ in 0..<20 {
            #expect(board.words().map(\.text) == first)
        }
    }

    @Test("Runs are found at negative coordinates too")
    func negativeCoordinatesWork() throws {
        var board = Board()
        try board.place(Tile(letter: "T"), at: Coord(row: -3, col: -9))
        try board.place(Tile(letter: "O"), at: Coord(row: -3, col: -8))

        let words = board.words()
        #expect(words.count == 1)
        #expect(words[0].text == "TO")
        #expect(words[0].origin == Coord(row: -3, col: -9))
    }
}
