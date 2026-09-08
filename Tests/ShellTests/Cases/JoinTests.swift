import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell

/// Joining a match by invite code: the field, the wait, the match, and the two
/// ways it can go wrong.
///
/// Everything here drives the real entry points — `ShellModel.showJoin()`,
/// `JoinModel.join()`, `JoinModel.cancel()` — over a real `OnlineMatch` on the
/// host's side. The host is a second façade on the same `FakeBackend` with its
/// own wire, linked to the guest's, so "the host pressed Start" is an actual
/// `.start` crossing a channel rather than a flag this test set.
@MainActor
@Suite("Join by code")
struct JoinTests {

    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal
    typealias LobbyWire = HostLobbyTests.LobbyWire

    /// A host lobby that already exists, and a shell signed in as the guest.
    struct Fixture {
        let backend: FakeBackend
        let shell: ShellModel
        let hostMatch: OnlineMatch
        let hostWire: LobbyWire
        let guestWire: LobbyWire
        let host: Profile
        let guest: Profile

        @MainActor var code: String { hostMatch.inviteCode }
    }

    /// Builds the host's lobby first, then the guest's shell.
    ///
    /// The host token is chosen so its id sorts *before* the guest's:
    /// `OnlineMatch` elects `roster[0]`, and the criterion is that the host is
    /// the one elected. `FakeBackend` derives a stable id from the token, so the
    /// search is deterministic run to run.
    ///
    /// Order is load-bearing. `FakeBackend` holds one session, so the lobby has
    /// to be created while the host is the signed-in user; `ShellModel`'s own
    /// sign-in then switches it to the guest, which is who joins.
    static func make(
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = { _ in }
    ) async throws -> Fixture {
        let backend = FakeBackend()
        // The token `FakeBackend: ShellSignIn` uses — the guest is whoever the
        // shell will sign in as.
        let guest = try await backend.signIn()

        var found: Profile?
        for index in 0..<64 where found == nil {
            let candidate = try await backend.signInWithApple(
                idToken: "join-host-\(index)", nonce: "n")
            if candidate.playerID.rawValue < guest.playerID.rawValue { found = candidate }
        }
        let host = try #require(found, "no fake token sorted before the guest's")

        let hostWire = LobbyWire(localPlayerID: host.playerID)
        let guestWire = LobbyWire(localPlayerID: guest.playerID)
        hostWire.peer = guestWire
        guestWire.peer = hostWire
        let hostID = host.playerID
        await backend.setTransportFactory { _, player in
            player == hostID ? hostWire : guestWire
        }

        // Signed in as the host, because the candidate search left it that way.
        let hostMatch = try await OnlineMatch.host(
            options: .standard,
            backend: backend,
            dictionary: EveryWordIsReal(),
            sleepFor: sleepFor
        )

        let shell = ShellModel(
            dictionary: { EveryWordIsReal() },
            sleepFor: sleepFor,
            services: ShellServices(backend: backend, signIn: backend)
        )
        await shell.signInTask?.value
        #expect(shell.currentProfile?.id == guest.id)

        return Fixture(
            backend: backend, shell: shell, hostMatch: hostMatch,
            hostWire: hostWire, guestWire: guestWire, host: host, guest: guest
        )
    }

    /// Yields until `condition` holds. Scheduler turns, never a clock.
    static func until(
        _ label: String, _ condition: @MainActor () async -> Bool
    ) async {
        for _ in 0..<20_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("timed out waiting for: \(label)")
    }

    /// Opens the join screen and joins `f.code`, leaving the model waiting.
    static func joinTheLobby(_ f: Fixture) async throws -> JoinModel {
        #expect(f.shell.showJoin())
        #expect(f.shell.route == .join)
        let model = try #require(f.shell.join)
        model.code = f.code
        model.join()
        await until("the guest is waiting") { model.phase == .waiting }
        return model
    }

    // MARK: - done when 1

    @Test("Entering a live lobby's code reaches the waiting state and writes the membership row")
    func joiningReachesTheWaitingState() async throws {
        let f = try await Self.make()

        let model = try await Self.joinTheLobby(f)
        #expect(model.waitingLine.contains(JoinModel.waitingTitle))
        #expect(model.message == nil)
        #expect(f.shell.route == .join)

        // `match_players` shows the joiner — the row the real backend's RLS
        // policy is written about.
        let rows = try await f.backend.players(inMatch: f.hostMatch.record.id)
        #expect(rows.count == 2)
        #expect(rows.contains { $0.playerID == f.guest.id })
        #expect(rows.contains { $0.playerID == f.host.id })

        // The host is named on the waiting screen, read from the profile row.
        await Self.until("the host is named") { model.hostName != nil }
        #expect(model.hostName == f.host.displayName)
        #expect(model.waitingLine.contains(f.host.displayName))

        f.shell.returnToMenu()
    }

    // MARK: - done when 2

    @Test("A code that matches no match is one line beside the field, and the route stays put")
    func aWrongCodeStaysOnTheScreen() async throws {
        let f = try await Self.make()

        #expect(f.shell.showJoin())
        let model = try #require(f.shell.join)
        // Six characters, well-formed, and nobody's lobby.
        model.code = "ZZZZZZ"
        #expect(model.code != f.code, "the fixture's own code was used as the wrong one")
        #expect(model.canJoin)
        model.join()

        await Self.until("the join failed") { model.message != nil }
        #expect(model.message == HostLobbyModel.message(for: BackendError.notFound))
        #expect(model.phase == .entering)
        #expect(f.shell.route == .join)
        #expect(f.shell.run == nil)
        #expect(f.guestWire.hasLeft == false, "a join that never opened a channel left one")

        // Still typeable: the screen is not a dead end.
        #expect(model.canJoin)

        f.shell.returnToMenu()
    }

    @Test("A full or started match, and offline, each reach the field as copy")
    func everyJoinFailureIsCopy() {
        let errors: [any Error] = [
            BackendError.notFound,
            BackendError.matchFull,
            BackendError.permissionDenied,
            BackendError.offline,
        ]
        var seen: Set<String> = []
        for error in errors {
            let message = HostLobbyModel.message(for: error)
            #expect(!message.isEmpty, "\(error) mapped to nothing")
            #expect(!message.contains("Error"), "\(error) leaked its case name")
            seen.insert(message)
        }
        // Not one line for all four: a screen that says the same thing about a
        // wrong code and a dead network is not saying anything.
        #expect(seen.count >= 3)
    }

    /// The other half of the criterion, which the mapping test above cannot
    /// reach: an error that is *not* `.notFound` has to travel the same path out
    /// of `join()` and land beside the field. Proven at the model, on the real
    /// entry point, for every case the item names.
    @Test(
        "A full match, a started match and a dead network each land beside the field",
        arguments: [BackendError.matchFull, .permissionDenied, .offline]
    )
    func everyJoinFailureReachesTheField(_ error: BackendError) async throws {
        let f = try await Self.make()
        let refusing = RefusingJoin(wrapping: f.backend, throwing: error)
        let shell = ShellModel(
            dictionary: { EveryWordIsReal() },
            sleepFor: { _ in },
            services: ShellServices(backend: refusing, signIn: f.backend)
        )
        await shell.signInTask?.value

        #expect(shell.showJoin())
        let model = try #require(shell.join)
        model.code = f.code
        model.join()

        await Self.until("the join failed") { model.message != nil }
        #expect(model.message == HostLobbyModel.message(for: error))
        #expect(model.message != HostLobbyModel.message(for: BackendError.notFound))
        #expect(model.phase == .entering)
        #expect(shell.route == .join)
        #expect(shell.run == nil)
        #expect(model.canJoin, "the screen is a dead end after a refusal")

        shell.returnToMenu()
        f.hostMatch.leave()
    }

    // MARK: - done when 3

    @Test("The host pressing Start carries the guest to the countdown over the host's session")
    func theHostStartingOpensTheGuestsMatch() async throws {
        // A countdown still running when the route is read: with an instant tick
        // the session can reach `.playing` between `install` and the assertion,
        // and `.countdown` is what this criterion is about.
        let f = try await Self.make(
            sleepFor: { _ in try await Task.sleep(for: .milliseconds(500)) })

        let model = try await Self.joinTheLobby(f)
        // The guest is in, and has not been carried anywhere yet: the host has
        // not pressed Start. Given turns to do it in, so this is the wait
        // holding rather than the assertion arriving first — `awaitStart()`
        // returns as soon as the membership rows are in, and a model that took
        // that for the start would have moved by now.
        for _ in 0..<500 { await Task.yield() }
        #expect(f.shell.route == .join, "the guest walked in before the host started")
        #expect(f.shell.run == nil)
        #expect(model.phase == .waiting)

        // The host's side, driven through the real façade.
        f.hostWire.announce(.connected(f.guest.playerID))
        await Self.until("two in the host's lobby") { f.hostMatch.lobby.count == 2 }
        let hostSession = try await f.hostMatch.start()

        await Self.until("the guest left the join screen") { f.shell.route != .join }

        guard case .countdown(let setup) = f.shell.route else {
            Issue.record("route is \(f.shell.route), not the countdown")
            return
        }
        #expect(setup.seed == f.hostMatch.record.poolSeed)
        #expect(setup.startingHandSize == OnlineMatch.startingHandSize)
        #expect(setup.countdownSeconds == OnlineMatch.countdownSeconds)

        let run = try #require(f.shell.run)
        let roster = run.session.roster
        #expect(roster == [f.host.playerID, f.guest.playerID])
        #expect(roster == hostSession.roster, "the two devices disagree about the roster")
        // The host is `roster[0]`, as `OnlineMatch` elected it — the shell never
        // decided who hosts.
        #expect(HostPool.host(of: roster) == f.host.playerID)
        // And this device is the guest, not the host.
        #expect(run.session.localPlayerID == f.guest.playerID)
        #expect(run.opponent is OnlineOpponent)

        // The screen handed the façade over rather than keeping it: a teardown
        // must not end the match that just began.
        #expect(model.match == nil)
        #expect(model.session == nil)
        #expect(f.shell.join == nil)
        #expect(f.guestWire.hasLeft == false)

        f.shell.returnToMenu()
        #expect(f.guestWire.hasLeft)
    }

    // MARK: - guardrail: the field accepts only [A-Z0-9], length 6

    @Test("The field keeps only six [A-Z0-9], uppercased")
    func theFieldClampsWhatItHolds() {
        #expect(JoinModel.sanitised(" ab-3d9zq! ") == "AB3D9Z")
        #expect(JoinModel.sanitised("abc123") == "ABC123")
        #expect(JoinModel.sanitised("ABCDEFGHIJ") == "ABCDEF")
        #expect(JoinModel.sanitised("é🙂 a1") == "A1")
        #expect(JoinModel.sanitised("") == "")
    }

    @Test("A code that is not six characters makes no backend call")
    func aShortCodeNeverReachesTheNetwork() async throws {
        let f = try await Self.make()

        #expect(f.shell.showJoin())
        let model = try #require(f.shell.join)

        model.code = "  ab-1 "
        // The clamp ran on the way in, not on the way out.
        #expect(model.code == "AB1")
        #expect(model.canJoin == false)

        model.join()
        #expect(model.message == JoinModel.shortCodeMessage)
        #expect(model.phase == .entering)
        // The negative side effect, read off the fake rather than re-derived:
        // no membership row, no channel, no task.
        #expect(model.work == nil)
        let rows = try await f.backend.players(inMatch: f.hostMatch.record.id)
        #expect(rows.count == 1, "a short code reached joinMatch")
        #expect(f.guestWire.hasLeft == false)

        // Typing the rest clears the refusal and arms the button.
        model.code = "AB1234"
        #expect(model.message == nil)
        #expect(model.canJoin)

        f.shell.returnToMenu()
    }

    // MARK: - guardrail: no orphaned task, no live channel after the route moves

    /// The ordering half, which a state check after the call cannot see: both
    /// halves land in one main-actor turn, so only an observer woken by the
    /// route change can tell whether the join was already cancelled when it
    /// moved. `withObservationTracking`'s `onChange` fires on `willSet` — the
    /// instant before `route` becomes `.menu`.
    @Test("The join in flight is already cancelled when the route leaves the screen")
    func cancellingMidJoinCancelsTheTask() async throws {
        let f = try await Self.make()

        #expect(f.shell.showJoin())
        let model = try #require(f.shell.join)
        model.code = f.code
        model.join()

        // The task exists and has not run yet — a `Task { }` on the main actor
        // starts on a later turn, so this cancel lands mid-join by construction.
        let task = try #require(model.work, "join() started no task")
        #expect(model.phase == .joining)

        nonisolated(unsafe) var cancelledWhenTheRouteMoved: Bool?
        nonisolated(unsafe) var screenWhenTheRouteMoved: JoinModel?
        let shell = f.shell
        withObservationTracking {
            _ = shell.route
        } onChange: {
            cancelledWhenTheRouteMoved = task.isCancelled
            screenWhenTheRouteMoved = MainActor.assumeIsolated { shell.join }
        }

        model.cancel()

        #expect(cancelledWhenTheRouteMoved == true)
        #expect(screenWhenTheRouteMoved == nil)
        #expect(f.shell.route == .menu)

        // Cancellation is cooperative, so the join it had already issued does
        // land — and the façade it produced closes its own channel rather than
        // being left subscribed behind the menu.
        await task.value
        await Self.until("the orphaned channel is gone") { f.guestWire.hasLeft }
        #expect(f.shell.route == .menu)
        #expect(f.shell.run == nil)
    }

    @Test("Cancelling while waiting closes the channel before the route moves, and the host cannot start it after")
    func cancellingWhileWaitingLeavesNothingSubscribed() async throws {
        let f = try await Self.make()

        _ = try await Self.joinTheLobby(f)
        #expect(f.guestWire.hasLeft == false)

        nonisolated(unsafe) var leftWhenTheRouteMoved: Bool?
        let wire = f.guestWire
        let shell = f.shell
        withObservationTracking {
            _ = shell.route
        } onChange: {
            leftWhenTheRouteMoved = wire.hasLeft
        }

        f.shell.join?.cancel()

        #expect(leftWhenTheRouteMoved == true)
        #expect(f.shell.route == .menu)
        #expect(f.shell.join == nil)

        // No observer survived the cancel: the host opening the match behind
        // the menu moves nothing.
        f.hostWire.announce(.connected(f.guest.playerID))
        await Self.until("two in the host's lobby") { f.hostMatch.lobby.count == 2 }
        _ = try await f.hostMatch.start()
        for _ in 0..<500 { await Task.yield() }
        #expect(f.shell.route == .menu)
        #expect(f.shell.run == nil)

        f.hostMatch.leave()
    }

    // MARK: - The seam

    @Test("Join is refused with no signed-in profile")
    func joiningNeedsAProfile() async throws {
        let shell = ShellModel(sleepFor: { _ in })
        #expect(shell.canPlayOnline == false)
        #expect(shell.showJoin() == false)
        #expect(shell.route == .menu)
        #expect(shell.join == nil)
    }

    /// `ShellRootView` is SwiftUI and cannot be constructed on macOS, so the
    /// route reaching a real screen is checked against the bytes on disk — the
    /// same approach `ShellRootViewTests` takes. The names are asserted present,
    /// so a rename turns this red rather than vacuously green.
    @Test("The join route renders JoinView, and the menu has a way in")
    func theRouteIsWired() throws {
        let shell = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ShellSrc")
            .resolvingSymlinksInPath()

        let root = try String(
            contentsOf: shell.appendingPathComponent("ShellRootView.swift"), encoding: .utf8)
        #expect(root.contains("case .join:"), "no .join case in ShellRootView")
        #expect(root.contains("JoinView("), "no JoinView in ShellRootView")

        let menu = try String(
            contentsOf: shell.appendingPathComponent("MenuView.swift"), encoding: .utf8)
        #expect(menu.contains("shell.showJoin()"), "no way onto the join screen from the menu")
        #expect(menu.contains("JoinModel.title"), "the menu's join action is unlabelled")

        // The View is excluded, or this package stops building for macOS.
        let manifest = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(manifest.contains("\"JoinView.swift\""))
    }
}

/// A `FakeBackend` that refuses `joinMatch` with one chosen error and forwards
/// everything else. The only way to drive `.matchFull` and `.offline` through
/// the real entry point: the fake reaches the first only with six members and
/// the second never.
private actor RefusingJoin: BackendClient {
    private let inner: FakeBackend
    private let error: BackendError

    init(wrapping inner: FakeBackend, throwing error: BackendError) {
        self.inner = inner
        self.error = error
    }

    func joinMatch(inviteCode: String) async throws -> MatchRecord { throw error }

    var currentUserID: UUID? { get async { await inner.currentUserID } }
    func signInWithApple(idToken: String, nonce: String) async throws -> Profile {
        try await inner.signInWithApple(idToken: idToken, nonce: nonce)
    }
    func signOut() async throws { try await inner.signOut() }
    func profile(id: UUID) async throws -> Profile { try await inner.profile(id: id) }
    func profile(friendCode: String) async throws -> Profile? {
        try await inner.profile(friendCode: friendCode)
    }
    func updateDisplayName(_ name: String) async throws -> Profile {
        try await inner.updateDisplayName(name)
    }
    func friendships() async throws -> [Friendship] { try await inner.friendships() }
    func requestFriend(addresseeID: UUID) async throws -> Friendship {
        try await inner.requestFriend(addresseeID: addresseeID)
    }
    func respondToFriendRequest(requesterID: UUID, accept: Bool) async throws -> Friendship {
        try await inner.respondToFriendRequest(requesterID: requesterID, accept: accept)
    }
    func block(_ playerID: UUID) async throws -> Friendship { try await inner.block(playerID) }
    func createMatch(options: MatchOptions, seed: Int64) async throws -> MatchRecord {
        try await inner.createMatch(options: options, seed: seed)
    }
    func players(inMatch matchID: UUID) async throws -> [MatchPlayerRow] {
        try await inner.players(inMatch: matchID)
    }
    func transport(for match: MatchRecord, as player: PlayerID) async throws -> any MatchTransport {
        try await inner.transport(for: match, as: player)
    }
}
