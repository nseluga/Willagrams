import Foundation
import Testing
@testable import Friends
@testable import Match

/// The model's sectioning, against the in-memory backend.
///
/// This is deliberately *only* the sectioning. Whether the database lets the two
/// ends see each other's row at all is a policy question a fake cannot answer —
/// `FriendsLiveTests` is where that is proved.
@MainActor
@Suite("Friends sectioning")
struct FriendsModelTests {

    private static func loaded(_ f: FriendsFixture) async -> FriendsModel {
        let model = FriendsModel(me: f.me.id, backend: f.backend)
        await model.load()
        return model
    }

    // MARK: - done when: each friendship lands in its own section

    @Test("An accepted, an incoming and an outgoing friendship each get their own section")
    func eachStatusGetsItsOwnSection() async throws {
        let f = try await FriendsFixture.make()
        let model = await Self.loaded(f)

        #expect(model.accepted.map(\.id) == [f.friend.id])
        #expect(model.incoming.map(\.id) == [f.asker.id])
        #expect(model.outgoing.map(\.id) == [f.asked.id])
        #expect(model.message == nil)
        #expect(!model.isEmpty)
    }

    /// The counterpart's row is resolved, not invented: the name on screen comes
    /// from `profile(id:)` and is the other player's, never the viewer's.
    @Test("Every entry carries the other player's profile")
    func entriesCarryTheCounterpartProfile() async throws {
        let f = try await FriendsFixture.make()
        let model = await Self.loaded(f)

        let entry = try #require(model.accepted.first)
        #expect(entry.profile == f.friend)
        #expect(entry.profile.id != f.me.id)
        #expect(entry.friendship.other(than: f.me.id) == f.friend.id)
    }

    // MARK: - done when: accepting moves the row

    @Test("Accepting the incoming request moves it to accepted")
    func acceptingMovesIt() async throws {
        let f = try await FriendsFixture.make()
        let model = await Self.loaded(f)

        let request = try #require(model.incoming.first)
        await model.accept(request)

        #expect(model.incoming.isEmpty)
        // Ordered by name, not by the order the rows came back in. The fixture
        // renames `friend` so those two orders disagree — the accepted row is
        // the older of the pair and the later name.
        #expect(f.asker.displayName < f.friend.displayName, "the fixture's names no longer disagree with row order")
        #expect(model.accepted.map(\.id) == [f.asker.id, f.friend.id])
        #expect(model.outgoing.map(\.id) == [f.asked.id], "accepting must not disturb the other sections")

        // The move is the database's, not the model's: the row itself now reads
        // accepted when read back through the seam.
        _ = try await f.backend.signIn("me")
        let rows = try await f.backend.friendships()
        let row = try #require(rows.first { $0.other(than: f.me.id) == f.asker.id })
        #expect(row.status == .accepted)
        #expect(row.respondedAt != nil)
    }

    /// Declining is a block at the seam, so the row leaves every section rather
    /// than moving to another one.
    @Test("Declining the incoming request removes it from every section")
    func decliningRemovesIt() async throws {
        let f = try await FriendsFixture.make()
        let model = await Self.loaded(f)

        let request = try #require(model.incoming.first)
        await model.decline(request)

        #expect(model.incoming.isEmpty)
        #expect(!model.accepted.contains { $0.id == f.asker.id })
        #expect(!model.outgoing.contains { $0.id == f.asker.id })
    }

    @Test("Blocking a friend takes them out of the accepted section")
    func blockingRemovesAFriend() async throws {
        let f = try await FriendsFixture.make()
        let model = await Self.loaded(f)

        let friend = try #require(model.accepted.first)
        await model.block(friend)

        #expect(model.accepted.isEmpty)
        #expect(model.incoming.map(\.id) == [f.asker.id], "blocking must not disturb the other sections")
        #expect(model.outgoing.map(\.id) == [f.asked.id])
    }

    // MARK: - done when: blocked players are hidden everywhere

    @Test("A blocked player appears in no section, whichever end blocked")
    func blockedPlayersAreHidden() async throws {
        let f = try await FriendsFixture.make()
        let model = await Self.loaded(f)

        // Presence first: the two blocked rows really are in the store, so this
        // is a filter that fires rather than a scan that found nothing.
        _ = try await f.backend.signIn("me")
        let blockedRows = try await f.backend.friendships().filter { $0.status == .blocked }
        #expect(Set(blockedRows.compactMap { $0.other(than: f.me.id) })
                == [f.blockedThem.id, f.blockedByMe.id])

        for section in [model.accepted, model.incoming, model.outgoing] {
            #expect(!section.contains { $0.id == f.blockedThem.id })
            #expect(!section.contains { $0.id == f.blockedByMe.id })
        }
    }

    // MARK: - failure and emptiness

    @Test("A player with no friendships publishes three empty sections")
    func emptyIsEmpty() async throws {
        let backend = FakeBackend()
        let me = try await backend.signIn("lonely")
        let model = FriendsModel(me: me.id, backend: backend)
        await model.load()

        #expect(model.accepted.isEmpty)
        #expect(model.incoming.isEmpty)
        #expect(model.outgoing.isEmpty)
        #expect(model.isEmpty)
        #expect(model.message == nil, "an empty list is not a failure")
    }

    /// A refused read says so and leaves the sections alone, rather than
    /// silently emptying a screen that had rows on it.
    @Test("A failed load reports and does not empty a loaded list")
    func failedLoadKeepsTheSections() async throws {
        let f = try await FriendsFixture.make()
        let model = await Self.loaded(f)
        #expect(!model.accepted.isEmpty)

        // Nobody signed in: `friendships()` throws `notAuthenticated`.
        try await f.backend.signOut()
        await model.load()

        #expect(model.message == FriendsModel.loadFailedMessage)
        #expect(model.accepted.map(\.id) == [f.friend.id], "a failed read must not blank the list")
        #expect(model.incoming.map(\.id) == [f.asker.id])

        // And the line goes away once a read works again, rather than sticking
        // to the screen for the rest of the visit.
        _ = try await f.backend.signIn("me")
        await model.load()
        #expect(model.message == nil)
    }

    @Test("isLoading is false once a load settles")
    func loadingSettles() async throws {
        let f = try await FriendsFixture.make()
        let model = await Self.loaded(f)
        #expect(!model.isLoading)

        await model.accept(try #require(model.incoming.first))
        #expect(!model.isLoading)
    }
}
