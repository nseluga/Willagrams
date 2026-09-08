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

    @Test("The button is drawn inside the accepted section and nowhere else")
    func onlyAcceptedRowsCarryIt() throws {
        let view = try Self.text("FriendsView.swift")

        let accepted = try #require(view.range(of: "FriendsModel.acceptedSectionTitle"))
        let outgoing = try #require(view.range(of: "FriendsModel.outgoingSectionTitle"))
        let incoming = try #require(view.range(of: "FriendsModel.incomingSectionTitle"))
        let button = try #require(view.range(of: "FriendsModel.invitePlayLabel"))

        #expect(incoming.lowerBound < accepted.lowerBound, "the sections moved; this scan is stale")
        #expect(button.lowerBound > accepted.lowerBound, "the invite button is above the accepted section")
        #expect(button.upperBound < outgoing.lowerBound, "the invite button reaches a pending row")

        // The tap is reported, not decided: hosting and sending are the shell's.
        #expect(view.contains("onInvite(entry)"))
        #expect(view.contains("let onInvite: (FriendEntry) -> Void"))
    }
}
