//
//  AppActivityWiringTests.swift
//  ShellTests
//
//  Item 10, the half no behavioural test can reach: the observer the *app*
//  ships, as opposed to the one every other case hand-wires.
//
//  `ShellServices.activity` defaults to `AppActivity()`, which subscribes to
//  `NotificationCenter.default`. Changing that one default argument to
//  `AppActivity(center: nil)` compiles, ships a binary where locking the phone
//  still kills the match, and passes every other test in the repo — because
//  every other test builds its own observer and drives it with `send(_:)`.
//  These cases are the only thing standing between that edit and a release.
//

import Foundation
import Testing

@testable import Audio
@testable import Match
@testable import Shell

@Suite("The scene-phase observer the app actually ships")
struct AppActivityWiringTests {

    @Test("The shell's own AppActivity is subscribed to a notification centre")
    func theShippedObserverIsSubscribed() {
        #expect(ShellServices().activity.isObservingForTesting)
    }

    @Test("A shell built with no arguments still gets a subscribed observer")
    func everyDefaultedShellObserves() {
        // The lobbies read `shell.services.activity` and pass it to
        // `OnlineMatch`, so a services value built any other way in the app
        // would silently hand them a dead observer.
        let services = ShellServices(audio: SilentAudioPlayer())
        #expect(services.activity.isObservingForTesting)
        #expect(services.activity.phase == .active)
    }

    /// The two names are ObjC strings rather than `UIApplication.<x>Notification`
    /// behind a `#if canImport(UIKit)` precisely so this case can exist: the
    /// conditional version was compiled by no `swift test` gate at all, so
    /// swapping background for foreground was invisible.
    @Test("An observing AppActivity flips phase on the real lifecycle notifications")
    func theObserverSubscribesToTheTwoLifecycleNotifications() {
        let centre = NotificationCenter()
        let activity = AppActivity(center: centre)
        #expect(activity.isObservingForTesting)

        centre.post(name: AppActivity.awayNotification, object: nil)
        #expect(activity.phase == .away)

        centre.post(name: AppActivity.activeNotification, object: nil)
        #expect(activity.phase == .active)
    }

    @Test("The two lifecycle notifications are UIKit's, by name")
    func theNotificationNamesAreUIKits() {
        #expect(AppActivity.awayNotification.rawValue == "UIApplicationDidEnterBackgroundNotification")
        #expect(
            AppActivity.activeNotification.rawValue
                == "UIApplicationWillEnterForegroundNotification")
    }

    @Test("A listener registered on the shell's observer hears both phases")
    func aListenerOnTheShellsObserverIsCalled() {
        let heard = Heard()
        let services = ShellServices()
        services.activity.add(heard)
        services.activity.send(.away)
        services.activity.send(.active)
        #expect(heard.phases == [.away, .active])
    }

    private final class Heard: AppActivityListener, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [AppActivity.Phase] = []
        var phases: [AppActivity.Phase] { lock.withLock { seen } }
        func appActivityChanged(to phase: AppActivity.Phase) {
            lock.withLock { seen.append(phase) }
        }
    }
}
