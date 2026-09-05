import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell

/// Hosting a match from the menu: the code, the roster, Start and Cancel.
///
/// Everything here drives the real entry points — `ShellModel.playAFriend()`,
/// `HostLobbyModel.start()`, `HostLobbyModel.cancel()` — rather than
/// re-deriving what they would have done from the façade underneath. A cancel
/// that abandoned the row only because the test called `leave()` itself would
/// prove nothing about the button.
@MainActor
@Suite("Host lobby")
struct HostLobbyTests {

    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal

    /// A wire whose presence stream the test drives, and which records that it
    /// was left.
    ///
    /// `FakeTransport.pair` cannot stand in here: it buffers a `.connected` for
    /// the peer on both endpoints before it returns, so a lobby built over it
    /// holds two players from the first frame and "canStart flips only after a
    /// second player arrives" is unfalsifiable.
    final class LobbyWire: MatchTransport, @unchecked Sendable {

        let localPlayerID: PlayerID
        let inboundMessages: AsyncStream<MatchMessage>
        let peerConnectionStates: AsyncStream<PeerConnectionState>

        private let inbound: AsyncStream<MatchMessage>.Continuation
        private let states: AsyncStream<PeerConnectionState>.Continuation
        private let lock = NSLock()
        private var leaves = 0
        private var outbound: [MatchMessage] = []

        /// Whether the channel has been torn down, and what went out on it.
        var hasLeft: Bool { lock.withLock { leaves > 0 } }
        var sent: [MatchMessage] { lock.withLock { outbound } }

        init(localPlayerID: PlayerID) {
            self.localPlayerID = localPlayerID
            let messages = AsyncStream.makeStream(
                of: MatchMessage.self, bufferingPolicy: .unbounded)
            let presence = AsyncStream.makeStream(
                of: PeerConnectionState.self, bufferingPolicy: .unbounded)
            inboundMessages = messages.stream
            inbound = messages.continuation
            peerConnectionStates = presence.stream
            states = presence.continuation
        }

        /// The test's hand on the lobby: a peer arriving, or going.
        func announce(_ state: PeerConnectionState) { states.yield(state) }

        func send(_ message: MatchMessage, delivery: MatchDelivery) async throws {
            lock.withLock { outbound.append(message) }
        }

        func leave() {
            lock.withLock { leaves += 1 }
            inbound.finish()
            states.finish()
        }
    }

    /// A shell signed in as the host, over a fake backend whose one transport is
    /// ``LobbyWire``.
    struct Fixture {
        let backend: FakeBackend
        let shell: ShellModel
        let wire: LobbyWire
        let host: Profile
        let guest: Profile
    }

    /// The token `FakeBackend: ShellSignIn` signs the shell in with. Declared
    /// here so the fixture can create that profile before the model exists.
    static let hostToken = "shell-tests"

    /// Builds the two profiles, then the model.
    ///
    /// The guest is chosen so its id sorts *after* the host's: `OnlineMatch`
    /// elects `roster[0]`, so this is what makes "the local player is host" a
    /// real assertion rather than a coin toss. `FakeBackend` derives a stable
    /// id from the token, so the search is deterministic run to run.
    static func make(
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = { _ in }
    ) async throws -> Fixture {
        let backend = FakeBackend()
        let host = try await backend.signInWithApple(idToken: hostToken, nonce: hostToken)

        var found: Profile?
        for index in 0..<64 where found == nil {
            let candidate = try await backend.signInWithApple(
                idToken: "zz-lobby-guest-\(index)", nonce: "n")
            if candidate.playerID.rawValue > host.playerID.rawValue { found = candidate }
        }
        let guest = try #require(found, "no fake token sorted after the host's")

        let wire = LobbyWire(localPlayerID: host.playerID)
        await backend.setTransportFactory { _, _ in wire }

        let shell = ShellModel(
            dictionary: { EveryWordIsReal() },
            sleepFor: sleepFor,
            services: ShellServices(backend: backend, signIn: backend)
        )
        await shell.signInTask?.value
        #expect(shell.currentProfile?.id == host.id)
        return Fixture(backend: backend, shell: shell, wire: wire, host: host, guest: guest)
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

    // MARK: - done when 1

    @Test("Play a Friend opens a lobby, shows a six-character code, and waits for a second player")
    func hostingPublishesACodeAndWaitsForASecondPlayer() async throws {
        let f = try await Self.make()

        #expect(f.shell.canPlayOnline)
        #expect(f.shell.playAFriend())
        #expect(f.shell.route == .hostLobby)

        let lobby = try #require(f.shell.hostLobby)
        #expect(lobby.phase == .creating)

        await Self.until("the lobby exists") { lobby.phase == .waiting }
        let code = try #require(lobby.inviteCode)
        #expect(code.count == 6)
        #expect(code.allSatisfy { $0.isUppercase || $0.isNumber })

        // One player, who is this device, named from the profile already in hand.
        #expect(lobby.roster == [f.host.displayName])
        #expect(lobby.canStart == false)
        #expect(lobby.message == nil)

        f.wire.announce(.connected(f.guest.playerID))
        await Self.until("the guest is in the lobby") { lobby.canStart }
        await Self.until("the guest is named") { lobby.roster.count == 2 && !lobby.roster.contains(HostLobbyModel.pendingName) }
        #expect(lobby.roster == [f.host.displayName, f.guest.displayName])

        f.shell.returnToMenu()
    }

    @Test("Play a Friend is refused with no signed-in profile")
    func hostingNeedsAProfile() async throws {
        let shell = ShellModel(sleepFor: { _ in })
        #expect(shell.canPlayOnline == false)
        #expect(shell.playAFriend() == false)
        #expect(shell.route == .menu)
        #expect(shell.hostLobby == nil)
    }

    // MARK: - done when 2

    @Test("Start on a two-player lobby moves to the countdown over a two-player session")
    func startingOpensTheMatch() async throws {
        // A countdown that is still running when the route is read: with an
        // instant tick the session can reach `.playing` between `install` and
        // the assertion, and `.countdown` is what this criterion is about. The
        // teardown at the end cancels it, so nothing outlives the test.
        let f = try await Self.make(sleepFor: { _ in try await Task.sleep(for: .milliseconds(500)) })

        #expect(f.shell.playAFriend())
        let lobby = try #require(f.shell.hostLobby)
        await Self.until("the lobby exists") { lobby.phase == .waiting }

        f.wire.announce(.connected(f.guest.playerID))
        await Self.until("two in the lobby") { lobby.canStart }

        lobby.start()
        await Self.until("the run is installed") { f.shell.run != nil }

        guard case .countdown(let setup) = f.shell.route else {
            Issue.record("route is \(f.shell.route), not the countdown")
            return
        }
        #expect(setup.startingHandSize == OnlineMatch.startingHandSize)
        #expect(setup.countdownSeconds == OnlineMatch.countdownSeconds)

        let run = try #require(f.shell.run)
        let roster = run.session.roster
        #expect(roster.count == 2)
        #expect(roster == [f.host.playerID, f.guest.playerID])
        #expect(run.session.localPlayerID == f.host.playerID)
        // The election `OnlineMatch` ran, read back off the session it built:
        // the shell never picked a host.
        #expect(HostPool.host(of: roster) == f.host.playerID)
        // And it really is the online opponent, not a solo run.
        #expect(run.opponent is OnlineOpponent)

        // The lobby handed the façade over rather than keeping it: a teardown
        // here must not end the match that just began.
        #expect(lobby.match === nil)

        f.shell.returnToMenu()
        #expect(f.wire.hasLeft)
    }

    // MARK: - done when 3

    @Test("Cancel leaves the channel, abandons the row and returns to the menu")
    func cancellingAbandonsTheRow() async throws {
        let f = try await Self.make()

        #expect(f.shell.playAFriend())
        let lobby = try #require(f.shell.hostLobby)
        await Self.until("the lobby exists") { lobby.phase == .waiting }

        let matchID = try #require(lobby.match?.record.id)
        #expect(await f.backend.matchRecord(matchID)?.status == .lobby)

        lobby.cancel()

        // Synchronously, before anything else: no live channel survives a cancel.
        #expect(f.wire.hasLeft)
        #expect(f.shell.route == .menu)
        #expect(f.shell.hostLobby == nil)

        await Self.until("the row is abandoned") {
            await f.backend.matchRecord(matchID)?.status == .abandoned
        }
    }

    /// The guardrail's *ordering* half, which the cancel case above cannot see:
    /// both halves land in one main-actor turn, so only an observer woken by the
    /// route change can tell whether the channel was already gone when it moved.
    ///
    /// `withObservationTracking`'s `onChange` fires on `willSet` — the instant
    /// before `route` becomes `.menu` — so a teardown that ran after the route
    /// assignment would be caught here with `hasLeft` still false.
    @Test("The channel is gone before the route leaves the lobby")
    func teardownPrecedesTheRouteMove() async throws {
        let f = try await Self.make()

        #expect(f.shell.playAFriend())
        let lobby = try #require(f.shell.hostLobby)
        await Self.until("the lobby exists") { lobby.phase == .waiting }

        nonisolated(unsafe) var leftWhenTheRouteMoved: Bool?
        nonisolated(unsafe) var lobbyWhenTheRouteMoved: HostLobbyModel?
        let wire = f.wire
        let shell = f.shell
        withObservationTracking {
            _ = shell.route
        } onChange: {
            leftWhenTheRouteMoved = wire.hasLeft
            lobbyWhenTheRouteMoved = MainActor.assumeIsolated { shell.hostLobby }
        }

        lobby.cancel()

        #expect(leftWhenTheRouteMoved == true)
        #expect(lobbyWhenTheRouteMoved == nil)
        #expect(f.shell.route == .menu)
    }

    // MARK: - The error copy

    @Test("Every lobby failure is one line of copy, never an error and never a silent exit")
    func failuresBecomeCopy() {
        let errors: [any Error] = [
            OnlineMatchError.lobbyNotReady(1),
            OnlineMatchError.notAuthenticated,
            BackendError.offline,
            BackendError.notFound,
            BackendError.matchFull,
            BackendError.permissionDenied,
            BackendError.notAuthenticated,
            BackendError.alreadyExists,
            BackendError.blocked,
        ]
        var seen: Set<String> = []
        for error in errors {
            let message = HostLobbyModel.message(for: error)
            #expect(!message.isEmpty, "\(error) mapped to nothing")
            #expect(!message.contains("Error"), "\(error) leaked its case name")
            seen.insert(message)
        }
        // Not one line for everything: a screen that says the same thing about
        // an empty lobby and a dead network is not saying anything.
        #expect(seen.count >= 4)
    }

    @Test("A backend that refuses to create leaves the lobby failed, with copy, on the screen")
    func aRefusedCreateStaysOnTheScreen() async throws {
        let f = try await Self.make()
        // Signed out from under the model: `createMatch` then throws
        // the façade turns that into `OnlineMatchError.notAuthenticated`, which
        // is the shape a refused create reaches this model in.
        try await f.backend.signOut()

        #expect(f.shell.playAFriend())
        let lobby = try #require(f.shell.hostLobby)
        await Self.until("the create failed") { lobby.phase == .failed }

        #expect(lobby.inviteCode == nil)
        #expect(lobby.canStart == false)
        #expect(lobby.message == HostLobbyModel.message(for: OnlineMatchError.notAuthenticated))
        // Never a silent return to the menu.
        #expect(f.shell.route == .hostLobby)

        f.shell.returnToMenu()
    }
}
