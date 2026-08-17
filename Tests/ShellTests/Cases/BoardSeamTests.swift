import CoreGraphics
import Testing
import WillagramsRules
import BoardKit

/// The seam `BoardView` now exposes, checked on the STATE TYPES rather than on
/// the view: `BoardView` takes `Binding<Board>` and `Binding<BoardModel>`, so
/// whatever the owner holds is what the surface draws from and what the owner
/// reads its HUD off. A `@State` copy could satisfy neither direction, and
/// SwiftUI itself is not reachable from this package — but the two things the
/// binding carries are, so they are what is pinned here.
@Suite("Board seam")
struct BoardSeamTests {

    /// Stands in for the shell: it holds both halves the way the owner will.
    private struct Owner {
        var board = Board()
        var model = BoardModel()
    }

    private static let camera = BoardCamera()
    private static let rect = CGRect(x: 0, y: 0, width: 480, height: 480)

    /// Tiles the owner deals AFTER the board was handed over reach the draw
    /// list. Under the old by-value `@State` init this was the impossible
    /// direction: the view read its starting board once and never again.
    @Test("Tiles delivered after construction reach the draw list")
    func dealtTilesRender() throws {
        var owner = Owner()
        let drawn = BoardRender.cells(board: owner.board, camera: Self.camera, in: Self.rect)
        #expect(drawn.allSatisfy { $0.tile == nil })

        for (offset, letter) in "WILL".enumerated() {
            try owner.board.place(Tile(letter: letter), at: Coord(row: 0, col: offset))
        }

        let letters = BoardRender
            .cells(board: owner.board, camera: Self.camera, in: Self.rect)
            .compactMap(\.tile?.letter)
        #expect(String(letters.sorted()) == "ILLW")
    }

    /// The other direction. The owner asks the model, and the model answers off
    /// the frozen validation — the shell never checks the board itself.
    @Test("The owner reads draw eligibility off the model, never recomputing it")
    func canDrawIsReadOffTheModel() throws {
        var owner = Owner()
        let dictionary = EnableWordList(words: ["WILL"])
        for (offset, letter) in "WILL".enumerated() {
            try owner.board.place(Tile(letter: letter), at: Coord(row: 0, col: offset))
        }

        // Nothing has been committed or seeded yet, so the model still holds the
        // bare answer about a board that already has tiles on it.
        #expect(owner.model.canDraw == false)

        owner.model.seed(owner.board, against: dictionary)
        #expect(owner.model.canDraw)

        // A board the list refuses is refused through the same one property.
        owner.model.seed(owner.board, against: EnableWordList(words: []))
        #expect(owner.model.canDraw == false)
        #expect(owner.model.invalidCoords.isEmpty == false)
    }

    /// A second cluster is not drawable either, and the owner learns that from
    /// the same read — no cluster counting shell-side.
    @Test("A scattered board is refused through the same read")
    func scatteredBoardIsNotDrawable() throws {
        var owner = Owner()
        for (offset, letter) in "WILL".enumerated() {
            try owner.board.place(Tile(letter: letter), at: Coord(row: 0, col: offset))
        }
        try owner.board.place(Tile(letter: "Z"), at: Coord(row: 4, col: 6))
        owner.model.seed(owner.board, against: EnableWordList(words: ["WILL"]))
        #expect(owner.model.canDraw == false)
    }
}
