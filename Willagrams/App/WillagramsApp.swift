import SwiftUI

@main
struct WillagramsApp: App {

    /// One `ShellModel` per launch, owned here and read by `ShellRootView`.
    /// A `@State` on the `App` value is constructed once however many times
    /// `body` is evaluated, so the route survives every re-render.
    @State private var shell: ShellModel

    init() {
        // Must stay on the launch path: without it every custom face falls
        // back to San Francisco, silently. `registerOnce` is idempotent.
        BrandFonts.registerOnce()

        // The one place in the app that builds a service. Exactly one backend,
        // one player and one settings store exist per process; every screen
        // reads them off `ShellModel.services`.
        let backend = SupabaseBackend()
        let audio = SystemAudioPlayer(muted: AudioSettings(defaults: .standard).isMuted)
        _shell = State(
            initialValue: ShellModel(
                services: ShellServices(
                    backend: backend,
                    audio: audio,
                    settings: SettingsStore(defaults: .standard),
                    signIn: ShellServices.anonymousSignIn(backend),
                    // A factory, not a channel: the topic is named for the
                    // signed-in player, who is not known until sign-in lands.
                    inviteChannel: { backend.inviteChannel(for: $0) }
                )
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ShellRootView(shell: shell)
        }
    }
}
