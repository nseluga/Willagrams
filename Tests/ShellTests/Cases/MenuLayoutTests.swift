import CoreGraphics
import Testing
@testable import Shell

/// `MenuLayout` is the plain struct behind the Menu's sizing — no SwiftUI,
/// no simulator, so its numbers are asserted directly here.
@Suite("Menu layout")
struct MenuLayoutTests {

    /// iPhone 13 mini, landscape. The safe area eats into the 375pt height —
    /// no top inset in landscape, a 21pt bottom inset for the home indicator.
    private static let iPhone13MiniLandscapeSafeAreaInset: CGFloat = 21

    @Test("The compact menu fits a landscape phone without scrolling, in a two-column quiet grid")
    func compactMenuFitsPhone() {
        let layout = MenuLayout(size: CGSize(width: 812, height: 375))

        #expect(layout.isCompact)
        #expect(layout.quietColumns == 2)

        let budget: CGFloat = 375 - Self.iPhone13MiniLandscapeSafeAreaInset
        #expect(layout.estimatedActionsHeight <= budget)
    }

    @Test("The iPad wordmark grows past the old fixed constant, capped at 88pt")
    func iPadWordmarkGrowsWithinCap() {
        let layout = MenuLayout(size: CGSize(width: 1194, height: 834))

        #expect(!layout.isCompact)
        #expect(layout.quietColumns == 1)
        // 64 was the old fixed `wordmarkCell` ceiling this layout replaces.
        #expect(layout.wordmarkHeight > 64)
        #expect(layout.wordmarkHeight <= 88)
    }
}
