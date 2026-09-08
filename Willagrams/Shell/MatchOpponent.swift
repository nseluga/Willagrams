//
//  MatchOpponent.swift
//  Willagrams
//
//  What `MatchRun` needs from whoever is at the far end of a match, and nothing
//  more. `SoloMatch` conforms here; `OnlineMatch` is adapted to it separately.
//
//  NO SwiftUI here — see the note in AppRoute.swift. This file is pure state,
//  so it compiles into the macOS `Shell` test target and must NOT be listed in
//  that target's `exclude:`.
//
//  This file must never import GameKit.
//

// The app compiles `Willagrams/Match` and `Willagrams/Shell` into one module,
// where there is nothing to import; `Tests/ShellTests` compiles them as
// separate ones — the same shim `SoloMatch.swift` uses.
#if canImport(Match)
import Match
#endif

import WillagramsRules

/// The far end of a match, as the shell sees it.
///
/// `MatchRun` holds one of these and never asks which kind it is: a run built
/// over a bot and a run built over a network peer differ in how they were
/// constructed, never in how they are driven. Anything a screen needs beyond
/// these three things belongs on ``MatchSession``, which every conformer
/// already exposes.
///
/// Class-bound because the shell's ownership rule is about instance identity —
/// exactly one live opponent at a time — and a value type has none.
@MainActor
public protocol MatchOpponent: AnyObject {

    /// The local end. Everything the shell renders reads off this.
    var session: MatchSession { get }

    /// The local player's id at that end.
    var localPlayerID: PlayerID { get }

    /// Opens the match. Called once, by ``MatchRun/start()``, after the run is
    /// fully assembled and observing.
    func start()

    /// Ends the session and everything the far end was running. Must be
    /// idempotent: tearing a run down twice cannot reach a live one.
    func leave()

    /// Whether this far end can be played again straight from the end screen.
    ///
    /// Asked of the opponent rather than answered by `MatchRun`, so the run
    /// still never learns which kind it holds. A bot can be dealt a second hand
    /// on the spot; a network peer cannot — that needs a new match row and a
    /// fresh invite, which is a lobby's job and not this screen's.
    var offersRematch: Bool { get }
}

extension MatchOpponent {

    /// Rebuildable in place unless the conformer says otherwise. Solo is the
    /// default because every opponent `ShellModel` can construct by itself is.
    public var offersRematch: Bool { true }

    /// The session already elected a local player; asking it is how the two
    /// answers cannot start to disagree.
    public var localPlayerID: PlayerID { session.localPlayerID }
}

/// Solo is just one kind of far end. Declared here rather than on the type so
/// `SoloMatch` keeps saying only what solo means.
extension SoloMatch: MatchOpponent {}
