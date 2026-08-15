import SwiftUI
import WillagramsRules

@main
struct WillagramsApp: App {

    init() {
        BrandFonts.registerOnce()
    }

    var body: some Scene {
        WindowGroup {
            // Replaced by the shell lane. Present only so the scaffold builds
            // and links against WillagramsRules.
            Text(verbatim: "Willagrams")
        }
    }
}
