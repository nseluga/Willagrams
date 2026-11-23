import Foundation

/// The App Store page, defined once. Every share sheet and the update prompt
/// read it from here, so there is no second copy of the address to go stale.
public enum AppStoreLink {
    public static let urlString = "https://apps.apple.com/app/id6812609905"
    /// The literal above is a valid URL (a test pins it); the fallback only
    /// keeps this free of a force unwrap, which the Match audit forbids.
    public static var url: URL { URL(string: urlString) ?? URL(fileURLWithPath: "/") }

    /// What a share sheet sends: the caller's line, then the link so a friend
    /// who has no app can install it. Copy never goes through this; it puts
    /// the bare code on the pasteboard because that text is pasted into Join.
    public static func shareText(_ line: String) -> String { "\(line)\n\(urlString)" }

    /// The invite for a match code.
    public static func inviteText(code: String) -> String {
        shareText("Join my Willagrams match with code \(code)")
    }
}
