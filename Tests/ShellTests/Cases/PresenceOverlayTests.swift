import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell
@testable import Style

/// What a peer's absence does to the three match-side screens: the board is
/// covered and frozen while they may still come back, the match ends when they
/// do not, and the end screen it lands on says so and offers only the way home.
///
/// Every case here drives a real `MatchSession` over a transport double whose
/// *only* extra power is pushing one connection-state change at a time. Nothing
/// is pre-buffered and no presence is written into the session by hand, so a
/// model that stopped reading presence cannot stay green.
@MainActor
@Suite("Presence overlay and departure")
struct PresenceOverlayTests {

    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal

    static let localID = PlayerID(rawValue: "aaa")
    static let peerID = PlayerID(rawValue: "zzz")

    // MARK: - The doubles

    /// A transport with one hook: the test says when the peer drops and when it
    /// comes back.
    ///
    /// Deliberately *not* `FakeTransport`. That one buffers `.connected` on
    /// both endpoints before `pair` returns and its `leave()` finishes both
    /// streams, so a peer that dropped could never be reported back — a return
    /// is unobservable there, and "the overlay clears" would be vacuous.
    /// Nothing is announced here until a test announces it.
    final class PresenceWire: MatchTransport {

        let localPlayerID: PlayerID
        let inboundMessages: AsyncStream<MatchMessage>
        let peerConnectionStates: AsyncStream<PeerConnectionState>

        private let inbound: AsyncStream<MatchMessage>.Continuation
        private let states: AsyncStream<PeerConnectionState>.Continuation

        init(localPlayerID: PlayerID) {
            self.localPlayerID = localPlayerID
            let inbound = AsyncStream.makeStream(
                of: MatchMessage.self, bufferingPolicy: .unbounded)
            let states = AsyncStream.makeStream(
                of: PeerConnectionState.self, bufferingPolicy: .unbounded)
            self.inboundMessages = inbound.stream
            self.peerConnectionStates = states.stream
            self.inbound = inbound.continuation
            self.states = states.continuation
        }

        /// Into the void: there is no peer process, and nothing here asserts on
        /// what was sent.
        func send(_ message: MatchMessage, delivery: MatchDelivery) async throws {}

        func leave() {
            inbound.finish()
            states.finish()
        }

        /// The hook. One change, when the test says so.
        func announce(_ state: PeerConnectionState) { states.yield(state) }
    }

    /// A far end that is a real host-side session on a ``PresenceWire``.
    final class WiredOpponent: MatchOpponent {

        let session: MatchSession
        let wire: PresenceWire
        private let setup: MatchSetup

        init(
            setup: MatchSetup,
            dictionary: some WordList,
            sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void
        ) {
            self.setup = setup
            let wire = PresenceWire(localPlayerID: PresenceOverlayTests.localID)
            self.wire = wire
            self.session = MatchSession(
                transport: wire,
                peerPlayerID: PresenceOverlayTests.peerID,
                dictionary: dictionary,
                // Never a wall clock: a leaked countdown aborts the whole test
                // process in `MatchSession.deinit`.
                sleepFor: sleepFor
            )
        }

        func start() {
            session.startMatch(
                seed: setup.seed,
                startingHandSize: setup.startingHandSize,
                countdownSeconds: setup.countdownSeconds,
                options: setup.options
            )
        }

        func leave() { session.leave() }
    }

    static let setup = MatchSetup(seed: 5_150, startingHandSize: 4, countdownSeconds: 0)

    /// A clock that answers the countdown at once and *holds* the reconnect
    /// window open until the test releases it.
    ///
    /// The two are told apart by the duration `MatchSession` asks for — one
    /// second per countdown tick, `reconnectGraceSeconds` for the window — so a
    /// peer stays `.reconnecting` for as long as the test needs to look at it,
    /// with no wall clock anywhere.
    static func heldGrace() -> (
        clock: @MainActor @Sendable (Duration) async throws -> Void, release: () -> Void
    ) {
        let gate = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .unbounded)
        let stream = gate.stream
        return (
            clock: { duration in
                guard duration == .seconds(MatchSession.reconnectGraceSeconds) else { return }
                for await _ in stream {}
            },
            release: { gate.continuation.finish() }
        )
    }

    static func shell(
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = { _ in }
    ) -> ShellModel {
        ShellModel(dictionary: { EveryWordIsReal() }, sleepFor: sleepFor)
    }

    /// A live match over a ``WiredOpponent``, dealt and playing.
    static func playing(
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void
    ) async throws -> (shell: ShellModel, run: MatchRun, opponent: WiredOpponent) {
        let shell = Self.shell()
        var made: WiredOpponent?
        #expect(
            shell.startMatch(Self.setup) {
                let opponent = WiredOpponent(
                    setup: Self.setup, dictionary: EveryWordIsReal(), sleepFor: sleepFor)
                made = opponent
                return opponent
            })
        let opponent = try #require(made)
        let run = try #require(shell.run)
        try await SoloMatchTests.waitUntil("the opening deal to be laid") {
            run.board.board.placementList.count == Self.setup.startingHandSize
        }
        try await SoloMatchTests.waitUntil("the shell to reach the match screen") {
            shell.route == .match(Self.setup)
        }
        return (shell, run, opponent)
    }

    // MARK: - done when 1

    @Test("A reconnecting peer covers the board and locks it, and a returning one clears both")
    func aReconnectingPeerCoversAndLocksTheBoard() async throws {
        let grace = Self.heldGrace()
        let (shell, run, opponent) = try await Self.playing(sleepFor: grace.clock)

        // Nothing covers a board whose peer is here.
        #expect(run.board.overlay == nil)
        #expect(run.board.inputLocked == false)

        opponent.wire.announce(.disconnected(Self.peerID))
        try await SoloMatchTests.waitUntil("the peer to be reported away") {
            run.board.overlay != nil
        }

        // Named, and named from the session's own roster rather than a literal
        // the model kept.
        #expect(run.board.overlay == .reconnecting(peer: Self.peerID.rawValue))
        #expect(run.board.inputLocked, "the board is playable under the overlay")
        // Still a live match: the window has not run out, so this is a freeze
        // and not an ending.
        #expect(shell.route == .match(Self.setup))

        opponent.wire.announce(.connected(Self.peerID))
        try await SoloMatchTests.waitUntil("the peer to be reported back") {
            run.board.overlay == nil
        }
        #expect(run.board.inputLocked == false)
        #expect(shell.route == .match(Self.setup))

        grace.release()
        shell.returnToMenu()
    }

    // MARK: - The guardrail: never in a solo match

    @Test("A solo match is never covered by the overlay")
    func soloIsNeverCovered() async throws {
        let shell = Self.shell()
        #expect(shell.startSoloPractice())
        let run = try #require(shell.run)

        try await SoloMatchTests.waitUntil("the opening deal to be laid") {
            run.board.board.placementList.count == ShellModel.soloHandSize
        }
        try await SoloMatchTests.waitUntil("the shell to reach the match screen") {
            if case .match = shell.route { return true }
            return false
        }

        // The bot is a peer that never drops, so nothing here can ever be true —
        // and the board stays playable for the whole of it.
        for _ in 0..<200 {
            #expect(run.board.overlay == nil)
            #expect(run.board.inputLocked == false)
            #expect(run.session.presence(of: run.session.roster[1]) == .present)
            await Task.yield()
        }

        shell.returnToMenu()
    }

    // MARK: - done when 2

    @Test("A peer that does not come back ends the match on the results screen, naming no winner")
    func aDepartedPeerEndsTheMatchOnResults() async throws {
        // An instant clock: the reconnect window runs out the moment it opens.
        let (shell, run, opponent) = try await Self.playing(sleepFor: { _ in })
        #expect(shell.route == .match(Self.setup))

        opponent.wire.announce(.disconnected(Self.peerID))
        try await SoloMatchTests.waitUntil("the shell to end the match itself") {
            shell.route == .results(winner: nil)
        }

        #expect(run.session.isMatchOver)
        #expect(run.session.winner == nil)
        #expect(run.session.presence(of: Self.peerID) == .gone)

        // The production entry point, not a headline helper: this is the very
        // `ResultsModel` `ShellRootView` renders for this run.
        let results = run.results()
        #expect(results.outcome == .noWinner)
        #expect(results.headline == "Opponent left")
        // And it is not a scoreboard line. The player is told the reason.
        #expect(results.headline != ResultsModel.peerWinHeadline)
        #expect(results.headline != Terminology.winCall)

        shell.returnToMenu()
    }

    // MARK: - done when 3

    @Test("An online run offers no rematch action at all; a solo run still does")
    func onlineResultsOfferOnlyTheWayHome() async throws {
        // The real thing: a real `OnlineMatch` over `FakeBackend`, wrapped as
        // the `OnlineOpponent` the lobby builds, reached through the lobby's own
        // Start — not a double that merely claims to be online.
        let f = try await HostLobbyTests.make()
        #expect(f.shell.playAFriend())
        let lobby = try #require(f.shell.hostLobby)
        await HostLobbyTests.until("the lobby exists") { lobby.phase == .waiting }
        f.wire.announce(.connected(f.guest.playerID))
        await HostLobbyTests.until("two in the lobby") { lobby.canStart }
        lobby.start()
        await HostLobbyTests.until("the run is installed") { f.shell.run != nil }

        let online = try #require(f.shell.run)
        #expect(online.opponent is OnlineOpponent, "this fixture stopped being online")
        #expect(online.opponent.offersRematch == false)
        #expect(
            online.results().isRematchEnabled == false,
            "an online end screen offered a rematch it cannot build")
        f.shell.returnToMenu()

        // Solo is unchanged.
        let shell = Self.shell()
        #expect(shell.startSoloPractice())
        let solo = try #require(shell.run)
        #expect(solo.opponent.offersRematch)
        #expect(solo.results().isRematchEnabled)
        shell.returnToMenu()
    }

    // MARK: - The guardrail: presence is read, never stored again

    /// Presence lives in `MatchSession` and nowhere else.
    ///
    /// Behaviourally invisible, and that is the point: a `MatchBoard` that
    /// mirrored `presence(of:)` into a stored property and refreshed it from
    /// its own observation callback passes every other case in this file. It is
    /// still the defect the lane's toolchain rule is about — a second copy of
    /// presence that can disagree with the session's, on the one path the
    /// Swift 6.3.3 limit already makes fragile — so it is fenced here, against
    /// the bytes on disk.
    ///
    /// Falsifiable: the computed spellings it requires must be present, so
    /// renaming `overlay` or dropping the `presence(of:)` read fails here
    /// rather than passing vacuously.
    @Test("The overlay is computed off the session, never mirrored into the shell")
    func presenceIsNeverStoredInTheShell() throws {
        let text = try String(
            contentsOf: MatchHUDTests.shellSource("MatchBoard.swift"), encoding: .utf8)
        let code = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.isEmpty }

        // Computed — the brace on the declaration is what says so — and read
        // straight off the session every time it is asked.
        #expect(code.contains { $0 == "public var overlay: MatchOverlay? {" })
        #expect(code.contains { $0.contains("session.presence(of: player)") })
        #expect(code.contains { $0 == "public var inputLocked: Bool { overlay != nil }" })

        // Nothing ever writes it, so there is no copy to go stale.
        let writes = code.filter { $0.hasPrefix("overlay =") || $0.contains("self.overlay =") }
        #expect(writes.isEmpty, "presence is mirrored into stored state: \(writes)")
        // And no stored declaration of it in any spelling.
        let stored = code.filter {
            $0.contains("var overlay") && !$0.hasSuffix("{")
        }
        #expect(stored.isEmpty, "overlay is stored rather than computed: \(stored)")
    }

    /// The other half of the lock: the model's answer has to reach the surface.
    ///
    /// `MatchView` is SwiftUI and the macOS test target cannot compile it, so
    /// the wire is checked against the bytes on disk — and the spellings it
    /// greps for must be present, so a rename fails here rather than passing
    /// vacuously.
    @Test("MatchView hands the lock to the board and draws the overlay over it")
    func matchViewWiresTheLockAndTheOverlay() throws {
        let text = try String(
            contentsOf: MatchHUDTests.shellSource("MatchView.swift"), encoding: .utf8)
        let code = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.isEmpty }

        #expect(code.contains { $0.contains("inputLocked: matchBoard.inputLocked") })
        #expect(code.contains { $0.contains("= matchBoard.overlay") })
        #expect(code.contains { $0.contains("ReconnectingOverlay(peer: peer)") })
        // The copy is the model's, so the fence over player-facing strings has
        // one place to look.
        #expect(code.contains { $0.contains("Text(MatchBoard.reconnectingTitle)") })
    }

    /// `ResultsView` is SwiftUI and cannot be constructed on macOS, so the
    /// "absent, not disabled" half is checked against the bytes on disk.
    ///
    /// Falsifiable both ways: the spellings it greps for must be present, so a
    /// rename fails here rather than passing vacuously.
    @Test("The rematch button is omitted, not greyed out")
    func rematchIsAbsentRatherThanDisabled() throws {
        let text = try String(
            contentsOf: MatchHUDTests.shellSource("ResultsView.swift"), encoding: .utf8)
        let code = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.isEmpty }

        #expect(code.contains { $0.contains("if results.isRematchEnabled {") })
        #expect(code.contains { $0.contains("Text(ResultsModel.rematchLabel)") })
        #expect(
            !code.contains { $0.contains(".disabled(!results.isRematchEnabled)") },
            "the rematch action is disabled rather than absent")
    }
}
