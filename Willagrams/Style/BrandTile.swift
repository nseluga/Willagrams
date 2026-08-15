import SwiftUI

/// A letter tile — face, bevel, ring and lift.
///
/// **On the bevel.** The direction specifies `inset 0 -3px 0`, and SwiftUI has
/// no inner shadow. Two implementations were measured by rendering both at
/// 20 / 28 / 36 / 56pt and reading the band back out of the bitmap:
///
/// | | 20pt | 28pt | 36pt | 56pt | top edge |
/// |---|---|---|---|---|---|
/// | bottom-aligned band, clipped | 3.00pt | 3.00pt | 3.00pt | 3.00pt | hard |
/// | overlaid rounded shape, gradient | 2.67pt | 3.67pt | 4.67pt | 7.33pt | softens |
///
/// The gradient's stops are proportional, so the band scales with the tile and
/// its edge blurs out as tiles grow — at rack size it reads as a vignette, not
/// a bevel, and at board size it is thin. The clipped band holds the specified
/// 3pt at every size because the height is absolute and the rounded-rect clip
/// carries the bottom corners for free, which is exactly what a zero-blur inset
/// shadow does. The band ships.
public struct BrandTile: View {

    /// How a tile is sitting: loose on the rack, seated in a cell, or picked up.
    public enum State: Equatable, Sendable {
        /// Loose — resting on the surface, casting a small drop shadow.
        case idle
        /// Seated in a board cell. Flush, so it drops no shadow of its own.
        case placed
        /// Picked up — ringed and lifted.
        case selected
    }

    public let letter: Character
    public let size: CGFloat
    public let state: State

    public init(letter: Character, size: CGFloat, state: State = .idle) {
        self.letter = letter
        self.size = size
        self.state = state
    }

    public var body: some View {
        Text(String(letter))
            .font(DesignTokens.Typography.tileLetter)
            .foregroundStyle(DesignTokens.Palette.tileLetter)
            .minimumScaleFactor(Self.letterScaleFloor)
            .lineLimit(1)
            .frame(width: size, height: size)
            .background(face)
            .overlay(ring)
            .brandShadow(shadow)
            .offset(y: state == .selected ? DesignTokens.Motion.tileLift : 0)
            .animation(DesignTokens.Motion.snap, value: state)
    }

    /// Face plus the bottom bevel band, both inside one clip.
    private var face: some View {
        DesignTokens.Palette.tileFace
            .overlay(alignment: .bottom) {
                DesignTokens.Palette.tileEdge
                    .frame(height: DesignTokens.Stroke.bevel)
            }
            .clipShape(shape)
    }

    @ViewBuilder
    private var ring: some View {
        if state == .selected {
            shape.strokeBorder(
                DesignTokens.Palette.accent,
                lineWidth: DesignTokens.Stroke.selectedRing
            )
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.tile, style: .continuous)
    }

    private var shadow: DesignTokens.Shadow.Recipe {
        switch state {
        case .idle: DesignTokens.Shadow.tile
        case .placed: DesignTokens.Shadow.flush
        case .selected: DesignTokens.Shadow.selected
        }
    }

    /// The letter token is sized for a rack tile; smaller tiles shrink it
    /// rather than clipping it.
    private static let letterScaleFloor: CGFloat = 0.4
}
