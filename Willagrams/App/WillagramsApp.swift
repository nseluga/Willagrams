import SwiftUI

@main
struct WillagramsApp: App {

    /// One `ShellModel` per launch, owned here and read by `ShellRootView`.
    /// A `@State` on the `App` value is constructed once however many times
    /// `body` is evaluated, so the route survives every re-render.
    @State private var shell = ShellModel()

    init() {
        // Must stay on the launch path: without it every custom face falls
        // back to San Francisco, silently. `registerOnce` is idempotent.
        BrandFonts.registerOnce()
    }

    var body: some Scene {
        WindowGroup {
            ShellRootView(shell: shell)
        }
    }
}
