import Foundation
import Style
import Testing
import WillagramsRules
@testable import Match
@testable import Shell

/// A clock that hands out one second only when this test says so.
///
/// The session's countdown is the only thing that sleeps in these tests, so a
/// suspended sleeper is always the countdown waiting for its next tick. Nothing
/// here waits on wall-clock time: three seconds cost nothing and cannot flake.
@MainActor
final class StepClock {
    private var waiting: CheckedContinuation<Void, Never>?

    /// Whether the countdown is parked on a tick.
    var isWaiting: Bool { waiting != nil }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { waiting = $0 }
    }

    /// Lets one second elapse.
    func advance() {
        let resume = waiting
        waiting = nil
        resume?.resume()
    }
}

@MainActor
@Suite("Countdown overlay")
struct CountdownOverlayTests {

    // MARK: - The derivation, without a session

    @Test("Every second reported shows, with the frozen title")
    func showsWhatTheStatusCarries() {
        for seconds in 1...10 {
            let overlay = CountdownOverlay(
                status: .countdown(secondsRemaining: seconds),
                isMatchOver: false
            )
            #expect(overlay?.secondsRemaining == seconds)
            #expect(overlay?.title == Terminology.countdownTitle)
        }
    }

    @Test("Nothing covers the board off the countdown")
    func nothingOutsideACountdown() {
        // The status a session sits at before it has started.
        #expect(CountdownOverlay(status: .countdown(secondsRemaining: 0), isMatchOver: false) == nil)
        #expect(CountdownOverlay(status: .playing, isMatchOver: false) == nil)
        #expect(CountdownOverlay(status: .finished(winner: SoloMatch.localPlayerID), isMatchOver: true) == nil)
    }

    /// The stranded-card case: a peer that drops mid-countdown and never comes
    /// back ends the match with the status left exactly where it stood.
    @Test("A match ended under the countdown leaves no card")
    func matchOverClearsIt() {
        #expect(CountdownOverlay(status: .countdown(secondsRemaining: 2), isMatchOver: true) == nil)
    }

    // MARK: - The derivation against a real session

    /// Criterion 1: each second the session reports, and cleared at `.playing`.
    @Test("A three-second countdown shows 3, 2, 1 and then nothing")
    func countsDownWithTheSession() async throws {
        try await runCountdown(from: 3)
    }

    /// Criterion 3, at the shortest countdown there is.
    @Test("A one-second countdown leaves no card behind")
    func oneSecondClears() async throws {
        try await runCountdown(from: 1)
    }

    /// Drives a real `MatchSession` down from `start` one injected second at a
    /// time, asserting the overlay at every step including the last.
    private func runCountdown(from start: Int) async throws {
        let clock = StepClock()
        let solo = SoloMatch(
            setup: MatchSetup(
                seed: 20260817,
                startingHandSize: ShellModel.soloHandSize,
                countdownSeconds: start
            ),
            dictionary: SoloMatchTests.EveryWordIsReal(),
            sleepFor: { await clock.sleep($0) }
        )
        defer { solo.leave() }
        solo.start()

        #expect(CountdownOverlay(session: solo.session)?.secondsRemaining == start)
        #expect(CountdownOverlay(session: solo.session)?.title == Terminology.countdownTitle)

        for remaining in stride(from: start - 1, through: 1, by: -1) {
            try await tick(clock)
            try await SoloMatchTests.waitUntil("second \(remaining)") {
                solo.session.state.status == .countdown(secondsRemaining: remaining)
            }
            #expect(CountdownOverlay(session: solo.session)?.secondsRemaining == remaining)
        }

        try await tick(clock)
        try await SoloMatchTests.waitUntil("the match to start") {
            solo.session.state.status == .playing
        }
        #expect(CountdownOverlay(session: solo.session) == nil)
    }

    private func tick(_ clock: StepClock) async throws {
        try await SoloMatchTests.waitUntil("the countdown to park on a tick") { clock.isWaiting }
        clock.advance()
    }
}
