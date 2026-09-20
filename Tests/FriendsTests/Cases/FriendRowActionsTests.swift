import Foundation
import Testing
@testable import Friends

/// The friend row's action set, pinned at the data layer rather than against
/// `FriendsView`'s nesting: a view-tree scan turns green the day the actions
/// move to a different control for an unrelated reason, and this must stay
/// true through exactly that move. `FriendsView` renders from
/// `FriendRowSection`, so this suite is the guarantee that none of the five
/// real actions — Accept, Decline, Block, Invite to play, Unfriend — was
/// dropped when the row shrank to fit a phone.
@Suite("Friend row actions")
struct FriendRowActionsTests {

    @Test("Every action available today is still offered by exactly one section")
    func allFiveActionsSurvive() {
        let offered = Set(
            FriendRowSection.incoming.allActions
                + FriendRowSection.accepted.allActions
                + FriendRowSection.outgoing.allActions
        )
        #expect(offered == Set(FriendRowAction.allCases))
    }

    @Test("Incoming: Accept stays a visible primary button, Decline and Block move to the overflow")
    func incomingSection() {
        #expect(FriendRowSection.incoming.primaryAction == .accept)
        #expect(FriendRowSection.incoming.overflowActions == [.decline, .block])
        #expect(FriendRowSection.incoming.allActions == [.accept, .decline, .block])
    }

    @Test("Accepted: Invite to play stays a visible primary button, Unfriend and Block move to the overflow")
    func acceptedSection() {
        #expect(FriendRowSection.accepted.primaryAction == .invitePlay)
        #expect(FriendRowSection.accepted.overflowActions == [.unfriend, .block])
        #expect(FriendRowSection.accepted.allActions == [.invitePlay, .unfriend, .block])
    }

    @Test("Outgoing still has nothing to act on")
    func outgoingSection() {
        #expect(FriendRowSection.outgoing.primaryAction == nil)
        #expect(FriendRowSection.outgoing.overflowActions.isEmpty)
        #expect(FriendRowSection.outgoing.allActions.isEmpty)
    }

    /// The data layer alone cannot catch a row whose `switch` quietly returns
    /// `EmptyView` for an action the enum still lists — `FriendsView` is
    /// SwiftUI and never compiles here, so the wiring is checked against the
    /// bytes on disk, the same pattern `InviteRowTests` uses beside it.
    @Test("FriendsView actually draws every action's label, and labels the overflow control")
    func theViewDrawsEachAction() throws {
        let view = try Self.viewSource()
        for label in ["acceptLabel", "declineLabel", "blockLabel", "invitePlayLabel", "unfriendLabel"] {
            #expect(view.contains("FriendsModel.\(label)"), "FriendsView no longer draws \(label)")
        }
        // A bare glyph is an accessibility regression, and the word is a
        // screen label beside its siblings, never inlined at the call site.
        #expect(view.contains(".accessibilityLabel(FriendsModel.moreActionsLabel)"))
        #expect(!view.contains("\"More actions\""))
    }

    /// The overflow was moved off `Menu` because UIKit's system popup ignores
    /// `DesignTokens` entirely — it cannot be themed, only replaced. A `Menu`
    /// reintroduced here would look stock again and break nothing else, so the
    /// count is pinned: every `Menu {` in the file must be a `BrandMenu {`.
    @Test("The overflow is a BrandMenu, and its rows are BrandMenuRows")
    func theOverflowIsThemed() throws {
        let view = try Self.viewSource()
        #expect(Self.occurrences(of: "Menu {", in: view) == Self.occurrences(of: "BrandMenu {", in: view))
        for label in ["declineLabel", "blockLabel", "unfriendLabel"] {
            #expect(
                view.contains("BrandMenuRow(FriendsModel.\(label)"),
                "\(label) is no longer a themed row"
            )
        }
    }

    private static func viewSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("FriendsSrc/FriendsView.swift")
                .resolvingSymlinksInPath(),
            encoding: .utf8
        )
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
