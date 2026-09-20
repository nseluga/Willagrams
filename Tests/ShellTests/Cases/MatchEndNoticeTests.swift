import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell
@testable import Style

/// What the player is *told* while a peer is away, and what they are told when
/// that peer never comes back.
///
/// Two states and the one transition between them, pinned in that order and in
/// one run: the board says the match is being held while the reconnect window
/// is open, and the app leaves the board for the end screen once the window
/// shuts. Both directions, because the failure this file exists to stop is
/// silent — a screen that reports an ending while the peer can still return
/// looks exactly as correct as one that does not, and every other case in this
/// suite stays green either way.
///
/// The clock is ``PresenceOverlayTests/heldGrace()``: the window stays open for
/// as long as the test holds it and shuts the instant it is released, so the
/// transition happens where a test can look at it and no wall clock is
/// involved. Nothing here writes a presence by hand — every change enters
/// through the transport, exactly as it does in a real match.
@MainActor
@Suite("A held match says so, and a dead one says so")
struct MatchEndNoticeTests {

    static let peerID = PresenceOverlayTests.peerID
    static let setup = PresenceOverlayTests.setup

    // MARK: - done when 1 and 2, and the transition between them

    @Test("The board says it is holding, then the app surfaces the ending when the window shuts")
    func holdingBecomesEndedWhenTheGraceExpires() async throws {
        let grace = PresenceOverlayTests.heldGrace()
        let (shell, run, opponent) = try await PresenceOverlayTests.playing(sleepFor: grace.clock)

        // Nothing is being waited on, nothing has ended, and the controls work.
        #expect(run.board.overlay == nil)
        #expect(run.session.isMatchOver == false)
        #expect(run.hud.isSwapPressable)

        opponent.wire.announce(.disconnected(Self.peerID))
        try await SoloMatchTests.waitUntil("the peer to be reported away") {
            run.board.overlay != nil
        }

        // ── Waiting. Covered, locked, and explicitly NOT ended. The second half
        // is the fail-open one: a player inside the window must never be told
        // the match is over, and only an assertion on the ending catches it.
        #expect(run.board.overlay == .reconnecting(peer: Self.peerID.rawValue))
        #expect(run.board.inputLocked)
        #expect(shell.route == .match(Self.setup))
        #expect(run.session.isMatchOver == false)
        #expect(shell.route != .results(winner: nil))

        // And the cover names what is being waited on rather than reporting a
        // connection state the player cannot act on. Asserted by value, because
        // the words are the whole deliverable here.
        let cover = MatchBoard.reconnectingTitle + " " + MatchBoard.reconnectingLine
        #expect(cover.localizedCaseInsensitiveContains("reconnect"))
        #expect(cover.localizedCaseInsensitiveContains("opponent"))
        #expect(
            MatchBoard.reconnectingLine.contains(" "),
            "the line is a single token — it cannot be naming anything")

        // It stays that way for as long as the window is open. A re-entry, not
        // the first entry: the model has already answered this question once.
        for _ in 0..<50 {
            #expect(run.board.overlay == .reconnecting(peer: Self.peerID.rawValue))
            #expect(run.board.inputLocked)
            #expect(shell.route == .match(Self.setup))
            #expect(run.session.isMatchOver == false)
            await Task.yield()
        }

        // ── The window shuts.
        grace.release()
        try await SoloMatchTests.waitUntil("the match to end by itself") {
            run.session.isMatchOver
        }

        // ── Ended. The player is carried off the board to the end screen, which
        // says why. The Draw and Swap this item is about are not merely dead —
        // the screen holding them is gone, which is the only honest answer once
        // `isDrawPressable` and `isSwapPressable` can never be true again.
        try await SoloMatchTests.waitUntil("the shell to surface the ending") {
            shell.route == .results(winner: nil)
        }
        #expect(run.session.presence(of: Self.peerID) == .gone)
        #expect(run.session.winner == nil)
        #expect(run.results().outcome == .noWinner)
        #expect(run.results().headline == ResultsModel.noWinnerHeadline)
        #expect(
            ResultsModel.noWinnerHeadline.localizedCaseInsensitiveContains("left"),
            "the end screen no longer says why the match ended")

        // The two controls the player pressed into silence really are off.
        #expect(run.hud.isDrawPressable == false)
        #expect(run.hud.isSwapPressable == false)
        // And the board's own cover is down, because the board is not what the
        // player is looking at any more.
        #expect(run.board.overlay == nil)

        // It does not drift back. The ending is terminal, not a frame.
        for _ in 0..<50 {
            #expect(shell.route == .results(winner: nil))
            #expect(run.board.overlay == nil)
            await Task.yield()
        }

        shell.returnToMenu()
    }

    // MARK: - The other direction: a recoverable match is never called dead

    @Test("A peer that comes back inside the window was never reported as an ending")
    func aReturningPeerIsNeverReportedAsAnEnding() async throws {
        let grace = PresenceOverlayTests.heldGrace()
        let (shell, run, opponent) = try await PresenceOverlayTests.playing(sleepFor: grace.clock)

        opponent.wire.announce(.disconnected(Self.peerID))
        try await SoloMatchTests.waitUntil("the peer to be reported away") {
            run.board.overlay != nil
        }
        #expect(shell.route == .match(Self.setup))

        opponent.wire.announce(.connected(Self.peerID))
        try await SoloMatchTests.waitUntil("the peer to be reported back") {
            run.board.overlay == nil
        }

        // Fully recovered: nothing covers the board, nothing is locked, the
        // controls are live again, and no ending was ever surfaced.
        #expect(run.board.inputLocked == false)
        #expect(run.session.isMatchOver == false)
        #expect(run.session.presence(of: Self.peerID) == .present)
        #expect(shell.route == .match(Self.setup))
        #expect(run.hud.isDrawPressable)
        #expect(run.hud.isSwapPressable)

        // And it stays recovered — the re-entry the grace is still holding
        // cannot fire an ending behind the player's back.
        for _ in 0..<50 {
            #expect(shell.route == .match(Self.setup))
            #expect(run.session.isMatchOver == false)
            await Task.yield()
        }

        grace.release()
        shell.returnToMenu()
    }

    // MARK: - Reachability: both states are on screen, not merely in the source

    /// ``OrientationTests/source(_:)`` with comments and blank lines dropped, so
    /// a whole declaration can be matched as one contiguous literal.
    ///
    /// The reader is `OrientationTests`' — this only normalizes, on the same
    /// terms `PresenceOverlayTests` does, and there is still exactly one place
    /// that knows where the repo root is.
    static func flattened(_ file: String) throws -> String {
        try OrientationTests.source(file)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The walk from the app root to each of the two states, link by link.
    ///
    /// `ShellRootView.swift` and `MatchView.swift` are SwiftUI and excluded from
    /// this target, so there is nothing to execute and nothing to construct —
    /// the only thing a test can do is read the bytes. Each link is matched as
    /// ONE contiguous literal spanning the declaration, the call inside it and
    /// its closing brace, rather than as separate `contains` checks: an
    /// independent check proves a string exists in the file, not that a player
    /// reaches it, and it stays green for a call gated behind `if isHost`, a
    /// `.hidden()` appended to it, or an arm wrapped in a fresh `if`.
    ///
    /// Brittle on purpose. A sibling view added beside one of these calls turns
    /// this red, and extending the literal is the right answer.
    @Test("Every link from the root to the waiting cover and to the end screen")
    func bothStatesAreReachableFromTheRoot() throws {
        let root = try Self.flattened("Willagrams/Shell/ShellRootView.swift")
        let view = try Self.flattened("Willagrams/Shell/MatchView.swift")

        // Link 1 — the root shows the routed switch, gated only on the launch
        // screen, which is spent for good once the launch loop hands over.
        #expect(root.contains("""
        var body: some View {
        if shell.showsLaunchScreen {
        LaunchView(shell: shell)
        } else {
        routed
        }
        }
        """))

        // Link 2 — the switch reaches both arms, with no predicate on either.
        #expect(root.contains("""
        switch shell.route {
        case .menu: MenuView(shell: shell)
        case .soloSetup: SoloSetupView(shell: shell)
        case .howToPlay: HowToPlayView(shell: shell)
        case .hostLobby: hostLobby
        case .join: joinScreen
        case .profile: profileScreen
        case .friends: friendsScreen
        case .countdown: countdown
        case .match: match
        case .results: results
        }
        """))

        // Link 3 — the match arm, whose only predicate is the run existing.
        #expect(root.contains("""
        @ViewBuilder private var match: some View {
        if let run = shell.run {
        MatchView(matchBoard: run.board, hud: run.hud, dictionary: run.dictionary)
        }
        }
        """))

        // Link 4 — the waiting cover over that board, gated on nothing but the
        // model's own answer, and with no modifier between the arm and the view.
        // A switch, not an `if case`: a returning peer replaces the cover with
        // the resume countdown, and both arms are the one model's one answer.
        #expect(view.contains("""
        .overlay { MatchHUD(hud: hud) }
        .overlay {
        switch matchBoard.overlay {
        case .reconnecting:
        ReconnectingOverlay()
        case let .resuming(secondsRemaining):
        CountdownCard(
        title: Terminology.countdownTitle, secondsRemaining: secondsRemaining)
        case nil:
        EmptyView()
        }
        }
        """))

        // Link 5 — the cover's own body, with both lines of copy in it.
        #expect(view.contains("""
        struct ReconnectingOverlay: View {
        var body: some View {
        ZStack {
        DesignTokens.Palette.ink.opacity(Self.dimOpacity).ignoresSafeArea()
        VStack(spacing: DesignTokens.Space.s) {
        Text(MatchBoard.reconnectingTitle)
        .monoLabel()
        .textCase(.uppercase)
        Text(MatchBoard.reconnectingLine)
        """))

        // Link 6 — the ending's arm, whose only predicate is the same run, and
        // which renders the headline this suite pinned by value above.
        #expect(root.contains("""
        @ViewBuilder private var results: some View {
        if let run = shell.run {
        ResultsView(results: run.results(board: run.board.board), dictionary: run.dictionary)
        }
        }
        """))
        let results = try Self.flattened("Willagrams/Shell/ResultsView.swift")
        #expect(results.contains("Text(results.headline)"))
    }
}
