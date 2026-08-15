import UIKit

/// The hardware behind `BoardHaptics`.
///
/// UIKit is confined to this file. `BoardDrag.swift` decides WHEN each feel
/// fires and stays host-compilable so a test can execute those decisions; this
/// only turns a decision into a buzz.
public struct TileFeedback: BoardHaptics {

    public init() {}

    /// Three generators, not one: a pickup, a landed move and a refused drop
    /// have to be told apart by the hand alone, so a light tap, a firmer tap
    /// and the system's error pattern are deliberately different feels.
    ///
    /// `assumeIsolated` rather than an async hop: every caller is a SwiftUI
    /// gesture callback, which already runs on the main actor, and a hop would
    /// put the buzz a frame or more behind the finger.
    public func fire(_ event: BoardHapticEvent) {
        MainActor.assumeIsolated {
            switch event {
            case .pickup:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .snap:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .reject:
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
