// Plain on purpose: `Tests/ShellTests` builds this for macOS, where there is no
// `UIInterfaceOrientationMask`. `Willagrams/App/OrientationLock.swift` maps the
// answer onto the mask.

/// Which way the app may face.
public enum OrientationPolicy: Equatable, Sendable {
    case portrait
    case landscape

    /// iPad is landscape on every route; iPhone is landscape only in a match.
    public static func mask(isGameplay: Bool, isPad: Bool) -> OrientationPolicy {
        if isPad { return .landscape }
        return isGameplay ? .landscape : .portrait
    }

    /// Reports a rejected geometry request. A rejected rotation is not fatal —
    /// the mask still applies on the next opportunity — but a persistent
    /// rejection stays visible instead of silent.
    ///
    /// `nonisolated` is the whole point of this living here rather than in a
    /// closure inside `ShellRootView`: UIKit calls `requestGeometryUpdate`'s
    /// error handler on whatever executor it likes (`com.apple.root.default-qos`
    /// on an iPad, where the request is rejected), and a handler that inherited
    /// `@MainActor` from its enclosing view trapped in `dispatch_assert_queue`
    /// and killed the app at launch. This touches nothing isolated, so it is
    /// safe on any executor.
    public nonisolated static func report(rejection error: any Error) {
        debugPrint("orientation: requestGeometryUpdate failed: \(error)")
    }
}
