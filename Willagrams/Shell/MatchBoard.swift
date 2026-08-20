//
//  MatchBoard.swift
//  Willagrams
//
//  The wire between the match and the surface. `MatchSession` says which tiles
//  this device holds; `BoardLayout` says where an arrival goes; this routes the
//  one into the other and reads the surface's own answer back out for the HUD.
//
//  It computes NO geometry. Every coordinate on the board came out of
//  `BoardLayout` by way of `BoardModel`, and the only thing done with one here
//  is to hand it straight back to `MatchSession.place(tileID:at:)` so the tile
//  leaves the hand it arrived in.
//
//  NO SwiftUI here — see the note in AppRoute.swift. Pure state, so it compiles
//  into the macOS `Shell` test target and must NOT be listed in that target's
//  `exclude:`.
//
//  This file must never import GameKit.
//

// The app compiles `Willagrams/Match`, `Willagrams/Board` and
// `Willagrams/Shell` into one module, where there is nothing to import.
// `Tests/ShellTests` compiles them as separate ones, so the imports are real
// there and only there.
#if canImport(Match)
import Match
#endif
#if canImport(BoardKit)
import BoardKit
#endif

import CoreGraphics
import Foundation
import Observation
import WillagramsRules

/// What the board surface draws, kept in step with the match that feeds it.
///
/// ## The one rule
///
/// A tile exists in exactly one place. `MatchSession` puts an arrival in
/// `state.hand`; delivering it to the board is `MatchSession.place`, which
/// removes it from that hand in the same statement it lands it on
/// `state.board`. So `board` here and `session.state.board` hold the same
/// placements, and the hand holds none of them — there is no second copy of a
/// tile anywhere and no shell-side rack to lose one in.
///
/// ## Two arrivals, one path
///
/// The opening deal and every later Draw both surface as *tiles in the hand
/// this type has not laid yet*. The first such set is the opening and goes
/// through ``BoardModel/opening(_:against:)``; every later one is a delivery
/// and goes through ``BoardModel/delivered(_:onto:camera:in:against:)``.
/// `MatchSession` offers no "what just arrived" event, so the difference is
/// carried here rather than guessed from a count.
///
/// ## Interruption
///
/// A delivery is refused outright — not half done — whenever the session will
/// not take the placements: a tile waiting behind the Draw button, a peer that
/// has gone, a finished match. Nothing is marked laid on that path, so the
/// tiles stay in the hand and the very next change re-arms ``sync()``. The
/// mirror loop rolls its own placements back if the rules refuse one part way,
/// for the same reason: half a delivery is a lost tile.
@MainActor
@Observable
public final class MatchBoard {

    /// What `BoardView` draws, and what its drag commits write back through the
    /// binding. Settable for exactly that reason.
    public var board = Board()

    /// The surface's own state, including the validation the HUD reads.
    public var model = BoardModel()

    /// Where the surface is looking, and how much of it there is. Read by a
    /// delivery to land tiles the player can see; owned by the view, which is
    /// the only thing that knows either. Never used to compute a coordinate
    /// here — both are handed straight to `BoardLayout`.
    public var camera = BoardCamera()
    public var viewport: CGRect = .zero

    /// Whether the player may Draw. Straight off the surface's published
    /// answer — the shell never checks a board or a word itself.
    public var canDraw: Bool { model.canDraw }

    /// Tiles already laid on the board by this type. Not a rack and not a
    /// second copy: ids only, so an arrival can be told from a tile the player
    /// is still moving around.
    @ObservationIgnored private var laidTileIDs: Set<UUID> = []
    @ObservationIgnored private var hasOpened = false
    @ObservationIgnored private let session: MatchSession
    @ObservationIgnored private let dictionary: any WordList

    public init(session: MatchSession, dictionary: any WordList) {
        self.session = session
        self.dictionary = dictionary
        sync()
        track()
    }

    /// Lays whatever the session has handed this device and not yet had laid.
    ///
    /// Idempotent and cheap when there is nothing to do, which is what makes it
    /// safe to call from an observation callback that fires for every change to
    /// the session, most of which are not arrivals.
    public func sync() {
        // The session refuses `place` in all three of these states, and a
        // refusal part way through a delivery is what loses a tile. Nothing is
        // marked laid, so the arrival waits in the hand and the change that
        // lifts the block re-arms this.
        guard !session.hasPendingDraw,
              !session.isMatchOver,
              session.peerPresence == .present
        else { return }

        let arrivals = session.state.hand.filter { !laidTileIDs.contains($0.id) }
        guard !arrivals.isEmpty else { return }
        let arriving = Set(arrivals.map(\.id))

        // On a copy. `Board` and `BoardModel` are values, so a delivery the
        // mirror below refuses is thrown away whole rather than half published.
        var next = model
        let laid = hasOpened
            ? next.delivered(arrivals, onto: board, camera: camera, in: viewport, against: dictionary)
            : next.opening(arrivals, against: dictionary)

        var mirrored: [Coord] = []
        for placement in laid.placementList where arriving.contains(placement.tile.id) {
            do {
                try session.place(tileID: placement.tile.id, at: placement.coord)
                mirrored.append(placement.coord)
            } catch {
                // The rules refused a placement `BoardLayout` chose, which means
                // the session's board and this one have diverged. Every tile
                // this loop moved goes back to the hand it came from and the
                // delivery is dropped, leaving the count exactly where it was.
                for coord in mirrored { try? session.recall(from: coord) }
                return
            }
        }

        board = laid
        model = next
        laidTileIDs.formUnion(arriving)
        hasOpened = true
    }

    /// Re-runs ``sync()`` on every change to the session, once per change.
    ///
    /// `withObservationTracking` fires *before* the change lands and is spent
    /// when it does, so the work hops to the next main-actor turn — where the
    /// new value is readable — and re-registers there. Nothing polls, and
    /// nothing here observes this type's own state, so publishing a board
    /// cannot feed back into another sync.
    private func track() {
        withObservationTracking {
            _ = session.state.hand.count
            _ = session.pendingDrawTiles.count
            _ = session.peerPresence
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sync()
                self.track()
            }
        }
    }
}
