import SwiftUI

/// The card surface: filled panel, hairline border, hard-offset shadow.
///
/// **How the light/dark swap happens without a branch.** The direction wants
/// the `4px 5px 0` offset shadow in light and a one-point lit top edge in
/// dark, because an offset shadow on a dark ground reads as nothing at all.
/// Both are applied unconditionally here and the *catalog* decides which one
/// is visible: `shadowCard` is transparent in the dark appearance and
/// `topHighlight` is transparent in the light one. That keeps the rule the
/// lane is held to — no Swift branches on `colorScheme` — and it keeps the two
/// treatments where a designer can retune them, next to the colors.
public struct BrandCard: ViewModifier {

    public init() {}

    public func body(content: Content) -> some View {
        content
            .background(DesignTokens.Palette.surface)
            .overlay(alignment: .top) {
                // Visible only in dark, where the offset shadow is not.
                DesignTokens.Palette.topHighlight
                    .frame(height: DesignTokens.Stroke.hairline)
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    DesignTokens.Palette.hairline,
                    lineWidth: DesignTokens.Stroke.hairline
                )
            }
            // Visible only in light, where the top highlight is not.
            .brandShadow(DesignTokens.Shadow.card)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
    }
}

public extension View {
    /// Renders the receiver as a card.
    func brandCard() -> some View { modifier(BrandCard()) }
}
