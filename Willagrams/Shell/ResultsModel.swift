//
//  ResultsModel.swift
//  Willagrams
//
//  Everything the end screen says and everything its two actions do, as state a
//  test can execute. `ResultsView` renders this and decides nothing.
//
//  NO SwiftUI here — see the note in AppRoute.swift. This file is pure state,
//  so it compiles into the macOS `Shell` test target and must NOT be listed in
//  that target's `exclude:`.
//
//  This file must never import GameKit.
//

// The app compiles `Willagrams/Match` and `Willagrams/Style` into the same
// module as the shell, where there is nothing to import. `Tests/ShellTests`
// compiles them as separate ones, so these imports are real there and only
// there — the same shim `SoloMatch.swift` uses.
#if canImport(Match)
import Match
#endif
#if canImport(Style)
import Style
#endif

import Foundation
import WillagramsRules

/// The end of a match: who won, the board it ended on, and the two ways out.
///
/// Not `@Observable`: nothing here changes while the screen is up. The outcome
/// and the board are frozen at construction — a match that is over cannot move
/// — and the one mutable thing, ``teardown``, is spent on the way out.
@MainActor
public final class ResultsModel {

    /// How the match ended, from this device's point of view.
    ///
    /// Three cases, not two. A match with no winner is a real outcome the match
    /// lane ships — a peer that never came back, and a resignation whose peer
    /// vanished before it could be answered — and it is neither a win nor a
    /// loss. Anything derived from `winner` here goes through this, so there is
    /// no path on which `nil` falls through to a defeat.
    public enum Outcome: Equatable, Sendable {
        case localWin
        case peerWin
        case noWinner
    }

    public let outcome: Outcome

    /// The board shown behind the result. Fixed at construction: nothing on this
    /// screen may move a tile, so there is nothing to keep in step.
    public let board: Board

    private let shell: ShellModel

    /// Ends the match and drops the last strong reference to it in the same
    /// statement — see ``mainMenu()``. The closure is expected to capture the
    /// match (`SoloMatch`/`MatchSession`) strongly and call `leave()`, so
    /// releasing the closure releases the match.
    ///
    /// A closure rather than the match itself: this screen knows only that
    /// something has to be torn down, never what kind of match it was.
    ///
    /// Returns whether it actually tore anything down. A stale screen's closure
    /// declines — the match it was built for has already been replaced — and
    /// neither exit may act on a press that did nothing. A decline spends
    /// nothing, so a stale screen keeps its closure and keeps declining; the
    /// match it names is already gone, and the closure holds only a weak
    /// reference to the owner, so keeping it retains nothing.
    private var teardown: (() -> Bool)?

    /// Starts the next match. Spent on the way out, exactly like ``teardown``,
    /// so a double tap cannot build two.
    ///
    /// A closure for the same reason: what rebuilds a match is `ShellModel`,
    /// and this screen holds no opinion about how it does it.
    private var startRematch: (() -> Void)?

    public init(
        shell: ShellModel,
        winner: PlayerID?,
        localPlayerID: PlayerID,
        winningPlacements: [Placement]? = nil,
        board: Board = Board(),
        teardown: (() -> Bool)? = nil,
        rematch: (() -> Void)? = nil
    ) {
        self.startRematch = rematch
        self.shell = shell
        if let winner {
            self.outcome = winner == localPlayerID ? .localWin : .peerWin
        } else {
            self.outcome = .noWinner
        }
        self.board = Self.finalBoard(winningPlacements, fallback: board)
        self.teardown = teardown
    }

    /// The whole of what the view calls.
    public convenience init(
        shell: ShellModel,
        session: MatchSession,
        board: Board = Board(),
        teardown: (() -> Bool)? = nil,
        rematch: (() -> Void)? = nil
    ) {
        self.init(
            shell: shell,
            winner: session.winner,
            localPlayerID: session.localPlayerID,
            winningPlacements: session.winningPlacements,
            board: board,
            teardown: teardown,
            rematch: rematch
        )
    }

    /// The winner's board as it was sent, or the board this device ended on.
    ///
    /// `winningPlacements` is peer input, so it can name the same coordinate
    /// twice. `MatchSession` deliberately leaves that decision here: a list that
    /// will not make a board is dropped whole rather than shown half laid.
    static func finalBoard(_ placements: [Placement]?, fallback: Board) -> Board {
        guard let placements else { return fallback }
        var built = Board()
        for placement in placements {
            do { try built.place(placement.tile, at: placement.coord) } catch { return fallback }
        }
        return built
    }

    // MARK: - What the screen says

    public var didLocalPlayerWin: Bool { outcome == .localWin }
    public var didPeerWin: Bool { outcome == .peerWin }

    /// The one frozen string on this screen, and it is shown on exactly one
    /// outcome. Every other line here is local chrome.
    public var headline: String {
        switch outcome {
        case .localWin: Terminology.winCall
        case .peerWin: Self.peerWinHeadline
        case .noWinner: Self.noWinnerHeadline
        }
    }

    /// Local chrome, not `Terminology`: that file is the frozen IP fence and
    /// names game concepts, not screens.
    public static let peerWinHeadline = "Your opponent won"
    /// Not a defeat, and not an error. Said plainly.
    public static let noWinnerHeadline = "No winner"
    public static let rematchLabel = "Rematch"
    public static let mainMenuLabel = "Main Menu"

    // MARK: - The board behind the result

    /// The board is shown, never played. `BoardView` takes this and refuses a
    /// pickup before a drag is ever built.
    public static let inputLocked = true

    // MARK: - Rematch

    /// Whether there is anything to rematch into. A screen built with no
    /// rematch closure still refuses rather than offering a dead button.
    public var isRematchEnabled: Bool { startRematch != nil }

    /// Ends the finished match and starts a fresh one — in that order.
    ///
    /// The order is the guardrail: the old transport and its stream-iteration
    /// task are shut down before the replacement is built, so repeated
    /// rematches cannot pile up live sessions. The closure is spent first, so a
    /// second tap during the rebuild cannot start a third match.
    ///
    /// - Returns: whether the press did anything.
    @discardableResult
    public func rematch() -> Bool {
        guard let start = startRematch else { return false }
        // A stale screen declines both exits, and declining spends neither — the
        // same rule ``mainMenu()`` follows, for the same reason: a spent
        // teardown reads as "nothing to tear down", which is the state that
        // navigates unconditionally. Running it first also keeps the guardrail
        // order, the old match down before the new one is built.
        guard teardown?() ?? true else { return false }
        startRematch = nil
        teardown = nil
        start()
        return true
    }

    // MARK: - Main Menu

    /// Ends the match, lets go of it, and goes back to the root screen — in that
    /// order.
    ///
    /// Dropping ``teardown`` is what releases the match: it is the only strong
    /// reference this screen holds to one. Calling it twice is a no-op, so a
    /// double tap cannot leave a second match running.
    ///
    /// The route change and the teardown succeed or fail together. A stale
    /// screen's ``teardown`` declines, and parking the route on the menu while
    /// the match that replaced this screen is still live is the worse half of
    /// that. A screen built with no teardown owns nothing to decline, so it
    /// still navigates.
    ///
    /// A declined press spends nothing. Dropping the closure would encode the
    /// decline as "no teardown to run", which is the one state that navigates
    /// unconditionally — so a second press on a stale screen would go through
    /// the gap the first press just closed.
    public func mainMenu() {
        guard teardown?() ?? true else { return }
        teardown = nil
        startRematch = nil
        shell.returnToMenu()
    }
}
