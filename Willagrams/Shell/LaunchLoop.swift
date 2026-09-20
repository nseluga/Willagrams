import Foundation

// NO SwiftUI here — the loop policy has to be reachable from the macOS test
// package, which is why it is a plain value and not a `@State` in `LaunchView`.

/// Whether the loading screen replays or hands over to Home, and when.
///
/// Time and readiness are injected: nothing here sleeps, reads a wall clock or
/// touches a view, so a whole six-second timeout and a whole 4.2s cycle are
/// driven in a test without waiting for either.
///
/// The screen owns the animation. This owns the one decision the animation
/// cannot make for itself.
public struct LaunchLoop {

    /// One full pass of the wordmark animation, in seconds — the comp's.
    public static let cycleSeconds: TimeInterval = 4.2

    /// How long sign-in may hold the loading screen up. Past it the launch goes
    /// on regardless and Home shows its own signing-in state, which is what
    /// makes a dead network a delay rather than a hang.
    public static let signInTimeoutSeconds: TimeInterval = 6

    public enum Outcome: Equatable {
        /// Not ready yet: run the cycle again.
        case replay
        /// Ready: that was the last cycle, go to Home.
        case home
    }

    /// Whether the player has animation turned down.
    public let reduceMotion: Bool

    /// Seconds since the loading screen came up.
    private let elapsed: () -> TimeInterval

    private var dictionaryLoaded = false
    private var signInLanded = false

    public init(reduceMotion: Bool = false, elapsed: @escaping () -> TimeInterval) {
        self.reduceMotion = reduceMotion
        self.elapsed = elapsed
    }

    /// The dictionary finished building.
    public mutating func dictionaryDidLoad() { dictionaryLoaded = true }

    /// Sign-in landed — succeeded or failed. Either is settled; a failure is
    /// Home's existing reason line, not a reason to keep the loader up.
    public mutating func signInDidSettle() { signInLanded = true }

    /// Settled once sign-in lands *or* once the cap passes.
    public var isSignInSettled: Bool {
        signInLanded || elapsed() >= Self.signInTimeoutSeconds
    }

    public var isReady: Bool { dictionaryLoaded && isSignInSettled }

    /// Asked part-way through a cycle, whenever readiness may have changed.
    ///
    /// Only Reduce Motion leaves early. With motion on, readiness arriving
    /// mid-cycle never cuts the animation short — the cycle finishes first.
    public var exitsMidCycle: Bool { reduceMotion && isReady }

    /// Asked at the end of every cycle.
    public func cycleEnded() -> Outcome { isReady ? .home : .replay }
}
