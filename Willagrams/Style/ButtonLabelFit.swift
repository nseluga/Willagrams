import SwiftUI

/// How a button label is allowed to occupy its button.
///
/// Plain values and plain functions — no `View` — so StyleTests can run the
/// real decision at a real width rather than reading it off the source. The
/// three button styles in `ButtonStyles.swift` are its only callers; no call
/// site spells `lineLimit` or `minimumScaleFactor` for itself.
///
/// The bug this exists for: the styles chose the compact font off
/// `verticalSizeClass == .compact`, which is *landscape* phone. A portrait
/// phone is `horizontalSizeClass == .compact` with a regular vertical class,
/// so it got the full 20pt face plus 24pt of padding per side and "Copy" came
/// out of a shared row as `Cop` / `y`.
public enum ButtonLabelFit {

    /// One line, always. A button that wraps is a button whose row was too
    /// narrow — shrinking the word is the honest answer, growing the card is not.
    public static let lineLimit = 1

    /// How far the label may shrink before it stops shrinking.
    ///
    /// 0.8 of the compact 15pt face is 12pt, which is still read at arm's
    /// length. Lower would stop more rows overflowing, but a friend code or a
    /// verb the player has to act on is not worth reading at 9pt — a row that
    /// still does not fit at this floor needs fewer buttons, not smaller ones.
    public static let minimumScaleFactor: CGFloat = 0.8

    /// True on a phone in either orientation: landscape is a compact vertical
    /// class, portrait is a compact horizontal one. An iPad is neither.
    ///
    /// A nil size class counts as not compact, matching `ScreenMargin.value`.
    public static func isCompact(
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?
    ) -> Bool {
        vertical == .compact || horizontal == .compact
    }

    public static func font(
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?
    ) -> Font {
        isCompact(horizontal: horizontal, vertical: vertical)
            ? DesignTokens.Typography.buttonCompact
            : DesignTokens.Typography.button
    }

    /// The point size `font(...)` resolves to. Kept here as a number because a
    /// `Font` will not tell you its size, and a width cannot be computed
    /// without one. `ButtonLabelFitTests` pins both against `DesignTokens`.
    public static let pointSize: CGFloat = 20
    public static let compactPointSize: CGFloat = 15

    public static func pointSize(
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?
    ) -> CGFloat {
        isCompact(horizontal: horizontal, vertical: vertical) ? compactPointSize : pointSize
    }

    /// Padding per side on the two chrome'd styles.
    public static func horizontalPadding(
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?
    ) -> CGFloat {
        isCompact(horizontal: horizontal, vertical: vertical)
            ? DesignTokens.Space.m
            : DesignTokens.Space.l
    }

    /// The narrowest a button can be drawn: the label shrunk to the floor, plus
    /// padding, which does not shrink. `labelWidth` is measured by the caller
    /// against the real face at `pointSize(...)` — the measurement is injected
    /// so the app does not carry a text-measuring pass it never runs.
    public static func minimumButtonWidth(
        labelWidth: CGFloat,
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?
    ) -> CGFloat {
        labelWidth * minimumScaleFactor
            + 2 * horizontalPadding(horizontal: horizontal, vertical: vertical)
    }
}
