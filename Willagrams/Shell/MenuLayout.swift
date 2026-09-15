import CoreGraphics

/// The Menu's sizing decisions, derived from the space SwiftUI measured for it.
///
/// A plain struct, not a View — no SwiftUI import — so `ShellTests` can
/// construct one directly and assert on its numbers without a simulator.
/// `MenuView` reads it for the wordmark height, the row spacing, and whether
/// the quiet (secondary) actions sit in a two-column grid.
///
/// This cannot import `Willagrams/Style`: `DesignTokens.swift` imports
/// SwiftUI, which does not build for the macOS target this struct is tested
/// from (see `Tests/ShellTests/StyleSrc`, which symlinks only
/// `Terminology.swift` for exactly that reason). The two spacing numbers
/// below are kept in sync by hand with `DesignTokens.Space.s` / `.m`.
public struct MenuLayout: Equatable {

    /// Below this height the menu is on a landscape phone, not an iPad —
    /// mirrors the `verticalSizeClass == .compact` switch the real view reads
    /// from the environment. This struct only ever sees a size, not the
    /// environment, so it approximates the same switch from the measurement
    /// SwiftUI already made.
    private static let compactHeightThreshold: CGFloat = 500

    private static let compactSpacing: CGFloat = 8
    private static let regularSpacing: CGFloat = 16

    /// The compact button's on-screen height: the label's 36pt floor plus
    /// `Typography.buttonCompact`'s vertical padding (`Space.xs`) on both
    /// edges.
    private static let compactButtonHeight: CGFloat = 44
    /// The regular button's height, same arithmetic with `Space.s`.
    private static let regularButtonHeight: CGFloat = 52

    /// True under a landscape phone's height, false on an iPad.
    public let isCompact: Bool
    /// Scales with the available height; capped so a tall iPad window
    /// doesn't blow the mark up past a readable size.
    public let wordmarkHeight: CGFloat
    /// The spacing to use between the identity/action rows.
    public let spacing: CGFloat

    public init(size: CGSize) {
        isCompact = size.height < Self.compactHeightThreshold
        wordmarkHeight = min(max(size.height * 0.12, 32), 88)
        spacing = isCompact ? Self.compactSpacing : Self.regularSpacing
    }

    /// Two columns on a phone so the four quiet actions read as two rows
    /// instead of four; one column on an iPad, where height was never the
    /// constraint and the current single-column structure stays as-is.
    public var quietColumns: Int { isCompact ? 2 : 1 }

    /// Estimated height of the actions column — the mute row, the two
    /// primary buttons, and the quiet grid — the tallest stack in the menu.
    /// Proves the compact layout fits a landscape phone without scrolling.
    public var estimatedActionsHeight: CGFloat {
        let muteRowHeight: CGFloat = 44
        let quietActionCount = 4
        let quietRows = (quietActionCount + quietColumns - 1) / quietColumns
        let buttonHeight = isCompact ? Self.compactButtonHeight : Self.regularButtonHeight
        let primaryButtons = 2
        let rowCount = 1 + primaryButtons + quietRows
        let buttons = muteRowHeight + CGFloat(primaryButtons + quietRows) * buttonHeight
        let gaps = CGFloat(rowCount - 1) * spacing
        return buttons + gaps
    }
}
