import CoreGraphics

/// The Menu's sizing decisions, derived from the space SwiftUI measured for it.
///
/// A plain struct, not a View — no SwiftUI import — so `ShellTests` can
/// construct one directly and assert on its numbers without a simulator.
/// `MenuView` reads it for the wordmark height, the row spacing, whether the
/// quiet (secondary) actions sit in a two-column grid, and whether the
/// device is in the single-column portrait mode.
///
/// This cannot import `Willagrams/Style`: `DesignTokens.swift` imports
/// SwiftUI, which does not build for the macOS target this struct is tested
/// from (see `Tests/ShellTests/StyleSrc`, which symlinks only
/// `Terminology.swift` for exactly that reason). The two spacing numbers
/// below are kept in sync by hand with `DesignTokens.Space.s` / `.m`.

/// One of the Menu's six destinations, in the fixed order every device shows
/// them. A plain value — no SwiftUI — so `ShellTests` can assert the exact
/// order and each slot's enabled state without a simulator.
///
/// `MenuView` still hand-writes its buttons in both layouts, so this list is
/// a parallel description of Home rather than its source: change one and you
/// must change the other. `ShellTests` asserts this list against written
/// literals, which catches a change here but not one made only in the view.
public struct MenuAction: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case primary
        case quiet
    }

    public let title: String
    public let style: Style
    public let isEnabled: Bool
    /// A short reason shown under a disabled primary action. Nil for every
    /// other slot.
    public let caption: String?

    public init(title: String, style: Style, isEnabled: Bool = true, caption: String? = nil) {
        self.title = title
        self.style = style
        self.isEnabled = isEnabled
        self.caption = caption
    }
}

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

    /// The wordmark is square, so its one dimension is bounded by two things:
    /// the identity column's width (it should fill most of it, not sit tiny
    /// in the corner) and the vertical room the column actually has. Width
    /// wins on a wide iPad, height wins on a short landscape phone — either
    /// way the mark reads as the dominant shape in its column instead of a
    /// fixed-size logo.
    ///
    /// The width clamp is kept in sync by hand with `MenuView.WidthLayout`'s
    /// `identityColumnWidth` (`MenuLayout` cannot import that private type —
    /// see the header note on why it cannot import SwiftUI at all).
    private static let identityWidthFraction: CGFloat = 0.34
    private static let identityWidthMin: CGFloat = 260
    private static let identityWidthMax: CGFloat = 420

    /// Fraction of the screen height the mark is allowed to claim: more on a
    /// landscape phone, where width is the scarce dimension and the mark is
    /// the only thing racing the actions column for space; less on an iPad,
    /// where the identity column's width is the binding constraint anyway
    /// and a shorter mark leaves more air around the tagline.
    private static let compactHeightFraction: CGFloat = 0.55
    private static let regularHeightFraction: CGFloat = 0.40

    /// Portrait's wordmark is sized from the width alone — there is no
    /// second column racing it for space, so height never binds the way it
    /// does in the two-column layouts above.
    private static let portraitWordmarkFraction: CGFloat = 0.48
    private static let portraitWordmarkMin: CGFloat = 180
    private static let portraitWordmarkMax: CGFloat = 260

    /// True on a portrait phone (width < height): the single-column Home,
    /// mute top-right, wordmark near the top, PLAY actions anchored to the
    /// bottom. False for both landscape phone and iPad, which keep the
    /// existing two-column layout below.
    public let isPortrait: Bool
    /// True under a landscape phone's height, false on an iPad.
    public let isCompact: Bool
    /// Scales with the screen: bounded by the identity column's width and by
    /// the available height, whichever is tighter. In portrait it is bounded
    /// by width alone.
    public let wordmarkHeight: CGFloat
    /// The spacing to use between the identity/action rows.
    public let spacing: CGFloat

    public init(size: CGSize) {
        isPortrait = size.width < size.height
        isCompact = size.height < Self.compactHeightThreshold
        spacing = isCompact ? Self.compactSpacing : Self.regularSpacing

        if isPortrait {
            wordmarkHeight = min(
                max(size.width * Self.portraitWordmarkFraction, Self.portraitWordmarkMin),
                Self.portraitWordmarkMax
            )
        } else {
            let widthBudget = min(
                max(size.width * Self.identityWidthFraction, Self.identityWidthMin),
                Self.identityWidthMax
            )
            let heightBudget = size.height
                * (isCompact ? Self.compactHeightFraction : Self.regularHeightFraction)
            wordmarkHeight = min(widthBudget, heightBudget)
        }
    }

    /// Two columns on a phone (portrait or landscape) so the four quiet
    /// actions read as two rows instead of four; one column on an iPad,
    /// where height was never the constraint and the current single-column
    /// structure stays as-is.
    public var quietColumns: Int { (isCompact || isPortrait) ? 2 : 1 }

    /// The Menu's five destinations, in the fixed order both the portrait and
    /// landscape/iPad layouts render them: Play a Friend as the primary
    /// action, then Solo Practice, Profile, Friends and How to Play in the
    /// quiet grid. No Join entry — Join is reached from the Play a Friend
    /// screen, not from Home.
    public static let actions: [MenuAction] = [
        MenuAction(title: "Play a Friend", style: .primary),
        MenuAction(title: "Solo Practice", style: .quiet),
        MenuAction(title: "Profile", style: .quiet),
        MenuAction(title: "Friends", style: .quiet),
        MenuAction(title: "How to Play", style: .quiet),
    ]

    /// A conservative estimate of the portrait column's fixed (non-flexible)
    /// content height — the mute row, the wordmark, the PLAY label, the
    /// primary button, and the quiet grid.
    /// The gap between the wordmark and the PLAY section is a `Spacer` and
    /// contributes nothing here, so this proves the fixed content alone
    /// fits the screen without relying on that gap collapsing to zero.
    public var estimatedContentHeight: CGFloat {
        let muteRowHeight: CGFloat = 44
        let playLabelHeight: CGFloat = 20
        let onlineCaptionHeight: CGFloat = 16
        let buttonHeight = isCompact ? Self.compactButtonHeight : Self.regularButtonHeight

        let primaryCount = Self.actions.filter { $0.style == .primary }.count
        let quietCount = Self.actions.filter { $0.style == .quiet }.count
        let quietRows = (quietCount + quietColumns - 1) / quietColumns
        let rowCount = primaryCount + quietRows

        let topSection = muteRowHeight + spacing + wordmarkHeight
        let bottomSection = playLabelHeight
            + spacing
            + CGFloat(rowCount) * buttonHeight
            + CGFloat(rowCount - 1) * spacing
            + onlineCaptionHeight

        return topSection + spacing + bottomSection
    }

    /// Estimated height of the actions column — the mute row, the
    /// primary button, and the quiet grid — the tallest stack in the menu.
    /// Proves the compact layout fits a landscape phone without scrolling.
    public var estimatedActionsHeight: CGFloat {
        let muteRowHeight: CGFloat = 44
        let quietActionCount = 4
        let quietRows = (quietActionCount + quietColumns - 1) / quietColumns
        let buttonHeight = isCompact ? Self.compactButtonHeight : Self.regularButtonHeight
        let primaryButtons = 1
        let rowCount = 1 + primaryButtons + quietRows
        let buttons = muteRowHeight + CGFloat(primaryButtons + quietRows) * buttonHeight
        let gaps = CGFloat(rowCount - 1) * spacing
        return buttons + gaps
    }
}
