//
//  WordmarkTests.swift
//  ShellTests
//
//  The mark is drawn by SwiftUI, which cannot be built on macOS. What can be
//  wrong about it is the grid, and the grid is plain values.
//

import Testing
@testable import Shell

@Suite("Wordmark")
struct WordmarkTests {

    @Test("The two words spell the app's name")
    func spellsTheName() {
        #expect(Wordmark.spelled == "WILLAGRAMS")
    }

    @Test("One tile per cell, and the crossing is a single tile")
    func oneTilePerCell() {
        #expect(Set(Wordmark.tiles.map(\.id)).count == Wordmark.tiles.count)
        // Five across plus five down, less the one they share.
        #expect(Wordmark.tiles.count == Wordmark.across.count + Wordmark.down.count - 1)
    }

    @Test("The crossing letter belongs to both words")
    func crossingReadsBothWays() {
        let crossing = Wordmark.tiles.first {
            $0.column == Wordmark.crossingColumn && $0.row == Wordmark.crossingRow
        }
        #expect(crossing?.letter == "A")
        #expect(Array(Wordmark.across).last == crossing?.letter)
        #expect(Array(Wordmark.down)[Wordmark.crossingRow] == crossing?.letter)
    }

    @Test("Each word reads in order along its own line")
    func wordsReadInOrder() {
        let across = Wordmark.tiles
            .filter { $0.row == Wordmark.crossingRow }
            .sorted { $0.column < $1.column }
        #expect(String(across.map(\.letter)) == Wordmark.across)

        let down = Wordmark.tiles
            .filter { $0.column == Wordmark.crossingColumn }
            .sorted { $0.row < $1.row }
        #expect(String(down.map(\.letter)) == Wordmark.down)
    }

    @Test("Every tile sits inside the grid the view sizes itself to")
    func tilesStayInsideTheGrid() {
        for tile in Wordmark.tiles {
            #expect((0..<Wordmark.columns).contains(tile.column))
            #expect((0..<Wordmark.rows).contains(tile.row))
        }
    }
}
