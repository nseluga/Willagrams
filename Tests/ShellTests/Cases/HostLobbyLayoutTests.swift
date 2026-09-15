import Testing
@testable import Shell

/// `HostLobbyLayout` is the plain struct behind the Host Lobby's sizing — no
/// SwiftUI, no simulator, so its numbers are asserted directly here.
@Suite("Host lobby layout")
struct HostLobbyLayoutTests {

    @Test("The compact code font and button height are smaller than regular")
    func compactIsSmallerThanRegular() {
        let compact = HostLobbyLayout(isCompact: true)
        let regular = HostLobbyLayout(isCompact: false)

        #expect(compact.isCompact)
        #expect(!regular.isCompact)
        #expect(compact.codeFontSize < regular.codeFontSize)
        #expect(compact.buttonHeight <= regular.buttonHeight)
    }
}
