import Foundation
import Testing
@testable import Friends

/// "Invite to play" belongs to an accepted row and to no other kind.
///
/// `FriendsView` is SwiftUI and cannot be built for this target, so the
/// placement is checked against the bytes on disk on the same pattern as
/// `SourceGuardrailTests` beside it — and, like every check there, this asserts
/// what must be PRESENT as well as where it must not appear: a scan that only
/// looked for the absence would turn green the day the button is deleted.
@MainActor
@Suite("Invite row")
struct InviteRowTests {

    private static var friendsSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Cases
            .deletingLastPathComponent()   // FriendsTests
            .appendingPathComponent("FriendsSrc")
            .resolvingSymlinksInPath()
    }

    private static func text(_ name: String) throws -> String {
        try String(contentsOf: friendsSource.appendingPathComponent(name), encoding: .utf8)
    }

    @Test("The label is the model's, spelled once, and says nothing about the shell")
    func theLabelIsTheModels() throws {
        #expect(FriendsModel.invitePlayLabel == "Invite to play")

        let view = try Self.text("FriendsView.swift")
        let uses = view.components(separatedBy: "FriendsModel.invitePlayLabel").count - 1
        #expect(uses == 1, "the invite button is drawn \(uses) times, not once")
        // The literal itself is never drawn: the label has one home. A doc
        // comment naming it is not a second copy, so only code lines count.
        let code = view.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(!code.contains { $0.contains("\"Invite to play\"") })
    }

    /// Item 3 moved every row's actions out of the section bodies and into
    /// `rowActions(_:entry:)`, rendered from `FriendRowSection`, so the old
    /// scan of "where does the literal sit between these section titles" no
    /// longer has anything true to say — it would fail the moment a helper
    /// function moved in the file for an unrelated reason. The section that
    /// owns the button is asserted at the data layer instead, where
    /// `FriendRowActionsTests` also pins it, and the view is only checked for
    /// the parts a data-layer test cannot see: the closure wiring back to the
    /// shell.
    @Test("Invite to play is the accepted section's primary action, and nowhere else")
    func onlyAcceptedRowsCarryIt() throws {
        #expect(FriendRowSection.accepted.primaryAction == .invitePlay)
        #expect(FriendRowSection.incoming.primaryAction != .invitePlay)
        #expect(FriendRowSection.outgoing.allActions.isEmpty)

        let view = try Self.text("FriendsView.swift")

        // The tap is reported, not decided: hosting and sending are the shell's.
        #expect(view.contains("onInvite(entry)"))
        #expect(view.contains("let onInvite: (FriendEntry) -> Void"))
    }
}
