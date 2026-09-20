import Foundation
import Testing
@testable import Shell

/// The loading screen's policy, driven without a clock.
///
/// Every case here builds the loop with elapsed time as a value, so the whole
/// six-second sign-in cap and the whole 4.2s cycle are exercised in no time at
/// all. A case that needed a real wait would be the wrong design, not a slow
/// test.
@Suite("Launch loop")
struct LaunchLoopTests {

    private func loop(reduceMotion: Bool = false, elapsed: TimeInterval = 0) -> LaunchLoop {
        LaunchLoop(reduceMotion: reduceMotion, elapsed: { elapsed })
    }

    /// Written out rather than read back off the code under test: these two
    /// numbers are the comp's and the item's, and a test that compared them to
    /// themselves would pass over any value.
    @Test("The cycle length and the sign-in cap are the numbers the comp gives")
    func constantsAreTheCompsNumbers() {
        #expect(LaunchLoop.cycleSeconds == 4.2)
        #expect(LaunchLoop.signInTimeoutSeconds == 6.0)
    }

    @Test("Not ready at the end of a cycle replays it")
    func notReadyReplays() {
        var loop = loop()
        #expect(loop.cycleEnded() == .replay)

        // One gate is not readiness.
        loop.signInDidSettle()
        #expect(loop.isReady == false)
        #expect(loop.cycleEnded() == .replay)

        loop.dictionaryDidLoad()
        #expect(loop.isReady)
        #expect(loop.cycleEnded() == .home)
    }

    /// The half of the rule that is easy to lose: readiness landing part-way
    /// through must not cut the animation short.
    @Test("Ready mid-cycle exits at that cycle's end and not before")
    func readyMidCycleFinishesTheCycle() {
        var loop = loop()
        loop.dictionaryDidLoad()
        loop.signInDidSettle()
        #expect(loop.isReady)
        #expect(loop.exitsMidCycle == false)
        #expect(loop.cycleEnded() == .home)
    }

    @Test("Sign-in that never lands is given up on at six seconds, not before")
    func signInTimesOutAtSixSeconds() {
        var early = loop(elapsed: 5.9)
        early.dictionaryDidLoad()
        #expect(early.isSignInSettled == false)
        #expect(early.isReady == false)
        #expect(early.cycleEnded() == .replay)

        var capped = loop(elapsed: 6.0)
        capped.dictionaryDidLoad()
        #expect(capped.isSignInSettled)
        #expect(capped.isReady)
        #expect(capped.cycleEnded() == .home)
    }

    /// A launch can never hang: the cap alone, with no sign-in and no dictionary
    /// yet, still is not readiness — but the cap plus the dictionary always is.
    @Test("The cap alone is not readiness")
    func capAloneIsNotReadiness() {
        let stalled = loop(elapsed: 60)
        #expect(stalled.isSignInSettled)
        #expect(stalled.isReady == false)
        #expect(stalled.cycleEnded() == .replay)
    }

    @Test("Reduce Motion leaves the moment it is ready")
    func reduceMotionExitsImmediately() {
        var loop = loop(reduceMotion: true)
        #expect(loop.exitsMidCycle == false)
        loop.dictionaryDidLoad()
        #expect(loop.exitsMidCycle == false)
        loop.signInDidSettle()
        #expect(loop.isReady)
        #expect(loop.exitsMidCycle)
    }
}

/// `ShellModel`'s half: the gates the loop reads, and the one way the loader
/// comes down.
@MainActor
@Suite("Launch state")
struct LaunchStateTests {

    @Test("A fresh model comes up on the loading screen with both gates shut")
    func startsOnTheLoadingScreen() {
        let shell = ShellModel(sleepFor: { _ in })
        #expect(shell.showsLaunchScreen)
        #expect(shell.isDictionaryLoaded == false)
    }

    /// No sign-in in this build, so there is nothing to wait for — waiting
    /// anyway would hold the loader for the whole six seconds.
    @Test("launch() opens both gates when the build carries no sign-in")
    func launchOpensBothGates() {
        let shell = ShellModel(sleepFor: { _ in })
        shell.launch()
        #expect(shell.isDictionaryLoaded)
        #expect(shell.hasSignInSettled)
    }

    @Test("finishLaunch() is the one way the loading screen comes down")
    func finishTakesTheLoaderDown() {
        let shell = ShellModel(sleepFor: { _ in })
        shell.launch()
        #expect(shell.showsLaunchScreen)
        shell.finishLaunch()
        #expect(shell.showsLaunchScreen == false)
        // And the route it uncovers is the menu, untouched by any of this.
        #expect(shell.route == .menu)
    }
}
