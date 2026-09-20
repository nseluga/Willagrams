import CoreGraphics
import Testing
@testable import Shell

/// `MatchHUDLayout` is the plain struct behind the pool bag's sizing and its
/// count text — no SwiftUI, no simulator, so its numbers are asserted
/// directly here.
@Suite("Match HUD layout")
struct MatchHUDLayoutTests {

    @Test("The compact bag is smaller than the regular one, and the regular size is unchanged")
    func compactBagIsSmaller() {
        let regular = MatchHUDLayout(isCompact: false)
        let compact = MatchHUDLayout(isCompact: true)

        #expect(regular.bagSize == 96)
        #expect(compact.bagSize < regular.bagSize)
    }

    @Test("The count is the plain number for real counts, and an em dash exactly when the count is unknown")
    func poolValueFormatsCounts() {
        #expect(MatchHUDLayout.poolValue(0) == "0")
        #expect(MatchHUDLayout.poolValue(9) == "9")
        #expect(MatchHUDLayout.poolValue(98) == "98")
        #expect(MatchHUDLayout.poolValue(144) == "144")
        #expect(MatchHUDLayout.poolValue(nil) == "—")
    }
}
