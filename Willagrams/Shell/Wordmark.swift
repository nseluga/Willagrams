//
//  Wordmark.swift
//  Willagrams
//
//  The app's name, as a crossword rather than a line of type: WILLA across,
//  GRAMS down, crossing on the A they share.
//
//  NO SwiftUI here — see the note in AppRoute.swift. The layout is the part
//  that can be wrong, so it lives here as plain values a test can read;
//  `WordmarkView` draws them and computes nothing.
//
//  This file must never import GameKit.
//

import Foundation

/// The wordmark's grid: which letter sits in which cell.
///
/// Coordinates, not a picture. A view that hard-coded the crossing would be the
/// only thing that knew where it was, and nothing could check that the two
/// words still spell the app's name.
public enum Wordmark {

    /// One tile of the mark.
    public struct Tile: Hashable, Sendable, Identifiable {
        public let letter: Character
        public let column: Int
        public let row: Int

        /// The cell it occupies. Two tiles cannot share one, which is what
        /// makes the crossing a single tile rather than two stacked.
        public var id: String { "\(column),\(row)" }

        public init(letter: Character, column: Int, row: Int) {
            self.letter = letter
            self.column = column
            self.row = row
        }
    }

    public static let across = "WILLA"
    public static let down = "GRAMS"

    /// Where the two words meet: the last cell of ``across`` and the middle of
    /// ``down``. Both are derived, so shortening either word moves the crossing
    /// with it instead of leaving it behind.
    public static let crossingColumn = across.count - 1
    public static let crossingRow = down.count / 2

    public static let columns = across.count
    public static let rows = down.count

    /// Every tile, once. The crossing letter belongs to `down` and is skipped
    /// on the way across, so it is laid one time and reads in both directions.
    public static let tiles: [Tile] = {
        var tiles = across.enumerated().compactMap { index, letter -> Tile? in
            index == crossingColumn ? nil : Tile(letter: letter, column: index, row: crossingRow)
        }
        tiles += down.enumerated().map { index, letter in
            Tile(letter: letter, column: crossingColumn, row: index)
        }
        return tiles
    }()

    /// What the mark says, read across and then down. The crossing letter is
    /// read twice — once as the end of one word and once inside the other —
    /// which is the whole trick of the layout.
    public static var spelled: String { across + down }
}
