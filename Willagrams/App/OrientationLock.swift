import UIKit

/// The app's only `UIApplicationDelegate`, and all it does is answer which
/// orientations are allowed right now. `ShellRootView` sets ``mask`` whenever the
/// route crosses into or out of gameplay.
final class OrientationLock: NSObject, UIApplicationDelegate {

    @MainActor static var mask: UIInterfaceOrientationMask = .all

    /// The one place the idiom is read (App only, by rule).
    @MainActor static func mask(isGameplay: Bool) -> UIInterfaceOrientationMask {
        OrientationPolicy.mask(
            isGameplay: isGameplay,
            isPad: UIDevice.current.userInterfaceIdiom == .pad
        ).uiMask
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.mask
    }
}

extension OrientationPolicy {
    var uiMask: UIInterfaceOrientationMask {
        switch self {
        case .portrait: .portrait
        case .landscape: .landscape
        }
    }
}
