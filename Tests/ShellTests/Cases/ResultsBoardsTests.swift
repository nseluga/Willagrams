import BoardKit
import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell
@testable import Style

/// The end screen's card, its two boards, and the win moment's state.
@MainActor
@Suite("Results boards")
struct ResultsBoardsTests {

    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal
    static let me = PlayerID(rawValue: "zzz")
    static let them = PlayerID(rawValue: "aaa")

    static func placements(_ letters: String) -> [Placement] {
        letters.enumerated().map {
            Placement(tile: Tile(letter: $0.element), coord: Coord(row: 0, col: $0.offset))
        }
    }

    static func model(
        winner: PlayerID?, opponent: [Placement]? = nil, winning: [Placement]? = nil,
        mine: Board = Board(), state: ResultsState = ResultsState(), rematch: Bool = true,
        shell: ShellModel = ShellModel()
    ) -> ResultsModel {
        ResultsModel(
            shell: shell, winner: winner, localPlayerID: me, winningPlacements: winning,
            opponentFinalPlacements: opponent, board: mine, state: state,
            teardown: { true }, rematch: rematch ? {} : nil
        )
    }

    /// A far end over a real solo session whose opponent board is chosen.
    final class StubOpponent: MatchOpponent {
        let inner: SoloMatch
        let placed: [Placement]?
        var session: MatchSession { inner.session }
        init(placed: [Placement]?) {
            self.placed = placed
            inner = SoloMatch(setup: SoloMatchTests.setup, dictionary: EveryWordIsReal(), sleepFor: { _ in })
        }
        func start() { inner.start() }
        func leave() { inner.leave() }
        var peerBoardPlacements: [Placement]? { placed }
    }

    // MARK: - 7a

    @Test("The card closes and comes back, and both exits stay reachable")
    func cardDismissAndRestore() {
        let state = ResultsState()
        let results = Self.model(winner: Self.me, state: state)
        #expect(results.isCardShown)
        results.closeCard()
        #expect(!results.isCardShown)
        // A rebuilt model over the same state still reads closed.
        #expect(!Self.model(winner: Self.me, state: state).isCardShown)
        #expect(results.isRematchEnabled)
        results.reopenCard()
        #expect(results.isCardShown)

        // Rematch and Main Menu work with the card closed.
        results.closeCard()
        let shell = ShellModel(route: .results(winner: Self.me))
        let menu = Self.model(winner: Self.me, state: state, shell: shell)
        menu.mainMenu()
        #expect(shell.route == .menu)
        #expect(Self.model(winner: nil, rematch: false).isRematchEnabled == false)
        #expect(Self.model(winner: Self.them, rematch: true).rematch())
    }

    @Test("The shown board survives a rebuilt model")
    func shownBoardIsStable() {
        let state = ResultsState()
        Self.model(winner: Self.me, opponent: Self.placements("AB"), state: state).show(.opponents)
        let rebuilt = Self.model(winner: Self.me, opponent: Self.placements("AB"), state: state)
        #expect(rebuilt.shownSide == .opponents)
        #expect(rebuilt.shownBoard?.placementList.count == 2)
    }

    // MARK: - 7b

    @Test("Online shows the board from the supplied final placements")
    func onlineSuppliedPlacements() {
        let results = Self.model(winner: Self.me, opponent: Self.placements("ABC"))
        #expect(results.opponentBoard?.placementList.count == 3)
    }

    @Test("Solo shows the bot's board, read from its own session")
    func soloShowsBotBoard() throws {
        let shell = ShellModel(dictionary: { EveryWordIsReal() }, sleepFor: { _ in })
        let bot = Self.placements("BOT")
        var made: StubOpponent?
        shell.startMatch(SoloMatchTests.setup) { let o = StubOpponent(placed: bot); made = o; return o }
        _ = try #require(made)
        let run = try #require(shell.run)
        #expect(run.results().opponentBoard?.placementList.count == 3)
        // The real solo far end reads the bot session's own board.
        let solo = SoloMatch(setup: SoloMatchTests.setup, dictionary: EveryWordIsReal(), sleepFor: { _ in })
        #expect(solo.peerBoardPlacements == solo.bot.session.state.board.placementList)
        run.leave()
    }

    @Test("Boards are read-only and pannable")
    func readOnlyAndPannable() throws {
        #expect(ResultsModel.inputLocked)
        var board = Board()
        try board.place(Tile(letter: "A"), at: Coord(row: 0, col: 0))
        let camera = BoardCamera()
        let drag = BoardGesture.Drag(
            at: camera.point(for: Coord(row: 0, col: 0)), in: board, camera: camera,
            inputLocked: ResultsModel.inputLocked
        )
        #expect(drag.grab == .pan, "a locked touch must pan, not pick up")
    }

    @Test("The winner's board stands in for the opponent's when the opponent won")
    func winnerFallback() {
        let results = Self.model(winner: Self.them, winning: Self.placements("XY"))
        #expect(results.opponentBoard?.placementList.count == 2)
    }

    // MARK: - 7c

    @Test("A malformed or missing payload is 'not available', never the local board")
    func notAvailable() throws {
        var mine = Board()
        try mine.place(Tile(letter: "M"), at: Coord(row: 5, col: 5))
        let twice = [
            Placement(tile: Tile(letter: "W"), coord: Coord(row: 0, col: 0)),
            Placement(tile: Tile(letter: "E"), coord: Coord(row: 0, col: 0)),
        ]
        for results in [
            Self.model(winner: Self.me, opponent: twice, mine: mine),
            Self.model(winner: Self.me, opponent: nil, mine: mine),
            Self.model(winner: Self.them, opponent: twice, winning: Self.placements("AB"), mine: mine),
            Self.model(winner: Self.them, opponent: nil, winning: twice, mine: mine),
        ] {
            #expect(results.opponentBoard == nil)
            results.show(.opponents)
            #expect(results.shownBoard == nil)
        }
        #expect(ResultsModel.opponentBoardMissing.isEmpty == false)
    }

    // MARK: - 7e

    @Test("The burst plays once, on a win only")
    func burstOnWinOnly() {
        let state = ResultsState()
        let win = Self.model(winner: Self.me, state: state)
        #expect(win.showsBurst)
        win.burstFinished()
        #expect(!Self.model(winner: Self.me, state: state).showsBurst)
        #expect(!Self.model(winner: Self.them).showsBurst)
        #expect(!Self.model(winner: nil).showsBurst)
    }
}
