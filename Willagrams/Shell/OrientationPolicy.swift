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
}
