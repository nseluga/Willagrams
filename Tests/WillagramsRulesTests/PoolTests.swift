import Foundation
import Testing
@testable import WillagramsRules

@Suite("Pool and game state")
struct PoolTests {

    @Test("The distribution is exactly 144 tiles over A-Z")
    func distributionTotals144() {
        #expect(LetterDistribution.totalTiles == 144)
        #expect(LetterDistribution.standard.count == 26)
        #expect(LetterDistribution.standard.keys.allSatisfy { $0.isUppercase && $0.isASCII })
        #expect(LetterDistribution.standard.values.allSatisfy { $0 >= 2 })
    }

    @Test("The same seed produces the same shuffle")
    func seedIsDeterministic() {
        let a = Pool.standard(seed: 42)
        let b = Pool.standard(seed: 42)
        let different = Pool.standard(seed: 43)

        #expect(a.tiles.map(\.letter) == b.tiles.map(\.letter))
        #expect(a.tiles.map(\.letter) != different.tiles.map(\.letter))
        #expect(a.count == 144)
    }

    @Test("Draw hands out tiles and refuses to overdraw")
    func drawRespectsRemaining() {
        var pool = Pool.standard(seed: 7)

        #expect(pool.draw(21)?.count == 21)
        #expect(pool.count == 123)
        #expect(pool.draw(200) == nil)
        #expect(pool.count == 123, "a refused draw must not disturb the pool")

        #expect(pool.draw(123)?.count == 123)
        #expect(pool.isEmpty)
        #expect(pool.draw(1) == nil)
    }

    @Test("Swap takes three, returns one, and never returns the tile given up")
    func swapNetsTwo() {
        var generator = SeededGenerator(seed: 1)
        var pool = Pool.standard(seed: 9)
        let before = pool.count
        let giving = Tile(letter: "Q")

        let received = pool.swap(giving, using: &generator)

        #expect(received?.count == 3)
        #expect(pool.count == before - 2)
        #expect(received?.contains { $0.id == giving.id } == false)
        #expect(pool.tiles.contains { $0.id == giving.id })
    }

    @Test("Swap is refused when fewer than three tiles remain")
    func swapRefusedNearEmpty() {
        var generator = SeededGenerator(seed: 1)
        var pool = Pool(tiles: [Tile(letter: "A"), Tile(letter: "B")])

        #expect(pool.swap(Tile(letter: "Z"), using: &generator) == nil)
        #expect(pool.count == 2, "a refused swap must not disturb the pool")
    }

    @Test("Draw is gated on an empty hand as well as a complete board")
    func drawGateRequiresEmptyHand() throws {
        let dictionary = EnableWordList(words: ["to"])
        var state = GameState(pool: Pool(tiles: []), hand: [Tile(letter: "T"), Tile(letter: "O"), Tile(letter: "X")])

        let t = state.hand[0], o = state.hand[1]
        try state.place(tileID: t.id, at: Coord(row: 0, col: 0))
        try state.place(tileID: o.id, at: Coord(row: 0, col: 1))

        #expect(state.board.validate(against: dictionary).isComplete)
        #expect(!state.canDraw(against: dictionary), "an unplaced tile still blocks Draw")

        state.recall(from: Coord(row: 0, col: 1))
        #expect(state.hand.count == 2)
    }

    @Test("Placing a tile that is not in hand throws")
    func placeUnknownTileThrows() {
        var state = GameState(pool: Pool(tiles: []))
        let stranger = UUID()

        #expect(throws: PlacementError.tileNotInHand(stranger)) {
            try state.place(tileID: stranger, at: Coord(row: 0, col: 0))
        }
    }

    @Test("Game state round-trips through JSON in every status")
    func gameStateRoundTrips() throws {
        let statuses: [MatchStatus] = [
            .countdown(secondsRemaining: 3),
            .playing,
            .finished(winner: PlayerID(rawValue: "G:12345")),
        ]

        for status in statuses {
            let state = GameState(pool: Pool.standard(seed: 5), hand: [Tile(letter: "A")], status: status)
            let decoded = try JSONDecoder().decode(GameState.self, from: JSONEncoder().encode(state))
            #expect(decoded == state)
        }
    }
}
