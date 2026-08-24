//
//  MatchHUDModel.swift
//  Willagrams
//
//  Everything the in-match HUD shows and everything its controls do, as state a
//  test can execute. The view renders this and decides nothing.
//
//  NO SwiftUI here — see the note in AppRoute.swift. This file is pure state,
//  so it compiles into the macOS `Shell` test target and must NOT be listed in
//  that target's `exclude:`.
//
//  This file must never import GameKit.
//

// The app compiles `Willagrams/Match`, `Willagrams/Board` and
// `Willagrams/Style` into the same module as the shell, where there is nothing
// to import. `Tests/ShellTests` compiles them as separate ones, so these
// imports are real there and only there — the same shim `SoloMatch.swift` uses.
#if canImport(Match)
import Match
#endif
#if canImport(BoardKit)
import BoardKit
#endif
#if canImport(Style)
import Style
#endif

import Foundation
import Observation
import WillagramsRules

/// The in-match HUD: what is left to take, the two things a player can do with
/// it, and the one way out.
///
/// ## Nothing about the opponent
///
/// There is no opponent-facing value on this type and there is nothing for a
/// view to render one from. Not their board, not their tile count, not whether
/// they are there — `peerPresence` is read only to decide whether a control of
/// *this* player's can do anything, and is never published.
///
/// ## Every value is computed
///
/// Nothing here is mirrored into storage, so there is nothing to go stale and
/// no observation to re-arm: reading `session` and `board` inside a computed
/// property is what registers the dependency, and Observation re-evaluates the
/// view when either changes. ``resignArmed`` is the one stored value, because
/// it is the only thing the HUD itself knows.
@MainActor
@Observable
public final class MatchHUDModel {

    /// Armed by a first press, spent by the second. A destructive action on a
    /// live match takes two deliberate presses, and the arming one never
    /// resigns.
    public private(set) var resignArmed = false

    /// `unowned`: `ShellModel` owns the run that owns this, so a strong
    /// reference here closes a cycle that leaks the whole match when the shell
    /// is dropped mid-match. The shell cannot outlive this, so there is nothing
    /// to unwrap.
    /// How many times a completion claim has been refused this match.
    ///
    /// Not a mirror of anything, so it cannot go stale: it is written only by
    /// ``refuse()``, on the same press that returns `false`, and nothing else
    /// derives from it. The board keys its invalid flash on the value changing,
    /// so it only ever counts up — resetting it to re-arm a flash would replay
    /// a stale one.
    public private(set) var completionAttempts = 0

    /// The one place a refusal is recorded. Every control that can refuse a
    /// completion claim returns through here.
    @discardableResult
    private func refuse() -> Bool {
        completionAttempts += 1
        return false
    }

    @ObservationIgnored private unowned let shell: ShellModel
    @ObservationIgnored private let session: MatchSession
    @ObservationIgnored private let board: MatchBoard

    public init(shell: ShellModel, session: MatchSession, board: MatchBoard) {
        self.shell = shell
        self.session = session
        self.board = board
    }

    // MARK: - Pool

    /// How many tiles are left to take, or `nil` when the session cannot say.
    ///
    /// Straight from `MatchSession.poolRemaining`, which reads the host's real
    /// pool back after every movement of it. `nil` on a device that runs no
    /// pool — a guest cannot know this number.
    ///
    /// Nothing is counted here on purpose: a shell-side ledger of grants is a
    /// second source of truth that can silently disagree with the pool it
    /// claims to describe.
    public var poolRemaining: Int? { session.poolRemaining }

    /// The frozen name for the supply.
    public var poolLabel: String { Terminology.pool }

    /// The count beside that name, or a placeholder while there is no count to
    /// show. Never a guess.
    public var poolValue: String {
        guard let poolRemaining else { return Self.unknownValue }
        return String(poolRemaining)
    }

    /// Local chrome, not `Terminology`: an em dash standing in for a number is
    /// not a game concept.
    public static let unknownValue = "—"

    // MARK: - Draw

    public var drawLabel: String { Terminology.draw }

    /// Whether Draw is *tappable*. NOT the same question as whether it does
    /// anything — see ``draw()``.
    ///
    /// The three states in which drawing is meaningless, and only those. An
    /// unfinished board deliberately leaves the control live: pressing it is
    /// how the player asks why, and the refusal flashes the runs that are the
    /// answer. Disabling on `board.canDraw` swallowed that press, so the flash
    /// `MatchHUDModel` counts and `BoardView` draws could never fire from the
    /// app — only from a test calling ``draw()`` directly.
    ///
    /// The board's own published answer, AND-ed with the three states in which
    /// drawing is meaningless. The shell never checks a board or a word itself.
    ///
    /// A tile already waiting behind Draw does *not* disable it, and does not
    /// have to wait for a finished board either: taking an owed tile is not a
    /// completion claim, it is how the board reopens. Gating it on `canDraw`
    /// would strand a player whose board is unfinished — the only press that
    /// unfreezes them is the one they are not allowed to make.
    public var isDrawEnabled: Bool {
        isDrawPressable && (owesATile || board.canDraw)
    }

    /// Whether the opponent's draw has left this device a tile to take. Named
    /// once here because three properties below turn on it.
    public var owesATile: Bool { session.hasPendingDraw }

    /// Whether Draw and Win may be *pressed*, which is not whether they can
    /// succeed — everything except the board itself.
    ///
    /// The split is the whole point. A button disabled outright swallows the
    /// press, so nothing counts a refusal and nothing flashes, and a player
    /// whose board is merely unfinished — which is every player on every
    /// opening deal — presses a dead control and is told nothing at all. When
    /// the board is the problem the board can say so, so the press must land:
    /// see ``draw()`` and ``MatchHUDModel/blockedCoords`` on the surface.
    ///
    /// These three states are different. There is nothing on the board to light
    /// up for a finished match, a departed opponent or an empty pool, so those
    /// really do disable the control.
    public var isDrawPressable: Bool {
        !session.isMatchOver
            && session.peerPresence == .present
            && (owesATile || !session.poolIsExhausted)
    }

    /// Takes a round. Refuses outright when ``isDrawEnabled`` is false, so the
    /// disabled control and the ignored one cannot disagree.
    ///
    /// A refusal — from either the gate or the session — is counted in
    /// ``completionAttempts``, which is what tells the player why nothing
    /// happened.
    ///
    /// - Returns: whether the press did anything.
    @discardableResult
    public func draw() -> Bool {
        resignArmed = false
        guard isDrawEnabled, board.canDraw, session.draw() else { return refuse() }
        return true
    }

    // MARK: - Win

    public var winLabel: String { Terminology.winCall }

    /// Whether calling the match is on offer at all.
    ///
    /// Four things at once, and the pool is the one that is not a Draw rule: a
    /// player calls the game when there is nothing left to take and their own
    /// board is one complete grid. Offering the call while the pool still has
    /// tiles in it would be offering a press that ends a game nobody has run out
    /// of — so the control is not merely disabled then, it is not drawn.
    ///
    /// The other three are the Draw rules, minus the pool clause `isDrawPressable`
    /// folds in — which is false in exactly the state this must be true in.
    public var isWinEnabled: Bool {
        !session.isMatchOver
            && session.peerPresence == .present
            && !owesATile
            && session.poolIsExhausted
            && board.canDraw
    }

    /// Calls the match, and moves the shell to the results it just produced —
    /// the same ending ``confirmResign()`` makes, from the other side.
    ///
    /// A refusal — from the gate or from the session — is counted in
    /// ``completionAttempts`` and changes no route: a refused claim is not an
    /// outcome, so the player stays in the match they are still playing.
    ///
    /// - Returns: whether the match was won.
    @discardableResult
    public func claimWin() -> Bool {
        resignArmed = false
        guard isWinEnabled, board.canDraw, session.claimWin() else { return refuse() }
        shell.matchEnded(winner: session.winner)
        return true
    }

    // MARK: - Swap

    public var swapLabel: String { Terminology.swap }

    /// The tile Swap would return: the one the player has selected on the
    /// board. Nothing is chosen on the player's behalf — with no selection, or
    /// more than one, there is nothing to swap.
    public var swappableTile: Tile? {
        guard board.model.selected.count == 1,
              let coord = board.model.selected.first
        else { return nil }
        return board.board.tile(at: coord)
    }

    public var isSwapEnabled: Bool {
        swappableTile != nil
            && !session.isMatchOver
            && session.peerPresence == .present
            && !session.hasPendingDraw
            && !session.poolIsExhausted
    }

    /// Returns one tile and takes three.
    ///
    /// The session only swaps a tile that is in the rack, and every tile this
    /// shell holds is on the board, so a board tile comes back first. A refusal
    /// puts it back where it was, on both boards, before returning.
    ///
    /// ponytail: a swap the *host* refuses — fewer than three tiles left, which
    /// is not the same latch as an exhausted pool — answers over the wire long
    /// after this returns, leaving the tile in a rack the shell does not draw.
    /// Upgrade with the same `MatchSession` amendment ``poolRemaining`` names.
    ///
    /// - Returns: whether the swap was requested.
    @discardableResult
    public func swap(_ tile: Tile) -> Bool {
        resignArmed = false
        guard isSwapEnabled else { return false }

        let coord = session.state.board.placementList.first { $0.tile.id == tile.id }?.coord
        if let coord {
            do { try session.recall(from: coord) } catch { return false }
            _ = board.board.remove(at: coord)
        }
        guard session.swap(tile) else {
            if let coord {
                try? session.place(tileID: tile.id, at: coord)
                try? board.board.place(tile, at: coord)
            }
            return false
        }
        return true
    }

    // MARK: - Resign

    /// Local chrome, not `Terminology`: that file is the fence around the
    /// game's vocabulary and giving up is a control, not a game concept. Named
    /// here so there is exactly one copy of each.
    public var resignLabel: String { "Resign" }
    public var resignConfirmLabel: String { "Give up the match" }
    public var resignCancelLabel: String { "Keep playing" }

    /// Offers the confirmation. Never resigns — that is the whole point.
    public func armResign() {
        resignArmed = true
    }

    public func cancelResign() {
        resignArmed = false
    }

    /// Gives the match up, only from an armed HUD, and moves the shell to the
    /// results it just produced.
    ///
    /// - Returns: whether the match was resigned.
    @discardableResult
    public func confirmResign() -> Bool {
        guard resignArmed else { return false }
        resignArmed = false
        guard session.resign() else { return false }
        shell.matchEnded(winner: session.winner)
        return true
    }
}
