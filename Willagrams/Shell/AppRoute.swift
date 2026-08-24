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
/// Exactly the four arguments `MatchSession.startMatch` takes. `options` was the
/// speculative one until a screen rendered it — ``SoloSetup`` does now, so a
/// setup carries the rules the match will actually be played under rather than
/// leaving `startMatch` to assume the standard ones.
///
/// It defaults to `.standard`, so every caller that predates the screen still
/// describes the match it always described.
public struct MatchSetup: Hashable, Sendable {
    public let seed: UInt64
    public let startingHandSize: Int
    public let countdownSeconds: Int
    public let options: MatchOptions

    public init(
        seed: UInt64,
        startingHandSize: Int,
        countdownSeconds: Int,
        options: MatchOptions = .standard
    ) {
        self.seed = seed
        self.startingHandSize = startingHandSize
        self.countdownSeconds = countdownSeconds
        self.options = options
    }
}

/// The current screen *and* the state that screen renders, as one value. A case
/// without its data is unrepresentable, so there is no way to be on the match
/// screen with no setup or on the results screen with no outcome.
public enum AppRoute: Hashable, Sendable {
    /// The root screen. Renders nothing match-specific, so it carries nothing.
    case menu
    /// The screen that configures solo practice: who plays, and under what
    /// rules. Reachable from the menu, and the only way into a solo match. It
    /// carries nothing — the settings live on ``ShellModel/soloSetup``, which
    /// outlives the screen so a player's choices survive a visit to the menu.
    case soloSetup
    /// The rules screen. Reachable from the menu and back again, never from
    /// inside a match, and it renders nothing match-specific — so, like `menu`,
    /// it carries nothing.
    case howToPlay
    case countdown(MatchSetup)
    case match(MatchSetup)
    /// `winner` is nil when the match ended without one — a draw, or a peer that
    /// left before either player claimed.
    case results(winner: PlayerID?)
}
