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
