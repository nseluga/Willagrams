import Foundation
import Testing
import WillagramsRules
@testable import Friends
@testable import Match
@testable import Shell

/// The menu's way into the friends list and back out again.
///
/// The screen itself is `Tests/FriendsTests`' — what is asserted here is the
/// only part that is shell's: when the route moves, what it carries, and that
/// the screen model is gone before the menu is shown over it.
@MainActor
@Suite("Friends route")
struct FriendsRouteTests {

    struct Fixture {
        let backend: FakeBackend
        let shell: ShellModel
        let me: Profile
    }

    /// A shell that has finished signing in, so `currentProfile` is there.
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
        return Fixture(backend: backend, shell: shell, me: me)
    }

    // MARK: - done when: the menu's Friends action moves the route and back

    @Test("Friends moves the route to the friends list and returns to the menu")
    func friendsGoesThereAndBack() async throws {
        let f = try await Self.make()
        #expect(f.shell.route == .menu)

        #expect(f.shell.showFriends())
        #expect(f.shell.route == .friends)
        #expect(f.shell.friends != nil, "no screen model for the route to render")

        f.shell.returnToMenu()
        #expect(f.shell.route == .menu)
        #expect(f.shell.friends == nil)
    }

    @Test("Friends is refused before sign-in lands")
    func refusedWithoutAProfile() throws {
        let shell = ShellModel(sleepFor: { _ in })
        #expect(shell.currentProfile == nil)

        #expect(shell.showFriends() == false)
        #expect(shell.route == .menu)
        #expect(shell.friends == nil)
    }

    @Test("Friends is refused from anywhere but the menu")
    func refusedAwayFromTheMenu() async throws {
        let f = try await Self.make()
        f.shell.showSoloSetup()
        #expect(f.shell.route == .soloSetup)

        #expect(f.shell.showFriends() == false)
        #expect(f.shell.route == .soloSetup)
        #expect(f.shell.friends == nil)

        f.shell.returnToMenu()
    }

    /// The screen really reads through the backend the root handed the shell —
    /// not one it built for itself — so what it lists is the signed-in row's.
    @Test("The list reads the backend the shell signed in as, from the signed-in end")
    func readsTheInjectedBackend() async throws {
        let f = try await Self.make()

        // A second player who has asked to be friends with the signed-in one.
        let asker = try await f.backend.signInWithApple(idToken: "friends-route-asker", nonce: "n")
        _ = try await f.backend.requestFriend(addresseeID: f.me.id)
        // Back to whoever the shell is: `FakeBackend: ShellSignIn` uses this
        // token, so the session ends where the model will read from.
        _ = try await f.backend.signIn()

        #expect(f.shell.showFriends())
        let screen = try #require(f.shell.friends)
        await screen.load()

        // Incoming, not outgoing: the model was built for the shell's own id,
        // so the direction it read the row from is the signed-in player's.
        #expect(screen.incoming.map(\.profile.id) == [asker.id])
        #expect(screen.outgoing.isEmpty)

        f.shell.returnToMenu()
    }

    // MARK: - guardrail: teardown before the route moves

    /// The ordering half, which a state check after the call cannot see: both
    /// halves land in one main-actor turn. `withObservationTracking`'s `onChange`
    /// fires on `willSet` — the instant before `route` becomes `.menu` — so this
    /// is the only way to tell which happened first.
    @Test("The screen model is already gone when the route leaves it")
    func screenIsTornDownBeforeTheRouteMoves() async throws {
        let f = try await Self.make()
        #expect(f.shell.showFriends())
        #expect(f.shell.friends != nil)

        nonisolated(unsafe) var screenWhenTheRouteMoved: FriendsModel?
        let shell = f.shell
        withObservationTracking {
            _ = shell.route
        } onChange: {
            screenWhenTheRouteMoved = MainActor.assumeIsolated { shell.friends }
        }

        f.shell.returnToMenu()

        #expect(screenWhenTheRouteMoved == nil)
        #expect(f.shell.route == .menu)
    }

    /// A second visit reads the list again rather than showing the first
    /// visit's: the model is rebuilt, not reused.
    @Test("A second visit builds a new screen model")
    func screenIsRebuiltPerVisit() async throws {
        let f = try await Self.make()
        #expect(f.shell.showFriends())
        let first = try #require(f.shell.friends)
        f.shell.returnToMenu()

        #expect(f.shell.showFriends())
        let second = try #require(f.shell.friends)
        #expect(first !== second)
        f.shell.returnToMenu()
    }

    // MARK: - the menu's own row

    /// `MenuView` is SwiftUI and cannot be built on macOS, so what it wires is
    /// checked against the bytes on disk — the `ProfileRouteTests` approach.
    @Test("The menu offers Friends, gated on the signed-in row")
    func menuOffersFriends() throws {
        let menu = try Self.shellSource("MenuView.swift")
        #expect(menu.contains("shell.showFriends()"), "the menu no longer offers Friends")
        #expect(menu.contains("FriendsModel.title"), "the menu's Friends row is not labelled from the screen")

        // Scoped to the Friends row. A whole-file `menu.contains(".disabled(…)")`
        // is vacuously green: the Profile row above carries the same modifier, so
        // it stayed green with the Friends row ungated. Cut at the blank line that
        // ends the row so a match cannot come from a neighbour.
        let action = try #require(menu.range(of: "shell.showFriends()"))
        let rest = menu[action.upperBound...]
        let row = rest.range(of: "\n\n").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        #expect(row.count < 400, "the Friends row did not end where expected — this scan is not scoped")
        #expect(
            row.contains(".disabled(shell.currentProfile == nil)"),
            "the Friends row is not gated on a signed-in profile"
        )
    }

    @Test("The root renders the friends screen and hands it the way back")
    func rootRendersTheScreen() throws {
        let root = try Self.shellSource("ShellRootView.swift")
        #expect(root.contains("case .friends:"))
        #expect(root.contains("FriendsView(model: friends) { shell.returnToMenu() }"))
    }

    /// The screen loads itself. `.task` is a SwiftUI modifier this package
    /// cannot run, so the wiring is asserted against the bytes: without it the
    /// list is permanently empty and every model test here still passes.
    @Test("The view asks the model to load itself")
    func viewLoadsTheList() throws {
        let view = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("FriendsSrc/FriendsView.swift")
                .resolvingSymlinksInPath(),
            encoding: .utf8
        )
        #expect(view.contains(".task { await model.load() }"))
    }

    private static func shellSource(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ShellSrc/\(name)")
                .resolvingSymlinksInPath(),
            encoding: .utf8
        )
    }
}
