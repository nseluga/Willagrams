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
    /// not one it built for itself — and the saved row lands back on
    /// `ShellModel.currentProfile`, which is what every later visit is built
    /// from. Asserting only `screen.profile` is what let the stale-name bug ship
    /// green: the screen's own copy always moved, the shell's never did.
    @Test("A saved name reaches the shell's own row, not just the screen's")
    func savingReachesTheShellsRow() async throws {
        let f = try await Self.make()
        #expect(f.shell.showProfile())
        // Drained first, deliberately: a re-read still running would hand the
        // shell the same row a save is supposed to hand it, and every assertion
        // below would pass whether or not the save ever reached the shell.
        await f.shell.profileRefreshTask?.value

        let screen = try #require(f.shell.profile)
        screen.draftName = "Ada"
        await screen.save()

        #expect(screen.profile.displayName == "Ada")
        let stored = try await f.backend.profile(id: f.me.id)
        #expect(stored.displayName == "Ada")

        // The shell's copy — the one source of truth the app reads.
        #expect(f.shell.currentProfile?.displayName == "Ada")
        #expect(f.shell.currentProfile?.id == f.me.id, "the shell adopted a different row, not the saved one")

        // And the next visit is rebuilt from it, which is the defect itself.
        f.shell.returnToMenu()
        #expect(f.shell.showProfile())
        #expect(f.shell.profile?.profile.displayName == "Ada")
        #expect(f.shell.profile?.draftName == "Ada")
        f.shell.returnToMenu()
    }

    /// The wiring that carries the save back, pinned on the bytes as well: a
    /// `showProfile()` that forgets `onSaved:` compiles fine and silently
    /// restores the stale-name bug.
    @Test("showProfile hands the screen a way back to the shell's row")
    func showProfileWiresTheSaveBack() throws {
        let model = try Self.shellSource("ShellModel.swift")
        #expect(
            // The assignment only, not the whole call line: a reformat that
            // splits the closure across lines changes no behaviour.
            model.contains("currentProfile = saved"),
            "showProfile no longer writes the saved row back to currentProfile"
        )
    }

    /// The stats half of the same stale-row defect. `MatchOutcomeRecorder`
    /// discards the row `recordOutcome` hands back, so nothing in the app moves
    /// `currentProfile` after a finished match — the four stats would read their
    /// sign-in values all session. Opening Profile re-reads the row.
    @Test("Opening Profile re-reads the row, so a match's stats are not frozen at sign-in")
    func openingProfileRefreshesTheStoredRow() async throws {
        let f = try await Self.make()
        #expect(f.me.matchesPlayed == 0)

        // What a finished match leaves in the database, applied by the server
        // and never handed back through the client.
        var afterAMatch = f.me
        afterAMatch.matchesPlayed = 3
        afterAMatch.matchesWon = 2
        afterAMatch.tilesPlaced = 91
        afterAMatch.fastestWinSeconds = 84
        await f.backend.seedProfile(afterAMatch)

        #expect(f.shell.showProfile())
        await f.shell.profileRefreshTask?.value

        #expect(f.shell.currentProfile?.matchesPlayed == 3, "the shell's row is still the sign-in one")
        #expect(f.shell.profile?.profile.matchesPlayed == 3, "the screen is still drawing the frozen row")
        #expect(f.shell.profile?.stats.map(\.value) == ["3", "2", "91", "84s"])
        f.shell.returnToMenu()
    }

    /// The other order, which is the stale-name defect coming back sideways: the
    /// re-read is issued at open, the player saves while it is still in flight,
    /// and the row it has been holding since before the save must never be
    /// written over the saved one. The read is stamped with the row the visit
    /// opened on, so a `currentProfile` that has moved since drops it.
    @Test("A read still in flight when a save lands never undoes the save")
    func slowReadDoesNotClobberASave() async throws {
        let f = try await Self.make()
        // Runs inside the read, after the pre-save row has been taken and
        // before it is handed back — a response held open across a whole save.
        await f.backend.holdNextProfileRead {
            await Task { @MainActor in
                guard let screen = f.shell.profile else { return }
                screen.draftName = "Ada"
                await screen.save()
            }.value
        }

        #expect(f.shell.showProfile())
        await f.shell.profileRefreshTask?.value

        #expect(f.shell.currentProfile?.displayName == "Ada", "a read from before the save overwrote the shell's row")
        #expect(f.shell.profile?.profile.displayName == "Ada", "a read from before the save overwrote the screen")
        f.shell.returnToMenu()
    }

    /// The re-read must never eat what the player is typing, so a draft already
    /// changed survives a row landing under it.
    @Test("A re-read row does not overwrite a draft the player has already typed")
    func refreshLeavesATypedDraftAlone() async throws {
        let f = try await Self.make()
        #expect(f.shell.showProfile())
        let screen = try #require(f.shell.profile)
        screen.draftName = "half typed"

        var bumped = f.me
        bumped.matchesPlayed = 5
        screen.adopt(bumped)

        #expect(screen.profile.matchesPlayed == 5, "the stats did not refresh")
        #expect(screen.draftName == "half typed", "the re-read ate what the player typed")
        f.shell.returnToMenu()
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
        // `dismissProfile()`, not `returnToMenu()`: this screen is opened from
        // the menu and from the friends list, and Back means the one it came
        // from. `FriendProfileRouteTests` owns the scoped check of both halves.
        #expect(root.contains("ProfileView(model: profile) { shell.dismissProfile() }"))
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
