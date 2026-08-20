//
//  CountdownOverlay.swift
//  Willagrams
//
//  What the countdown screen shows, as a value. The view renders this and
//  decides nothing: whether anything covers the board at all, and the words and
//  the number on it, are settled here where a test can execute them.
//
//  NO SwiftUI here — see the note in AppRoute.swift. This file is pure state,
//  so it compiles into the macOS `Shell` test target and must NOT be listed in
//  that target's `exclude:`.
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

import WillagramsRules

/// The countdown card, or `nil` when nothing should cover the board.
///
/// The seconds are never computed here and never timed here: this reads the
/// number `MatchSession` reports and nothing else. Both devices show whatever
/// their own session counted down from receipt, so a local timer would be a
/// second, disagreeing clock.
public struct CountdownOverlay: Equatable, Sendable {

    /// `Terminology.countdownTitle`, verbatim and unconditionally. There is no
    /// second string for this idea anywhere in the shell.
    public let title: String

    /// Exactly what `MatchStatus.countdown(secondsRemaining:)` carried.
    public let secondsRemaining: Int

    /// Nothing shows at zero, and nothing shows once the match is over.
    ///
    /// The zero guard covers both ends: a session that has not started yet sits
    /// at `.countdown(secondsRemaining: 0)`, and a countdown that runs out flips
    /// straight to `.playing` — neither leaves a card behind.
    ///
    /// `isMatchOver` is the case the status alone cannot answer: a peer that
    /// drops mid-countdown and never returns ends the match with the status left
    /// exactly where it stood, which without this would strand a card over a
    /// board nobody is playing.
    public init?(status: MatchStatus, isMatchOver: Bool) {
        guard !isMatchOver,
              case let .countdown(secondsRemaining) = status,
              secondsRemaining > 0
        else { return nil }
        self.title = Terminology.countdownTitle
        self.secondsRemaining = secondsRemaining
    }

    /// The whole of what the view calls.
    @MainActor
    public init?(session: MatchSession) {
        self.init(status: session.state.status, isMatchOver: session.isMatchOver)
    }
}
