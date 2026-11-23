import Audio
import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell

/// The pause control, as the player meets it: at once against a bot, and by
/// agreement against a person.
///
/// The session's own rules are pinned in `MatchSessionPauseTests`. These cases
/// drive the HUD's one control over real sessions, so what is checked is what a
/// press does and what the player is told.
@MainActor
@Suite("Match pause: the control and what it says")
struct MatchPauseTests {

    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal

    // MARK: - Solo

    @Test("A solo pause holds the match at once, and a second press resumes it")
    func soloPausesAtOnceAndResumes() async throws {
        let shell = PresenceOverlayTests.shell()
        #expect(shell.startSoloPractice())
        let run = try #require(shell.run)
        try await SoloMatchTests.waitUntil("the opening deal to be laid") {
            run.board.board.placementList.count == ShellModel.soloHandSize
        }
        let hud = run.hud
        #expect(hud.pauseLabel == "Pause")
        #expect(hud.isPauseOffered)
        #expect(hud.isMatchLive)
        #expect(hud.isDrawPressable)

        hud.pausePressed()
        // No wait: there is nobody to ask, so the same press holds both ends.
        #expect(hud.isPaused)
        #expect(run.session.isPaused)
        #expect(run.match.bot.session.isPaused, "the bot plays on through a pause")
        #expect(hud.isMatchLive == false)
        #expect(hud.isDrawPressable == false)
        #expect(hud.isSwapPressable == false)
        #expect(hud.draw() == false)
        let laid = try #require(run.session.state.board.placementList.first)
        #expect(throws: (any Error).self) { try run.session.recall(from: laid.coord) }
        // The way out stays open, and it says what it does.
        #expect(hud.isPauseOffered)
        #expect(hud.pauseLabel == "Resume")
        #expect(hud.pauseStatus == nil)

        hud.pausePressed()
        #expect(hud.isPaused == false)
        #expect(run.match.bot.session.isPaused == false)
        #expect(hud.isMatchLive)
        #expect(hud.isDrawPressable)
        #expect(hud.pauseLabel == "Pause")
        try run.session.recall(from: laid.coord)

        shell.returnToMenu()
    }

    // MARK: - Two players

    static let alice = PlayerID(rawValue: "aaa")
    static let bob = PlayerID(rawValue: "zzz")

    /// Two real sessions on one wire, each under its own HUD. The shells are
    /// returned because a HUD holds its shell `unowned`.
    static func table() async throws -> (
        host: MatchHUDModel, guest: MatchHUDModel, sessions: [MatchSession], shells: [ShellModel]
    ) {
        let (first, second) = FakeTransport.pair(alice, bob)
        let sessions = [
            MatchSession(
                transport: first, peerPlayerID: bob, dictionary: EveryWordIsReal(), sleepFor: { _ in }),
            MatchSession(
                transport: second, peerPlayerID: alice, dictionary: EveryWordIsReal(), sleepFor: { _ in }),
        ]
        sessions[0].startMatch(seed: 77, startingHandSize: 2, countdownSeconds: 0)
        try await SoloMatchTests.waitUntil("both sessions playing") {
            sessions.allSatisfy { $0.state.status == .playing && $0.state.hand.count == 2 }
        }
        let shells = sessions.map { _ in ShellModel(route: .match(MatchBoardTests.setup)) }
        let huds = zip(sessions, shells).map { session, shell in
            MatchHUDModel(
                shell: shell, session: session,
                board: MatchBoard(
                    session: session, dictionary: EveryWordIsReal(), audio: SilentAudioPlayer()),
                audio: SilentAudioPlayer()
            )
        }
        return (huds[0], huds[1], sessions, shells)
    }

    @Test("One player asks, the other is told, and the match pauses only when both agree")
    func aPauseIsAskedForAndAgreedTo() async throws {
        let (host, guest, sessions, shells) = try await Self.table()
        defer { sessions.forEach { $0.leave() } }
        _ = shells

        guest.pausePressed()
        #expect(guest.pauseLabel == "Cancel pause")
        #expect(guest.pauseStatus == "Waiting for your opponent to agree to pause")
        try await SoloMatchTests.waitUntil("the host to be told") {
            host.pauseStatus == "Your opponent wants to pause"
        }
        #expect(host.pauseLabel == "Agree to pause")
        // A request is not a pause: both players can still play.
        #expect(host.isPaused == false && guest.isPaused == false)
        #expect(host.isMatchLive && guest.isMatchLive)

        host.pausePressed()
        try await SoloMatchTests.waitUntil("both players paused") { host.isPaused && guest.isPaused }
        try await SoloMatchTests.waitUntil("both players to see the agreement") {
            host.pauseStatus == nil && guest.pauseStatus == nil
        }
        #expect(host.pauseLabel == "Resume" && guest.pauseLabel == "Resume")
        #expect(host.isMatchLive == false && guest.isMatchLive == false)
        #expect(host.isPauseOffered && guest.isPauseOffered)

        // Resuming is asked for and agreed to the same way.
        host.pausePressed()
        #expect(host.pauseLabel == "Stay paused")
        #expect(host.pauseStatus == "Waiting for your opponent to agree to resume")
        try await SoloMatchTests.waitUntil("the guest to be told") {
            guest.pauseStatus == "Your opponent wants to resume"
        }
        #expect(guest.pauseLabel == "Agree to resume")
        #expect(host.isPaused && guest.isPaused)

        guest.pausePressed()
        try await SoloMatchTests.waitUntil("both players playing again") {
            !host.isPaused && !guest.isPaused && host.pauseStatus == nil && guest.pauseStatus == nil
        }
        #expect(host.pauseLabel == "Pause" && guest.pauseLabel == "Pause")
        #expect(host.isMatchLive && guest.isMatchLive)
    }

    @Test("A request nobody answers leaves the match playable, and a second press takes it back")
    func anUnansweredRequestIsTakenBack() async throws {
        let (host, guest, sessions, shells) = try await Self.table()
        defer { sessions.forEach { $0.leave() } }
        _ = shells

        guest.pausePressed()
        try await SoloMatchTests.waitUntil("the host to be told") { host.pauseStatus != nil }
        #expect(guest.isMatchLive)
        #expect(guest.isDrawPressable)

        guest.pausePressed()
        #expect(guest.pauseLabel == "Pause")
        #expect(guest.pauseStatus == nil)
        try await SoloMatchTests.waitUntil("the host to see it withdrawn") { host.pauseStatus == nil }
        #expect(host.pauseLabel == "Pause")
        #expect(host.isPaused == false && guest.isPaused == false)
    }

    /// The view is SwiftUI, which this target cannot compile, so the wiring is
    /// checked against the bytes on disk, the way `PresenceOverlayTests` checks
    /// the reconnect cover.
    @Test("MatchView locks a paused board and MatchHUD draws the control")
    func theViewsAreWiredToTheModel() throws {
        let view = try String(
            contentsOf: MatchHUDTests.shellSource("MatchView.swift"), encoding: .utf8)
        #expect(view.contains("inputLocked: matchBoard.inputLocked || hud.isPaused"))
        let hud = try String(
            contentsOf: MatchHUDTests.shellSource("MatchHUD.swift"), encoding: .utf8)
        #expect(hud.contains("Button(hud.pauseLabel) { hud.pausePressed() }"))
        #expect(hud.contains("if let status = hud.pauseStatus"))
        #expect(hud.contains("Text(hud.pausedTitle)"))
    }
}
