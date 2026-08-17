import Observation
import WillagramsRules

// NO SwiftUI here — see the note in AppRoute.swift.

/// Owns the current route and every legal move between routes. Views read
/// ``route`` and call these methods; nothing outside this type may assign a
/// route, which is why the setter is private.
@MainActor
@Observable
public final class ShellModel {

    public private(set) var route: AppRoute

    public init(route: AppRoute = .menu) {
        self.route = route
    }

    /// Menu → countdown. Ignored from anywhere else, so a stray tap on a stale
    /// menu button cannot yank a live match back to the start.
    public func startMatch(_ setup: MatchSetup) {
        guard case .menu = route else { return }
        route = .countdown(setup)
    }

    /// What the menu's one action starts. Solo practice takes no options, so the
    /// setup is fixed apart from the seed — there is no difficulty selector and
    /// no opponent to configure.
    public static let soloHandSize = 21
    public static let soloCountdownSeconds = 3

    /// Menu → countdown with the solo setup. The seed is injectable so a test
    /// can assert the exact route rather than only that it left `.menu`.
    public func startSoloPractice(seed: UInt64 = .random(in: UInt64.min ... UInt64.max)) {
        startMatch(
            MatchSetup(
                seed: seed,
                startingHandSize: Self.soloHandSize,
                countdownSeconds: Self.soloCountdownSeconds
            )
        )
    }

    /// Countdown → match, carrying the same setup forward untouched.
    public func countdownFinished() {
        guard case .countdown(let setup) = route else { return }
        route = .match(setup)
    }

    /// Match → results. Only reachable from a match, so results can never show
    /// an outcome for a match that never ran.
    public func matchEnded(winner: PlayerID?) {
        guard case .match = route else { return }
        route = .results(winner: winner)
    }

    /// The one transition legal from anywhere: back out to the root screen.
    public func returnToMenu() {
        route = .menu
    }
}
