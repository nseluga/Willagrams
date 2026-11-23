import Foundation
import Testing
@testable import Match
@testable import Friends
@testable import Shell

/// The share text carries the App Store link; Copy stays the bare code.
@Suite("Share link")
struct ShareLinkTests {
    @Test("An invite message holds the code and the store link")
    func inviteHasCodeAndLink() {
        let text = AppStoreLink.inviteText(code: "K7M2QX")
        #expect(text.contains("K7M2QX"))
        #expect(text.contains("https://apps.apple.com/app/id6812609905"))
    }

    @Test("The link is a valid URL on the one constant")
    func linkIsValid() {
        #expect(AppStoreLink.url.absoluteString == AppStoreLink.urlString)
        #expect(AppStoreLink.url.host == "apps.apple.com")
    }

    @Test("Pasting the whole invite into Join gives back the code")
    @MainActor func pastedInviteSanitisesToTheCode() {
        #expect(JoinModel.sanitised(AppStoreLink.inviteText(code: "K7M2QX")) == "K7M2QX")
    }
}
