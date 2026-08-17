import BoardKit
import CoreGraphics
import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell
@testable import Style

/// One test per acceptance criterion for the end screen. The three outcomes are
/// each driven from a real session's `winner` where the match lane can produce
/// one, and the teardown is proved by execution rather than by reading the code
/// that claims it.
@MainActor
@Suite("Results screen")
struct ResultsModelTests {

    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal

    /// The drag layer wants hardware. Nothing on a locked board ever fires, and
    /// that is one of the things asserted below.
    struct SilentHaptics: BoardHaptics {
        func fire(_ event: BoardHapticEvent) {}
    }

    static let hostID = PlayerID(rawValue: "aaa")
    static let guestID = PlayerID(rawValue: "zzz")

    /// Two real sessions on one real wire, both playing. One resignation then
    /// produces a local win on one of them and a peer win on the other, which is
    /// the only way to get both outcomes out of the match lane rather than out
    /// of a literal.
    static func playingPair() async throws -> (host: MatchSession, guest: MatchSession) {
        #expect(HostPool.host(of: hostID, guestID) == hostID)
        let (hostWire, guestWire) = FakeTransport.pair(hostID, guestID)
        let host = MatchSession(
            transport: hostWire, peerPlayerID: guestID,
            dictionary: EveryWordIsReal(), sleepFor: { _ in }
        )
        let guest = MatchSession(
            transport: guestWire, peerPlayerID: hostID,
            dictionary: EveryWordIsReal(), sleepFor: { _ in }
        )
        host.startMatch(seed: 7, startingHandSize: 2, countdownSeconds: 0)
        try await SoloMatchTests.waitUntil("both ends to be playing") {
            host.state.status == .playing && guest.state.status == .playing
        }
        return (host, guest)
    }

    // MARK: - Criterion 1, case 1: a local win

    @Test("A local win shows the win call")
    func aLocalWinShowsTheWinCall() async throws {
        let (host, guest) = try await Self.playingPair()
        #expect(guest.resign())
        try await SoloMatchTests.waitUntil("the resignation to reach the host") {
            host.winner != nil
        }
        #expect(host.winner == Self.hostID)

        let results = ResultsModel(shell: ShellModel(), session: host)
        #expect(results.outcome == .localWin)
        #expect(results.didLocalPlayerWin)
        #expect(results.didPeerWin == false)
        #expect(results.headline == Terminology.winCall)

        host.leave()
        guest.leave()
    }

    // MARK: - Criterion 1, case 2: a peer win

    @Test("A peer win shows the peer as winner and never the win call")
    func aPeerWinShowsThePeerAsWinner() async throws {
        let (host, guest) = try await Self.playingPair()
        #expect(guest.resign())
        #expect(guest.winner == Self.hostID, "resigning hands the win to the peer")

        let results = ResultsModel(shell: ShellModel(), session: guest)
        #expect(results.outcome == .peerWin)
        #expect(results.didPeerWin)
        #expect(results.didLocalPlayerWin == false)
        #expect(results.headline != Terminology.winCall)
        #expect(results.headline == ResultsModel.peerWinHeadline)

        host.leave()
        guest.leave()
    }

    // MARK: - Criterion 1, case 3: nobody won

    /// A peer that never comes back ends the match with `winner` nil. That is
    /// neither player winning and it is not this player losing — the screen must
    /// say so rather than fall through to a defeat.
    @Test("A peer that never returns shows neither player as winner and no defeat")
    func aVanishedPeerShowsNeitherPlayerAsWinner() async throws {
        let (host, guest) = try await Self.playingPair()

        // The reconnect window is the injected seam, and it returns at once.
        host.leave()
        try await SoloMatchTests.waitUntil("the peer to be gone") {
            guest.peerPresence == .gone
        }
        #expect(guest.isMatchOver, "the match really did end")
        #expect(guest.winner == nil)
        #expect(guest.winningPlacements == nil)

        let results = ResultsModel(shell: ShellModel(), session: guest)
        #expect(results.outcome == .noWinner)
        #expect(results.didLocalPlayerWin == false)
        #expect(results.didPeerWin == false)
        #expect(results.headline != Terminology.winCall)
        #expect(
            results.headline != ResultsModel.peerWinHeadline,
            "a nil winner fell through to a defeat"
        )
        #expect(results.headline == ResultsModel.noWinnerHeadline)

        guest.leave()
    }

    /// The other no-winner terminal the match lane ships: a resignation whose
    /// peer vanished before it could be answered. Same rule, different route in.
    @Test("A resignation the vanished peer never answered still names no winner")
    func aResignVanishShowsNoWinner() async throws {
        let (host, guest) = try await Self.playingPair()

        host.leave()
        try await SoloMatchTests.waitUntil("the peer to be gone") {
            guest.peerPresence == .gone
        }
        // Over is over: the resignation is refused, so nobody is handed a win.
        #expect(guest.resign() == false)
        #expect(guest.winner == nil)

        let results = ResultsModel(shell: ShellModel(), session: guest)
        #expect(results.outcome == .noWinner)
        #expect(results.didLocalPlayerWin == false)
        #expect(results.didPeerWin == false)

        guest.leave()
    }

    // MARK: - Criterion 2: Main Menu

    /// Teardown by execution: the match is left, and afterwards it is shut — not
    /// merely unreferenced by the screen.
    @Test("Main Menu returns to the menu and tears the match down")
    func mainMenuTearsTheMatchDown() async throws {
        let shell = ShellModel()
        shell.startSoloPractice(seed: 4)
        shell.countdownFinished()
        shell.matchEnded(winner: nil)
        #expect(shell.route == .results(winner: nil))

        let solo = SoloMatch(
            setup: SoloMatchTests.setup, dictionary: EveryWordIsReal(), sleepFor: { _ in }
        )
        solo.start()
        // The far end's pump has consumed the opening grant, so a later count is
        // a fact about the pump still running rather than about a buffer.
        try await SoloMatchTests.waitUntil("the far end to take its opening") {
            solo.session.state.status == .playing
                && solo.peerTileIDs.count == SoloMatchTests.setup.startingHandSize
        }
        let peerTilesWhilePlaying = solo.peerTileIDs.count

        var leaveCalls = 0
        let results = ResultsModel(
            shell: shell, session: solo.session, teardown: { leaveCalls += 1; solo.leave() }
        )
        results.mainMenu()

        #expect(shell.route == .menu)
        #expect(leaveCalls == 1, "Main Menu did not tear the match down")
        #expect(solo.session.peerPresence == .gone)
        #expect(solo.session.draw() == false, "a torn-down session still takes input")

        // The far end's pump is cancelled and its transport left. Nothing more
        // reaches it however many turns pass — the release test next door is
        // what proves no task is left holding the match itself.
        for _ in 0..<3 { await Task.yield() }
        #expect(solo.peerTileIDs.count == peerTilesWhilePlaying, "the far end kept taking tiles")

        // Spent, not repeatable: a second tap cannot leave a second match up.
        results.mainMenu()
        #expect(leaveCalls == 1)
    }

    /// Release by execution: the screen holds the only strong reference, and
    /// Main Menu drops it. Read on a later main-actor turn, because the tasks
    /// the session owns have to be given one to finish on.
    @Test("Main Menu releases the previous session")
    func mainMenuReleasesTheSession() async throws {
        let shell = ShellModel(route: .results(winner: nil))
        weak var weakSolo: SoloMatch?
        weak var weakSession: MatchSession?

        func makeResults() -> ResultsModel {
            let solo = SoloMatch(
                setup: SoloMatchTests.setup, dictionary: EveryWordIsReal(), sleepFor: { _ in }
            )
            solo.start()
            weakSolo = solo
            weakSession = solo.session
            // The closure is the only strong reference the screen holds.
            return ResultsModel(shell: shell, session: solo.session, teardown: { solo.leave() })
        }

        let results = makeResults()
        #expect(weakSolo != nil, "the match was released before Main Menu")
        #expect(weakSession != nil)

        results.mainMenu()
        #expect(shell.route == .menu)

        try await SoloMatchTests.waitUntil("the match to be released") {
            weakSolo == nil && weakSession == nil
        }
        // The screen is still alive and still holds nothing.
        #expect(results.outcome == .noWinner)
    }

    // MARK: - Criterion 3: the final board

    @Test("The final board cannot be played on")
    func theFinalBoardCannotBePlayedOn() throws {
        let tile = Tile(letter: "A")
        let coord = Coord(row: 0, col: 0)
        var board = Board()
        try board.place(tile, at: coord)

        #expect(ResultsModel.inputLocked, "the results screen unlocked the board")

        // Exactly what `BoardView` does with that boolean: `.onChange(of:
        // inputLocked, initial: true)` writes it into the model before a finger
        // can reach the surface.
        var model = BoardModel(inputLocked: ResultsModel.inputLocked)

        model.began(.tile(tile, at: coord), on: board, against: EveryWordIsReal(), haptics: SilentHaptics())
        #expect(model.dragging.isEmpty, "a locked board took hold of a tile")

        let after = model.commit(
            translation: CGSize(width: 200, height: 200), on: board,
            camera: BoardCamera(), threshold: 0, against: EveryWordIsReal()
        )
        #expect(after == board, "a locked board committed a move")

        model.enterSelection()
        #expect(model.selected.isEmpty, "a locked board entered selection")
    }

    /// The board shown is the winner's board when the wire sent one, and this
    /// device's own otherwise. Peer input that will not make a board is dropped
    /// whole rather than shown half laid.
    @Test("The final board is the winning board, or the one this device ended on")
    func theFinalBoardIsTheWinningBoard() throws {
        let shell = ShellModel()
        let mine = try {
            var board = Board()
            try board.place(Tile(letter: "M"), at: Coord(row: 5, col: 5))
            return board
        }()
        let theirs = [
            Placement(tile: Tile(letter: "W"), coord: Coord(row: 0, col: 0)),
            Placement(tile: Tile(letter: "E"), coord: Coord(row: 0, col: 1)),
        ]

        let won = ResultsModel(
            shell: shell, winner: Self.hostID, localPlayerID: Self.guestID,
            winningPlacements: theirs, board: mine
        )
        #expect(won.board.placementList.count == 2)
        #expect(won.board.tile(at: Coord(row: 0, col: 1))?.letter == "E")

        let none = ResultsModel(
            shell: shell, winner: nil, localPlayerID: Self.guestID,
            winningPlacements: nil, board: mine
        )
        #expect(none.board == mine)

        // Peer input naming one coordinate twice will not make a board.
        let duplicate = [
            Placement(tile: Tile(letter: "W"), coord: Coord(row: 0, col: 0)),
            Placement(tile: Tile(letter: "E"), coord: Coord(row: 0, col: 0)),
        ]
        let refused = ResultsModel(
            shell: shell, winner: Self.hostID, localPlayerID: Self.guestID,
            winningPlacements: duplicate, board: mine
        )
        #expect(refused.board == mine, "a board that will not build was shown half laid")
    }

    // MARK: - Rematch

    /// The labels, and the two ends of the enabled/disabled rule. A screen with
    /// nothing to rematch into still refuses; one wired to an owner does not.
    /// What a press actually rebuilds is `RematchTests`.
    @Test("Rematch is enabled only when wired, and Main Menu is local chrome")
    func rematchIsEnabledOnlyWhenWired() {
        let unwired = ResultsModel(
            shell: ShellModel(), winner: nil, localPlayerID: Self.guestID
        )
        #expect(unwired.isRematchEnabled == false)
        #expect(unwired.rematch() == false)

        var starts = 0
        let wired = ResultsModel(
            shell: ShellModel(), winner: nil, localPlayerID: Self.guestID,
            rematch: { starts += 1 }
        )
        #expect(wired.isRematchEnabled)
        #expect(wired.rematch())
        #expect(starts == 1)
        // Spent, not repeatable: a second tap cannot start a third match.
        #expect(wired.rematch() == false)
        #expect(wired.isRematchEnabled == false)
        #expect(starts == 1)

        // Main Menu spends it too, so a stale screen cannot start a match
        // behind the menu.
        let leaving = ResultsModel(
            shell: ShellModel(), winner: nil, localPlayerID: Self.guestID,
            rematch: { starts += 1 }
        )
        leaving.mainMenu()
        #expect(leaving.isRematchEnabled == false)
        #expect(leaving.rematch() == false)
        #expect(starts == 1)

        #expect(ResultsModel.rematchLabel == "Rematch")
        #expect(ResultsModel.mainMenuLabel == "Main Menu")
    }

    // MARK: - The guardrail

    /// Checked against the bytes on disk: `winCall` is the only frozen string
    /// this screen shows, and every other line on it is declared where it is
    /// used.
    @Test("Only the win call comes from Terminology")
    func onlyTheWinCallComesFromTerminology() throws {
        let shellSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ShellSrc")
            .resolvingSymlinksInPath()
        for name in ["ResultsModel.swift", "ResultsView.swift"] {
            let text = try String(
                contentsOf: shellSource.appendingPathComponent(name), encoding: .utf8
            )
            for line in text.components(separatedBy: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                guard let range = code.range(of: "Terminology.") else { continue }
                #expect(
                    code[range.lowerBound...].hasPrefix("Terminology.winCall"),
                    "\(name) reaches into Terminology for something other than winCall: \(code)"
                )
            }
        }
    }
}
