//
//  OnlineOpponent.swift
//  Willagrams
//
//  `OnlineMatch` as a ``MatchOpponent``. The adapter, and nothing else: no
//  lobby, no routing, no copy.
//
//  NO SwiftUI here — see the note in AppRoute.swift. This file is pure state,
//  so it compiles into the macOS `Shell` test target and must NOT be listed in
//  that target's `exclude:`.
//
//  This file must never import GameKit.
//

#if canImport(Match)
import Match
#endif

import WillagramsRules

/// A network far end, wearing the shape `MatchRun` drives.
///
/// The façade hands its `MatchSession` out of an `async` call, so — unlike
/// `SoloMatch` — the session exists before the opponent does. That is the whole
/// reason this is a separate type rather than a conformance on `OnlineMatch`:
/// the two halves are paired here, once, by whoever awaited the start.
///
/// Nothing here reads `MatchRun.match`, which is the solo handle and traps on a
/// run built this way.
@MainActor
public final class OnlineOpponent: MatchOpponent {

    /// The live session ``OnlineMatch/start()`` or ``OnlineMatch/awaitStart()``
    /// handed back.
    public let session: MatchSession

    /// Held so ``leave()`` reaches the channel, the presence pump and the
    /// recorder — everything the session itself does not own.
    private let match: OnlineMatch

    /// `leave()` is idempotent by contract, and both halves below are already
    /// idempotent themselves; this only stops a second teardown paying for two
    /// no-ops.
    private var hasLeft = false

    public init(match: OnlineMatch, session: MatchSession) {
        self.match = match
        self.session = session
    }

    /// Nothing. The match was opened by the façade before this pairing existed —
    /// `start()` on the façade is what returned the session — so there is no
    /// second opening to do, and doing one would deal a hand twice.
    ///
    /// `MatchRun.start()` calls this all the same: solo and online are driven
    /// identically, and the difference lives here rather than in a branch there.
    public func start() {}

    public func leave() {
        guard !hasLeft else { return }
        hasLeft = true
        session.leave()
        match.leave()
    }
}
