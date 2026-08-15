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
    /// Held rather than built per event. A generator constructed and fired in
    /// the same breath wakes the Taptic Engine on the event itself, which lands
    /// the buzz behind the finger. Pickup opens every drag, so warming the other
    /// two there puts the feel that actually resolves the drag on time.
    @MainActor private static var pickupGenerator = UIImpactFeedbackGenerator(style: .light)
    @MainActor private static let snapGenerator = UIImpactFeedbackGenerator(style: .medium)
    @MainActor private static let rejectGenerator = UINotificationFeedbackGenerator()

    /// Every caller is a SwiftUI gesture callback and already on the main actor,
    /// so the ordinary path stays synchronous — a hop would put the buzz a frame
    /// or more behind the finger.
    ///
    /// Off the main actor it hops instead of trapping. `MainActor.assumeIsolated`
    /// would crash there, and `BoardHaptics.fire` is nonisolated on a `Sendable`
    /// type: nothing structurally stops a later caller from arriving off-main,
    /// and a missed buzz must never take the app down with it.
    public func fire(_ event: BoardHapticEvent) {
        guard Thread.isMainThread else {
            Task { @MainActor in Self.play(event) }
            return
        }
        MainActor.assumeIsolated { Self.play(event) }
    }

    @MainActor
    private static func play(_ event: BoardHapticEvent) {
        switch event {
        case .pickup:
            pickupGenerator.impactOccurred()
            // A drag has started, so one of these two is the next feel to fire.
            snapGenerator.prepare()
            rejectGenerator.prepare()
        case .snap:
            snapGenerator.impactOccurred()
        case .reject:
            rejectGenerator.notificationOccurred(.error)
        }
    }
}
