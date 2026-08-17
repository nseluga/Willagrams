import WillagramsRules

// NO SwiftUI in this directory except in a file named in the `Shell` target's
// `exclude:` list in `Tests/ShellTests/Package.swift`. `Tests/ShellTests/ShellSrc`
// is a directory symlink to it and that test target builds for macOS with no
// simulator, so an unexcluded View landing here stops the suite building —
// `SourceGuardrailTests` fails first and says so. A view that does land here
// reads `ShellModel`; it never decides or assigns a route itself.

/// Everything a match needs to be stood up, carried by the routes that lead to
/// it so the countdown and the match it becomes cannot disagree about the seed.
///
/// ponytail: exactly the three arguments `MatchSession.startMatch` takes — no
/// speculative fields. Add more when a screen actually renders one.
public struct MatchSetup: Hashable, Sendable {
    public let seed: UInt64
    public let startingHandSize: Int
    public let countdownSeconds: Int

    public init(seed: UInt64, startingHandSize: Int, countdownSeconds: Int) {
        self.seed = seed
        self.startingHandSize = startingHandSize
        self.countdownSeconds = countdownSeconds
    }
}

/// The current screen *and* the state that screen renders, as one value. A case
/// without its data is unrepresentable, so there is no way to be on the match
/// screen with no setup or on the results screen with no outcome.
public enum AppRoute: Hashable, Sendable {
    /// The root screen. Renders nothing match-specific, so it carries nothing.
    case menu
    case countdown(MatchSetup)
    case match(MatchSetup)
    /// `winner` is nil when the match ended without one — a draw, or a peer that
    /// left before either player claimed.
    case results(winner: PlayerID?)
}
