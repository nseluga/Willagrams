import SwiftUI

/// The Willagrams wordmark as a crossword: WILLA reads across the middle row,
/// GRAMS reads down the right column, and the two words share the `A` at the
/// crossing. The shared tile is the accent tile — it is the whole point of the
/// mark, so it is not optional.
///
/// The grid is 5x5 with the empty squares left blank rather than drawn, so the
/// mark keeps the ragged silhouette of a real board corner.
public struct WordmarkTiles: View {

    /// Edge length of one tile. Everything else — gap, letter size — is derived
    /// from it, so a caller picks one number and the mark stays in proportion.
    private let cell: CGFloat

    public init(cell: CGFloat) {
        self.cell = cell
    }

    private var gap: CGFloat { (cell / 7).rounded() }
    private var letterSize: CGFloat { (cell * 0.57).rounded() }

    /// Row-major. `nil` is an empty square, not a blank tile.
    private static let grid: [[Character?]] = [
        [nil, nil, nil, nil, "G"],
        [nil, nil, nil, nil, "R"],
        ["W", "I", "L", "L", "A"],
        [nil, nil, nil, nil, "M"],
        [nil, nil, nil, nil, "S"],
    ]

    /// The crossing — row 2, column 4, zero-indexed.
    private static let crossing = (row: 2, column: 4)

    public var body: some View {
        VStack(spacing: gap) {
            ForEach(Array(Self.grid.enumerated()), id: \.offset) { row, letters in
                HStack(spacing: gap) {
                    ForEach(Array(letters.enumerated()), id: \.offset) { column, letter in
                        square(letter, row: row, column: column)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Willagrams"))
    }

    @ViewBuilder
    private func square(_ letter: Character?, row: Int, column: Int) -> some View {
        if let letter {
            WordmarkTile(
                letter: letter,
                size: cell,
                letterSize: letterSize,
                isCrossing: row == Self.crossing.row && column == Self.crossing.column
            )
        } else {
            Color.clear.frame(width: cell, height: cell)
        }
    }
}

/// One square of the wordmark.
///
/// This is deliberately *not* `BrandTile`. A `BrandTile` is a rack tile — it
/// carries placement state and a bevel that reads as liftable. A wordmark
/// square is a printed mark: flat, unliftable, and one of them is inverted into
/// the accent. Sharing the type would mean giving the game tile a state it can
/// never be in.
private struct WordmarkTile: View {

    let letter: Character
    let size: CGFloat
    let letterSize: CGFloat
    let isCrossing: Bool

    private var face: Color {
        isCrossing ? DesignTokens.Palette.accent : DesignTokens.Palette.tileFace
    }

    private var glyph: Color {
        isCrossing ? DesignTokens.Palette.onAccent : DesignTokens.Palette.tileLetter
    }

    var body: some View {
        Text(String(letter))
            .font(Font.brand(weight: .semibold, size: letterSize))
            .foregroundStyle(glyph)
            .frame(width: size, height: size)
            .background(face)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.tile, style: .continuous)
                    .strokeBorder(DesignTokens.Palette.hairline, lineWidth: DesignTokens.Stroke.hairline)
            )
            .brandShadow(DesignTokens.Shadow.tile)
    }
}
