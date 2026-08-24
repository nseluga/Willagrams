//
//  WordmarkView.swift
//  Willagrams
//
//  Draws `Wordmark`. Every coordinate comes from there; this file holds no
//  branch and no layout arithmetic beyond fitting the grid to the space given.
//
//  This file imports SwiftUI, so it is listed in the `Shell` target's
//  `exclude:` in `Tests/ShellTests/Package.swift`.
//

import SwiftUI

struct WordmarkView: View {

    /// How wide one tile is. The caller sizes the mark by sizing its tile, so
    /// the same view is a menu wordmark and a small badge.
    let tileSize: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A clear cell of the full grid, so the ZStack takes the mark's
            // whole size rather than the bounding box of the tiles that happen
            // to be laid.
            Color.clear
                .frame(
                    width: CGFloat(Wordmark.columns) * step,
                    height: CGFloat(Wordmark.rows) * step
                )

            ForEach(Wordmark.tiles) { tile in
                BrandTile(letter: tile.letter, size: tileSize, state: .placed)
                    .offset(x: CGFloat(tile.column) * step, y: CGFloat(tile.row) * step)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Wordmark.spelled)
        .accessibilityAddTraits(.isHeader)
    }

    /// Tile plus the seam between tiles, which is what the reference art shows
    /// — laid tiles that touch but do not merge.
    private var step: CGFloat { tileSize + tileSize * Self.seam }

    private static let seam: CGFloat = 0.06
}
