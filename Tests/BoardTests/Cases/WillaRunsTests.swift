import XCTest
import WillagramsRules

final class WillaRunsTests: XCTestCase {

    private let dictionary = EnableWordList(words: [])

    private func board(_ word: String, down: Bool) throws -> Board {
        var board = Board()
        for (i, letter) in word.enumerated() {
            try board.place(Tile(letter: letter), at: down ? Coord(row: i, col: 3) : Coord(row: 2, col: i))
        }
        return board
    }

    func testWillaRunsAreExactlyTheFiveCoordsAcrossAndDown() throws {
        for down in [false, true] {
            let model = BoardModel(board: try board("WILLA", down: down), against: dictionary)
            let expected = Set((0..<5).map { down ? Coord(row: $0, col: 3) : Coord(row: 2, col: $0) })
            XCTAssertEqual(model.willaRuns, [expected], down ? "down" : "across")
        }
        XCTAssertEqual(BoardModel(board: try board("WILAL", down: false), against: dictionary).willaRuns, [])
        XCTAssertEqual(BoardModel(board: try board("WILLAS", down: true), against: dictionary).willaRuns, [])
    }

    func testSparkleCountsOncePerNewRun() throws {
        var model = BoardModel()
        let willa = try board("WILLA", down: false)
        model.seed(Board(), against: dictionary)
        XCTAssertEqual(model.willaSparkles, 0)
        model.seed(willa, against: dictionary)
        XCTAssertEqual(model.willaSparkles, 1)
        // The same board again, and an unrelated tile landing: no replay.
        model.seed(willa, against: dictionary)
        var moved = willa
        try moved.place(Tile(letter: "X"), at: Coord(row: 9, col: 9))
        model.seed(moved, against: dictionary)
        XCTAssertEqual(model.willaSparkles, 1)
    }
}
