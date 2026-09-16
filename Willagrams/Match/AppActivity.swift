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
//  Never imports SwiftUI. `UIApplication` is behind `canImport(UIKit)`, which
//  is false for the macOS test host, so the notification half simply is not
//  built there and `send(_:)` is the whole surface a test needs.
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
        #if canImport(UIKit)
        let away = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.send(.away) }
        let back = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.send(.active) }
        lock.withLock { tokens.append(contentsOf: [away, back]) }
        #endif
    }

    deinit {
        guard let center else { return }
        for token in tokens { center.removeObserver(token) }
    }

    private struct WeakListener {
        weak var value: (any AppActivityListener)?
        init(_ value: any AppActivityListener) { self.value = value }
    }
}
