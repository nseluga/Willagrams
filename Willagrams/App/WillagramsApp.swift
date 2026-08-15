import SwiftUI
import WillagramsRules

@main
struct WillagramsApp: App {

    init() {
        BrandFonts.registerOnce()
    }

    var body: some Scene {
        WindowGroup {
            // Replaced by the shell lane, which owns the real root. Until it
            // lands, the style lane's proof surface is the app: it is the only
            // way to see the tokens render in both themes on a device.
            StyleGallery()
        }
    }
}
