import SwiftUI
import UIKit

/// The live pinch: how far the fingers have spread since they landed, AND where
/// their midpoint is RIGHT NOW.
///
/// SwiftUI's `MagnifyGesture` reports only `startLocation` — the midpoint at the
/// instant the second finger landed, frozen for the rest of the gesture. So a
/// pinch could zoom about where it began and nothing more: two fingers that
/// spread AND slid zoomed correctly and then left the board where it was, which
/// is why zooming and scrolling could not be done in one motion. UIKit's
/// `UIPinchGestureRecognizer` answers `location(in:)` every frame, which is the
/// one thing missing, so this reports it back and `BoardView` composes the zoom
/// and the pan itself.
///
/// The recognizer goes on the WINDOW, not on the view this makes. A UIKit view
/// laid over the board would hit-test first and swallow every touch before
/// SwiftUI's drag saw it — the tiles would stop lifting. This view is inert
/// (`isUserInteractionEnabled = false`) and exists only to name a coordinate
/// space: the recognizer watches an ancestor, `cancelsTouchesInView` is off and
/// simultaneous recognition is allowed, so the drag underneath keeps every touch
/// it had while the midpoints are reported in the board's own coordinates.
struct BoardPinchReporter: UIViewRepresentable {

    /// Cumulative scale since the fingers landed, and their current midpoint in
    /// this view's coordinate space.
    let onChange: (CGFloat, CGPoint) -> Void

    /// The fingers left, or the recognizer was cancelled. Both end the pinch:
    /// there is no half-finished pinch to carry forward.
    let onEnd: () -> Void

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        // There is no window yet inside `makeUIView`. UIKit says exactly when
        // there is one, so ask it rather than hopping a run loop and hoping.
        view.onEnterWindow = { [weak view] in
            guard let view else { return }
            context.coordinator.attach(reporting: view)
        }
        return view
    }

    /// A view that does nothing but say when it joins a window.
    final class Surface: UIView {
        var onEnterWindow: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onEnterWindow?() }
        }
    }

    func updateUIView(_ uiView: Surface, context: Context) {
        // The closures capture `BoardView` state that changes every frame, so
        // the coordinator is re-pointed at the current ones rather than holding
        // whatever it was built with.
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
        // Attach here too. `makeUIView` runs before this view is in a window,
        // and a single run-loop hop after it is a guess about when SwiftUI got
        // around to inserting it — a guess that, when wrong, leaves a pinch
        // that silently never fires. `attach` is idempotent, so retrying on
        // every update costs one nil check and removes the timing question.
        context.coordinator.attach(reporting: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onEnd: onEnd)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {

        var onChange: (CGFloat, CGPoint) -> Void
        var onEnd: () -> Void

        /// The inert view whose coordinate space the midpoints are reported in.
        private weak var surface: UIView?

        init(onChange: @escaping (CGFloat, CGPoint) -> Void, onEnd: @escaping () -> Void) {
            self.onChange = onChange
            self.onEnd = onEnd
        }

        func attach(reporting view: UIView) {
            // The window, not the immediate superview. A recognizer only sees
            // touches whose hit-test view is its own view or a descendant, and
            // what SwiftUI puts directly above an overlay's representable is an
            // implementation detail that need not be an ancestor of the tiles —
            // when it is not, every pinch lands somewhere the recognizer cannot
            // see and nothing happens at all. The window is an ancestor of the
            // board by definition. Midpoints are still reported in this view's
            // space, so where the recognizer lives changes nothing downstream.
            guard let host = view.window, surface == nil else { return }
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handle(_:)))
            pinch.delegate = self
            // The touches must keep flowing to SwiftUI underneath. Without this
            // the drag is cancelled the moment the recognizer takes hold, which
            // is the behaviour being replaced, not kept.
            pinch.cancelsTouchesInView = false
            pinch.delaysTouchesBegan = false
            pinch.delaysTouchesEnded = false
            host.addGestureRecognizer(pinch)
            surface = view
        }

        @objc func handle(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                // Two touches or it is not a midpoint. A recognizer reporting a
                // `.changed` as a finger lifts would hand back the position of
                // the one that is left, and the board would jump to it.
                guard recognizer.numberOfTouches >= 2, let surface else { return }
                let scale = recognizer.scale
                guard scale.isFinite, scale > 0 else { return }
                onChange(scale, recognizer.location(in: surface))
            case .ended, .cancelled, .failed:
                onEnd()
            default:
                break
            }
        }

        /// The drag, the double tap and this pinch all watch the same touches.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
