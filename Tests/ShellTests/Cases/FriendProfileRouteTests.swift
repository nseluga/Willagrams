import Foundation
import Testing
import WillagramsRules
@testable import Account
@testable import Friends
@testable import Match
@testable import Shell

/// Opening a friend's profile from the friends list, and getting back.
///
/// The screen itself is `Tests/AccountTests`'. What is shell's is whose row it
/// renders, that it renders it read-only, and that Back lands on the list rather
/// than the menu.
@MainActor
@Suite("Friend profile route")
struct FriendProfileRouteTests {

    struct Fixture {
        let backend: FakeBackend
        let shell: ShellModel
        let me: Profile
        /// Accepted, and carrying numbers the local player does not have — a
        /// screen built from the wrong profile would otherwise be invisible.
        let friend: Profile
    }

    static func make() async throws -> Fixture {
        let backend = FakeBackend()
        let shell = ShellModel(
            // Never the real clock: a live countdown outlives the test and
            // aborts the process from `MatchSession.deinit`.
            sleepFor: { _ in },
            services: ShellServices(backend: backend, signIn: backend)
        )
        await shell.signInTask?.value
        let me = try #require(shell.currentProfile, "the shell never signed in")

        var friend = try await backend.signInWithApple(
            idToken: "friend-profile-route-friend",
            nonce: "n"
        )
        friend.displayName = "Zoe"
        friend.matchesPlayed = 41
        friend.matchesWon = 17
        friend.tilesPlaced = 900
        friend.fastestWinSeconds = 63
        await backend.seedProfile(friend)

        // Through the seam in both directions, as the app would: they ask, the
        // local player accepts. The session is still theirs from the sign-in
        // above, and `FakeBackend: ShellSignIn`'s own token is what puts it back.
        _ = try await backend.requestFriend(addresseeID: me.id)
        _ = try await backend.signIn()
        _ = try await backend.respondToFriendRequest(requesterID: friend.id, accept: true)

        return Fixture(backend: backend, shell: shell, me: me, friend: friend)
    }

    /// The one accepted row on the friends screen, after a real load.
    static func acceptedFriend(_ f: Fixture) async throws -> FriendEntry {
        #expect(f.shell.showFriends())
        let friends = try #require(f.shell.friends, "no friends model for the route to render")
        await friends.load()
        return try #require(friends.accepted.first, "the accepted friendship never loaded")
    }

    // MARK: - done when: tapping an accepted friend opens their read-only profile

    @Test("Tapping an accepted friend opens a read-only profile of that friend")
    func friendProfileIsTheFriendAndIsReadOnly() async throws {
        let f = try await Self.make()
        let entry = try await Self.acceptedFriend(f)
        #expect(entry.profile.id == f.friend.id)

        #expect(f.shell.showFriendProfile(entry))
        #expect(f.shell.route == .profile)

        let screen = try #require(f.shell.profile, "no screen model for the route to render")
        #expect(!screen.isEditable, "someone else's profile is never editable")
        #expect(screen.profile.id == f.friend.id)

        // The friend's row, spelled out: every number here is one the local
        // player does not have, so a screen built from `currentProfile` fails.
        #expect(screen.stats.map(\.value) == ["41", "17", "900", "63s"])
        #expect(f.me.matchesPlayed == 0, "the local player must differ, or the check above proves nothing")
    }

    @Test("A friend's profile is refused from anywhere but the friends list")
    func refusedOffTheFriendsList() async throws {
        let f = try await Self.make()
        let entry = try await Self.acceptedFriend(f)

        f.shell.returnToMenu()
        #expect(!f.shell.showFriendProfile(entry))
        #expect(f.shell.route == .menu)
        #expect(f.shell.profile == nil)
    }

    // MARK: - done when: Back returns to the friends list, not the menu

    @Test("Back out of a friend's profile returns to the friends list, still loaded")
    func backReturnsToTheFriendsList() async throws {
        let f = try await Self.make()
        let entry = try await Self.acceptedFriend(f)
        let friends = try #require(f.shell.friends)
        #expect(f.shell.showFriendProfile(entry))

        f.shell.dismissProfile()

        #expect(f.shell.route == .friends)
        #expect(f.shell.profile == nil, "the profile screen outlived its route")
        #expect(f.shell.friends === friends, "the friends list was torn down behind the profile")
        #expect(!friends.accepted.isEmpty, "the list came back empty")
    }

    @Test("Back out of the player's own profile still returns to the menu")
    func backFromOwnProfileStillGoesToTheMenu() async throws {
        let f = try await Self.make()
        #expect(f.shell.showProfile())

        f.shell.dismissProfile()

        #expect(f.shell.route == .menu)
        #expect(f.shell.profile == nil)
    }

    @Test("Back out of a friend's profile, then out of the list, reaches the menu")
    func theWholeWayBack() async throws {
        let f = try await Self.make()
        let entry = try await Self.acceptedFriend(f)
        #expect(f.shell.showFriendProfile(entry))

        f.shell.dismissProfile()
        f.shell.returnToMenu()

        #expect(f.shell.route == .menu)
        #expect(f.shell.friends == nil)
        #expect(f.shell.profile == nil)
    }

    // MARK: - the wiring no headless test can see

    /// `ShellRootView` is excluded from this package, so the two closures it
    /// hands down are unobservable here. Scoped to the two properties rather
    /// than scanned whole-file — `returnToMenu()` appears legitimately in
    /// several other screens — and asserted present, so a rename turns this red
    /// instead of vacuously green.
    @Test("The root view wires Back to dismissProfile and a friend tap to the shell")
    func rootViewWiresBothClosures() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ShellSrc")
                .resolvingSymlinksInPath()
                .appendingPathComponent("ShellRootView.swift"),
            encoding: .utf8
        )

        let profileScreen = try #require(
            Self.body(of: "profileScreen", in: source),
            "ShellRootView no longer declares profileScreen"
        )
        #expect(profileScreen.contains("shell.dismissProfile()"))
        #expect(
            !profileScreen.contains("shell.returnToMenu()"),
            "Back out of the profile goes to the menu, not to the screen it was opened from"
        )

        let friendsScreen = try #require(
            Self.body(of: "friendsScreen", in: source),
            "ShellRootView no longer declares friendsScreen"
        )
        #expect(friendsScreen.contains("shell.showFriendProfile(entry)"))
    }

    /// The lines of one `@ViewBuilder private var <name>` declaration, up to the
    /// next declaration. Nil when there is no such property.
    private static func body(of name: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("private var \(name):") }) else {
            return nil
        }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.contains("private var ") } ?? rest.endIndex
        return lines[start..<end].joined(separator: "\n")
    }
}
