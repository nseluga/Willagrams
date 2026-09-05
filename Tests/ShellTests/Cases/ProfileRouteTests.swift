import Foundation
import Testing
import WillagramsRules
@testable import Account
@testable import Match
@testable import Shell

/// The menu's way into the profile screen and back out again.
///
/// The screen itself is `Tests/AccountTests`' — what is asserted here is the
/// only part that is shell's: when the route moves, what it carries, and that
/// the screen model is gone before the menu is shown over it.
@MainActor
@Suite("Profile route")
struct ProfileRouteTests {

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

    // MARK: - done when: the menu's Profile action moves the route and back

    @Test("Profile moves the route to the profile screen and returns to the menu")
    func profileGoesThereAndBack() async throws {
        let f = try await Self.make()
        #expect(f.shell.route == .menu)

        #expect(f.shell.showProfile())
        #expect(f.shell.route == .profile)

        let screen = try #require(f.shell.profile, "no screen model for the route to render")
        #expect(screen.profile == f.me)
        #expect(screen.isEditable, "the local player's own screen edits")
        #expect(screen.draftName == f.me.displayName)

        f.shell.returnToMenu()
        #expect(f.shell.route == .menu)
        #expect(f.shell.profile == nil)
    }

    @Test("Profile is refused before sign-in lands")
    func refusedWithoutAProfile() throws {
        // No sign-in at all: the same state the menu disables the button in.
        let shell = ShellModel(sleepFor: { _ in })
        #expect(shell.currentProfile == nil)

        #expect(shell.showProfile() == false)
        #expect(shell.route == .menu)
        #expect(shell.profile == nil)
    }

    @Test("Profile is refused from anywhere but the menu")
    func refusedAwayFromTheMenu() async throws {
        let f = try await Self.make()
        f.shell.showSoloSetup()
        #expect(f.shell.route == .soloSetup)

        #expect(f.shell.showProfile() == false)
        #expect(f.shell.route == .soloSetup)
        #expect(f.shell.profile == nil)

        f.shell.returnToMenu()
    }

    /// The screen really writes through the backend the root handed the shell —
    /// not one it built for itself — so the row the menu re-reads has moved.
    @Test("A name saved on the screen lands on the row the shell signed in as")
    func savingReachesTheInjectedBackend() async throws {
        let f = try await Self.make()
        #expect(f.shell.showProfile())

        let screen = try #require(f.shell.profile)
        screen.draftName = "Ada"
        await screen.save()

        #expect(screen.profile.displayName == "Ada")
        let stored = try await f.backend.profile(id: f.me.id)
        #expect(stored.displayName == "Ada")
    }

    // MARK: - guardrail: teardown before the route moves

    /// The ordering half, which a state check after the call cannot see: both
    /// halves land in one main-actor turn. `withObservationTracking`'s
    /// `onChange` fires on `willSet` — the instant before `route` becomes
    /// `.menu` — so this is the only way to tell which happened first.
    @Test("The screen model is already gone when the route leaves it")
    func screenIsTornDownBeforeTheRouteMoves() async throws {
        let f = try await Self.make()
        #expect(f.shell.showProfile())
        #expect(f.shell.profile != nil)

        nonisolated(unsafe) var screenWhenTheRouteMoved: ProfileModel?
        let shell = f.shell
        withObservationTracking {
            _ = shell.route
        } onChange: {
            screenWhenTheRouteMoved = MainActor.assumeIsolated { shell.profile }
        }

        f.shell.returnToMenu()

        #expect(screenWhenTheRouteMoved == nil)
        #expect(f.shell.route == .menu)
    }

    /// A draft typed and abandoned does not come back on the next visit: the
    /// model is rebuilt from the row, not reused.
    @Test("An abandoned draft does not survive a trip to the menu")
    func draftDoesNotSurvive() async throws {
        let f = try await Self.make()
        #expect(f.shell.showProfile())
        f.shell.profile?.draftName = "half typed"
        f.shell.returnToMenu()

        #expect(f.shell.showProfile())
        #expect(f.shell.profile?.draftName == f.me.displayName)
        f.shell.returnToMenu()
    }

    // MARK: - the menu's own row

    /// `MenuView` is SwiftUI and cannot be built on macOS, so what it wires is
    /// checked against the bytes on disk — the `ShellRootViewTests` approach.
    @Test("The menu offers Profile, gated on the signed-in row")
    func menuOffersProfile() throws {
        let menu = try Self.shellSource("MenuView.swift")
        #expect(menu.contains("shell.showProfile()"), "the menu no longer offers Profile")
        #expect(menu.contains("ProfileModel.title"), "the menu's Profile row is not labelled from the screen")
        #expect(
            menu.contains(".disabled(shell.currentProfile == nil)"),
            "the Profile row is not gated on a signed-in profile"
        )
    }

    @Test("The root renders the profile screen and hands it the way back")
    func rootRendersTheScreen() throws {
        let root = try Self.shellSource("ShellRootView.swift")
        #expect(root.contains("case .profile:"))
        #expect(root.contains("ProfileView(model: profile) { shell.returnToMenu() }"))
    }

    /// The clipboard the Copy button writes through.
    ///
    /// Checked against the bytes because `UIPasteboard` is UIKit and this
    /// package builds for macOS: with the closure left off, `ProfileModel`
    /// takes its no-op default, the app's Copy button silently copies nothing,
    /// and every executable test here still passes. Found by mutation.
    @Test("The shell hands the screen a clipboard that really writes")
    func shellWiresTheClipboard() throws {
        let model = try Self.shellSource("ShellModel.swift")
        #expect(model.contains("pasteboard: Self.pasteboard"), "showProfile hands the screen no clipboard")
        #expect(model.contains("UIPasteboard.general.string = text"), "the clipboard closure writes nothing")
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
