import Foundation
import SwiftUI
import Testing
import StyleKit

/// The evidence that a friend row's action cluster fits a 375pt phone now
/// that item 3 moved `Decline`/`Block` (incoming) and `Unfriend`/`Block`
/// (accepted) into an overflow `Menu`, leaving one primary labelled button
/// plus the overflow control on the row itself. Nobody can tap the
/// Simulator to screenshot this, so the budget is computed instead, reading
/// the real constants rather than guessing them.
@Suite("Friend row budget")
struct FriendRowBudgetTests {

    /// `FriendsView.swift` lives outside `Willagrams/Style/`, so it is read
    /// directly rather than through `StyleRepo.source`.
    static var friendsViewSource: String {
        get throws {
            try String(
                contentsOf: StyleRepo.root.appendingPathComponent("Willagrams/Friends/FriendsView.swift"),
                encoding: .utf8
            )
        }
    }

    /// `contentMaxWidth` and `rowTileSize` are `private static let`s on
    /// `FriendsView` — read from source rather than guessed, on the same
    /// pattern `ButtonLabelFitTests.pointSizesMatchTokens` uses for
    /// `DesignTokens.swift`.
    static func friendsViewConstant(_ name: String) throws -> CGFloat {
        let source = StyleRepo.strippingComments(try friendsViewSource)
        let hits = StyleRepo.matches(#"static let \#(name): CGFloat = ([0-9.]+)"#, in: source)
        let value = try #require(hits.first.flatMap(Double.init), "could not read \(name) from FriendsView.swift")
        return CGFloat(value)
    }

    /// What is left over for the trailing action cluster on a portrait
    /// phone: the screen, less `screenPadding()`'s margin on both sides
    /// (capped to the row's own `contentMaxWidth`), less the card padding
    /// the row applies to itself, less the avatar tile, less the two
    /// inter-element gaps either side of the elastic name/code column
    /// (avatar↔name, and the `Spacer(minLength:)` ahead of the actions).
    static func actionClusterBudget(screen: CGFloat) throws -> CGFloat {
        let h: UserInterfaceSizeClass? = .compact
        let v: UserInterfaceSizeClass? = .regular
        let contentMaxWidth = try friendsViewConstant("contentMaxWidth")
        let rowTileSize = try friendsViewConstant("rowTileSize")

        let contentWidth = min(screen, contentMaxWidth) - 2 * ScreenMargin.value(horizontal: h, vertical: v)
        return contentWidth
            - 2 * DesignTokens.Space.m   // row(): .padding(DesignTokens.Space.m)
            - rowTileSize                // row(): avatarTile(_:size: Self.rowTileSize)
            - 2 * DesignTokens.Space.m   // HStack(spacing: .m): avatar↔name, and the Spacer(minLength: .m)
    }

    /// One primary labelled button at compact `ButtonLabelFit` sizing, plus
    /// one overflow control, measured the way `ButtonLabelFitTests` measures
    /// every other row on this screen. The overflow control carries no
    /// label text, so it is modelled the same way the icon-only share
    /// control is there: a one-em glyph.
    static func measuredClusterWidth() -> CGFloat {
        let h: UserInterfaceSizeClass? = .compact
        let v: UserInterfaceSizeClass? = .regular
        let pointSize = ButtonLabelFit.pointSize(horizontal: h, vertical: v)

        // "Invite to play" is the longer of the row's two primary labels
        // (the other is "Accept"), so it is the one that has to fit.
        let labelWidth = ButtonLabelFitTests.width("Invite to play", pointSize: pointSize)
        let primaryButton = ButtonLabelFit.minimumButtonWidth(labelWidth: labelWidth, horizontal: h, vertical: v)
        let overflowControl = ButtonLabelFit.minimumButtonWidth(labelWidth: pointSize, horizontal: h, vertical: v)

        return primaryButton + DesignTokens.Space.m + overflowControl
    }

    @Test("A friend row's primary button plus overflow control fits a 375pt phone")
    func clusterFitsAt375() throws {
        let budget = try Self.actionClusterBudget(screen: 375)
        let measured = Self.measuredClusterWidth()
        #expect(measured <= budget, "cluster needs \(measured)pt of \(budget)pt")
    }

    /// The regression this item fixes: three full labelled buttons —
    /// `Invite to play`, `Unfriend`, `Block` — on one row, at the same
    /// compact sizing, did not fit. If this ever passes, the budget above
    /// has stopped meaning anything.
    @Test("Three full-size labelled buttons — the shipped-before layout — would not have fit")
    func threeButtonsWouldNotHaveFit() throws {
        let h: UserInterfaceSizeClass? = .compact
        let v: UserInterfaceSizeClass? = .regular
        let budget = try Self.actionClusterBudget(screen: 375)
        let pointSize = ButtonLabelFit.pointSize(horizontal: h, vertical: v)

        let widths = ["Invite to play", "Unfriend", "Block"].map {
            ButtonLabelFit.minimumButtonWidth(
                labelWidth: ButtonLabelFitTests.width($0, pointSize: pointSize),
                horizontal: h,
                vertical: v
            )
        }
        let total = widths.reduce(0, +) + 2 * DesignTokens.Space.m
        #expect(total > budget, "three buttons fit after all (\(total)pt of \(budget)pt) — this suite has no teeth")
    }
}
