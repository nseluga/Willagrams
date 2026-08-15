import SwiftUI

/// The three controls, loudest to quietest.
///
/// Each has a pressed state you can see without a side-by-side: primary drops
/// its shadow and sinks by the bevel height, quiet darkens its fill to the
/// hairline tint, and text goes to the pressed accent. A pressed state that
/// only changes opacity is the one players stop noticing.
public struct PrimaryButtonStyle: ButtonStyle {

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignTokens.Typography.button)
            .foregroundStyle(DesignTokens.Palette.onInk)
            .padding(.horizontal, DesignTokens.Space.l)
            .padding(.vertical, DesignTokens.Space.s)
            .background(DesignTokens.Palette.ink, in: shape)
            .brandShadow(configuration.isPressed ? DesignTokens.Shadow.flush : DesignTokens.Shadow.button)
            .offset(y: configuration.isPressed ? DesignTokens.Stroke.bevel : 0)
            .animation(DesignTokens.Motion.snap, value: configuration.isPressed)
    }
}

/// The secondary control: a recessed panel rather than a filled one.
public struct QuietButtonStyle: ButtonStyle {

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignTokens.Typography.button)
            .foregroundStyle(DesignTokens.Palette.ink)
            .padding(.horizontal, DesignTokens.Space.l)
            .padding(.vertical, DesignTokens.Space.s)
            .background(
                configuration.isPressed ? DesignTokens.Palette.hairline : DesignTokens.Palette.cellEmpty,
                in: shape
            )
            .overlay {
                shape.strokeBorder(
                    DesignTokens.Palette.hairline,
                    lineWidth: DesignTokens.Stroke.hairline
                )
            }
            .animation(DesignTokens.Motion.snap, value: configuration.isPressed)
    }
}

/// The quietest control: a word, no chrome.
public struct TextButtonStyle: ButtonStyle {

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignTokens.Typography.button)
            .foregroundStyle(
                configuration.isPressed ? DesignTokens.Palette.accentPressed : DesignTokens.Palette.accent
            )
            .padding(.horizontal, DesignTokens.Space.s)
            .padding(.vertical, DesignTokens.Space.xs)
            .animation(DesignTokens.Motion.snap, value: configuration.isPressed)
    }
}

private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
}

public extension ButtonStyle where Self == PrimaryButtonStyle {
    static var brandPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

public extension ButtonStyle where Self == QuietButtonStyle {
    static var brandQuiet: QuietButtonStyle { QuietButtonStyle() }
}

public extension ButtonStyle where Self == TextButtonStyle {
    static var brandText: TextButtonStyle { TextButtonStyle() }
}
