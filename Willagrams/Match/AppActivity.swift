//
//  AppActivity.swift
//  Willagrams
//
//  The app's one scene-phase observer, and the only place the app hears that
//  it left the screen and came back.
//
//  It lives beside the match rather than in `Willagrams/App/` for one concrete
//  reason: `Willagrams/App/` is symlinked into no test package at all, and
//  `Willagrams/Shell/` reaches neither `Tests/MatchTests` nor
//  `Tests/OnlineTests` — which is exactly where the two listeners
//  (`MatchSession` and `RealtimeMatchTransport`) are proven. `Willagrams/Match`
//  is compiled by every package that compiles either of them.
//
//  Never imports SwiftUI. The two lifecycle notifications are named by their
//  ObjC constants rather than by `UIApplication.<name>Notification` behind a
//  `#if canImport(UIKit)`, and that is deliberate: a conditionally-compiled
//  subscription is compiled by no `swift test` gate at all, so swapping the two
//  names is a mutation nothing can catch. Named as strings, `observe(_:)` is one
//  unconditional body that a macOS test drives by posting to an injected
//  `NotificationCenter` — see `ScreenLockTests.theObserverSubscribesToTheTwo…`.
//  `assertNamesStillMatchUIKit()` is the belt: it compiles only under UIKit, it
//  is compiled by the `xcodebuild` gate, and it trips on a debug launch if
//  Apple ever renames a constant that has been stable since iOS 2.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Something that has to be told the app left the screen and came back.
///
/// `nonisolated` on purpose, and that is the load-bearing word. UIKit posts its
/// lifecycle notifications on the main thread today, but a callback that
/// inherits `@MainActor` and is ever delivered off the main queue traps in
/// `dispatch_assert_queue` — the same fault the iPad launch crash was. Nothing
/// on this path is main-actor isolated; a listener that needs the main actor
/// hops onto it itself, where the hop is visible.
public protocol AppActivityListener: AnyObject, Sendable {
    func appActivityChanged(to phase: AppActivity.Phase)
}

/// Fans the app's scene phase out to whoever is mid-match.
///
/// Deliberately not a general lifecycle framework: one phase, one list of weak
/// listeners, and a `send(_:)` a test calls in place of locking a phone.
public final class AppActivity: @unchecked Sendable {

    /// Where the app is, as far as anything counting time needs to know.
    public enum Phase: Sendable, Equatable {
        /// On screen and running.
        case active
        /// Off screen: locked, switched away from, or suspended outright. A
        /// process in this state gets no CPU, so a peer has no way to reach it
        /// and no window it is missing is the peer's fault.
        case away
    }

    /// The notification that means the app left the screen —
    /// `UIApplication.didEnterBackgroundNotification` by its ObjC name.
    public static let awayNotification = Notification.Name(
        "UIApplicationDidEnterBackgroundNotification")

    /// The notification that means it is coming back —
    /// `UIApplication.willEnterForegroundNotification` by its ObjC name.
    public static let activeNotification = Notification.Name(
        "UIApplicationWillEnterForegroundNotification")

    private let lock = NSLock()
    private var current: Phase = .active
    private var listeners: [WeakListener] = []
    private var tokens: [any NSObjectProtocol] = []
    private let center: NotificationCenter?

    /// - Parameter center: where the system's lifecycle notifications come
    ///   from, or `nil` for an instance a test drives entirely through
    ///   ``send(_:)``. Defaulted to the real centre so the production path
    ///   cannot be forgotten at a call site.
    public init(center: NotificationCenter? = .default) {
        self.center = center
        guard let center else { return }
        observe(center)
    }

    /// The phase last announced.
    public var phase: Phase { lock.withLock { current } }

    /// Whether this instance is actually subscribed to anything.
    ///
    /// Exists because a `center: nil` argument at the one shipping call site is
    /// a one-word edit that makes the whole screen-lock fix a no-op in the
    /// binary while every behavioural test — which wires its own observer —
    /// carries on passing. `ShellTests` asserts it on the real `ShellServices`.
    public var isObservingForTesting: Bool { center != nil }

    /// Who is registered, in registration order.
    ///
    /// Identities rather than the listeners themselves, so reading this cannot
    /// extend anybody's life. Two things are only assertable through it, and
    /// both are load-bearing rather than incidental: that a lobby handed the
    /// façade a *live* observer at all — `activity: nil` at either call site
    /// compiles and ships a build where a lock kills the match — and that
    /// `OnlineMatch` registers the transport before the session, which is the
    /// order that puts the socket back up before any window resumes counting.
    public var listenerIdentitiesForTesting: [ObjectIdentifier] {
        lock.withLock { listeners.compactMap { $0.value.map(ObjectIdentifier.init) } }
    }

    /// Registers a listener. Held weakly: a match that ends while the app is
    /// backgrounded must not be kept alive by this list.
    public func add(_ listener: any AppActivityListener) {
        lock.withLock {
            listeners.removeAll { $0.value == nil }
            listeners.append(WeakListener(listener))
        }
    }

    /// Announces a phase, in registration order.
    ///
    /// Idempotent: the same phase twice changes nothing, so a duplicate
    /// notification — two scenes, a lock over an already-backgrounded app —
    /// cannot restart a grace window that is already running.
    public func send(_ phase: Phase) {
        let recipients: [any AppActivityListener] = lock.withLock {
            guard phase != current else { return [] }
            current = phase
            listeners.removeAll { $0.value == nil }
            return listeners.compactMap(\.value)
        }
        for listener in recipients { listener.appActivityChanged(to: phase) }
    }

    /// The enclosing context is nonisolated, so neither closure inherits
    /// `@MainActor` — see the note on ``AppActivityListener``.
    private func observe(_ center: NotificationCenter) {
        Self.assertNamesStillMatchUIKit()
        let away = center.addObserver(
            forName: Self.awayNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.send(.away) }
        let back = center.addObserver(
            forName: Self.activeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.send(.active) }
        lock.withLock { tokens.append(contentsOf: [away, back]) }
    }

    /// Debug-only, UIKit-only: proves the two string names above are still the
    /// ones UIKit posts. Free in release, and compiled by the `xcodebuild` gate
    /// even though no `swift test` host can see it.
    private static func assertNamesStillMatchUIKit() {
        #if canImport(UIKit)
        assert(awayNotification == UIApplication.didEnterBackgroundNotification)
        assert(activeNotification == UIApplication.willEnterForegroundNotification)
        #endif
    }

    deinit {
        guard let center else { return }
        for token in lock.withLock({ tokens }) { center.removeObserver(token) }
    }

    private struct WeakListener {
        weak var value: (any AppActivityListener)?
        init(_ value: any AppActivityListener) { self.value = value }
    }
}
