import Auth
import Foundation
import Testing
@testable import Friends
@testable import Match

/// The gate. Live cases talk to the real project, so they run only when both
/// halves are present: the opt-in flag and a key to open the door with. Unset
/// either and every case below reports as skipped — never as passed.
///
///     WILLAGRAMS_LIVE_TESTS=1 SUPABASE_ANON_KEY=... swift test --package-path Tests/FriendsTests
///
/// This is the item's real proof. RLS refuses a read by returning zero rows
/// rather than an error, so a fake-only pass says nothing at all about whether
/// two players can actually see each other's friendship.
enum LiveProject {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WILLAGRAMS_LIVE_TESTS"] == "1"
            && !SupabaseConfig.anonKey.isEmpty
    }

    /// A backend nobody else shares. Each user gets its own session store, so
    /// "a fresh anonymous user" really is fresh rather than whichever session
    /// the Keychain still holds.
    static func fresh() -> SupabaseBackend {
        SupabaseBackend(localStorage: EphemeralAuthStorage())
    }
}

/// Session storage that dies with the test. Not a mock of the Keychain — the
/// real thing would make two users in one run share a session.
final class EphemeralAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { values[key] = nil } }
}

@MainActor
@Suite("Friends against the live project")
struct FriendsLiveTests {

    // MARK: - done when: both sides list the other as accepted

    @Test("Two fresh users request and accept, and each side's model lists the other",
          .enabled(if: LiveProject.isEnabled))
    func bothSidesListTheOther() async throws {
        let aBackend = LiveProject.fresh()
        let bBackend = LiveProject.fresh()
        let a = try await aBackend.signInAnonymously()
        let b = try await bBackend.signInAnonymously()

        // Before the request there is nothing to see, so the assertions below
        // cannot be reading somebody else's leftovers.
        let aBefore = FriendsModel(me: a.id, backend: aBackend)
        await aBefore.load()
        #expect(!aBefore.accepted.contains { $0.profile.id == b.id })

        _ = try await aBackend.requestFriend(addresseeID: b.id)

        // The pending state, seen from both ends: one row, opposite sections.
        let aPending = FriendsModel(me: a.id, backend: aBackend)
        await aPending.load()
        #expect(aPending.outgoing.contains { $0.profile.id == b.id }, "the asker sees it as outgoing")
        #expect(!aPending.incoming.contains { $0.profile.id == b.id })

        let bPending = FriendsModel(me: b.id, backend: bBackend)
        await bPending.load()
        #expect(bPending.incoming.contains { $0.profile.id == a.id },
                "the addressee cannot see the request RLS is meant to show them")

        // Accepted through the model, not around it.
        let request = try #require(bPending.incoming.first { $0.profile.id == a.id })
        await bPending.accept(request)
        #expect(bPending.message == nil, "accepting failed against the live project")
        #expect(bPending.accepted.contains { $0.profile.id == a.id })
        #expect(bPending.incoming.isEmpty)

        // The other end, read fresh: this is the RLS proof.
        let aAfter = FriendsModel(me: a.id, backend: aBackend)
        await aAfter.load()
        #expect(aAfter.accepted.contains { $0.profile.id == b.id },
                "the requester cannot see the accepted row")
        #expect(aAfter.outgoing.isEmpty)

        // The counterpart profile really resolved through `profile(id:)`, so a
        // signed-in player can read a stranger's row as `profiles_select` says.
        let entry = try #require(aAfter.accepted.first { $0.profile.id == b.id })
        #expect(entry.profile.friendCode == b.friendCode)
    }

    // MARK: - done when: a blocked user appears in neither list

    @Test("A blocked user appears in no section on either side",
          .enabled(if: LiveProject.isEnabled))
    func blockedIsInvisible() async throws {
        let aBackend = LiveProject.fresh()
        let cBackend = LiveProject.fresh()
        let a = try await aBackend.signInAnonymously()
        let c = try await cBackend.signInAnonymously()

        _ = try await cBackend.requestFriend(addresseeID: a.id)

        let aModel = FriendsModel(me: a.id, backend: aBackend)
        await aModel.load()
        // Presence: the request really arrived, so the filter below fires
        // rather than passing over an empty list.
        let request = try #require(aModel.incoming.first { $0.profile.id == c.id },
                                   "the request never reached the addressee")

        await aModel.decline(request)
        #expect(aModel.message == nil, "declining failed against the live project")

        for section in [aModel.accepted, aModel.incoming, aModel.outgoing] {
            #expect(!section.contains { $0.profile.id == c.id })
        }

        // The row is really there and really blocked — hidden by the model, not
        // absent from the database.
        let rows = try await aBackend.friendships().filter { $0.other(than: a.id) == c.id }
        #expect(rows.count == 1)
        #expect(rows.first?.status == .blocked)

        // And the far end, freshly read, does not list the blocker either.
        let cModel = FriendsModel(me: c.id, backend: cBackend)
        await cModel.load()
        for section in [cModel.accepted, cModel.incoming, cModel.outgoing] {
            #expect(!section.contains { $0.profile.id == a.id })
        }
    }

    /// Blocking outright, with no request in either direction, and from the
    /// blocker's own side.
    @Test("Blocking a friend takes them out of the accepted section on the live project",
          .enabled(if: LiveProject.isEnabled))
    func blockingAFriendHidesThem() async throws {
        let aBackend = LiveProject.fresh()
        let bBackend = LiveProject.fresh()
        let a = try await aBackend.signInAnonymously()
        let b = try await bBackend.signInAnonymously()

        _ = try await aBackend.requestFriend(addresseeID: b.id)
        _ = try await bBackend.respondToFriendRequest(requesterID: a.id, accept: true)

        let aModel = FriendsModel(me: a.id, backend: aBackend)
        await aModel.load()
        let friend = try #require(aModel.accepted.first { $0.profile.id == b.id })

        await aModel.block(friend)
        #expect(aModel.message == nil, "blocking failed against the live project")
        #expect(!aModel.accepted.contains { $0.profile.id == b.id })

        let bModel = FriendsModel(me: b.id, backend: bBackend)
        await bModel.load()
        #expect(!bModel.accepted.contains { $0.profile.id == a.id },
                "the blocked player still lists the blocker as a friend")
    }

    /// A stranger's list says nothing about somebody else's pair — the same
    /// policy `Tests/OnlineTests` proves at the row level, asked here at the
    /// screen level.
    @Test("A third player's model shows neither end of somebody else's friendship",
          .enabled(if: LiveProject.isEnabled))
    func aStrangerSeesNothing() async throws {
        let aBackend = LiveProject.fresh()
        let bBackend = LiveProject.fresh()
        let strangerBackend = LiveProject.fresh()
        let a = try await aBackend.signInAnonymously()
        let b = try await bBackend.signInAnonymously()
        let stranger = try await strangerBackend.signInAnonymously()

        _ = try await aBackend.requestFriend(addresseeID: b.id)
        _ = try await bBackend.respondToFriendRequest(requesterID: a.id, accept: true)

        let model = FriendsModel(me: stranger.id, backend: strangerBackend)
        await model.load()
        #expect(model.isEmpty, "a fresh stranger's friends list must be empty")
    }
}
