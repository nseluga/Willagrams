import SwiftUI

/// A dropdown drawn entirely by us: no system bubble, no system chrome.
///
/// **Why nothing of UIKit's is left.** `Menu` renders UIKit's popup and
/// `.popover` renders UIKit's bubble — arrow, material, shadow and corner all
/// belong to `UIPopoverPresentationController`, and no SwiftUI modifier reaches
/// them. Colouring the rows inside either one leaves the container reading as
/// stock iOS. So the panel here is a `.brandCard()` over a scrim, positioned by
/// hand against the trigger's own frame.
///
/// **Why it is presented rather than overlaid.** A friend row is clipped by
/// `.brandCard()` and again by the scroll view above it, so a panel drawn in
/// place would be cut off at the row's edge. A full-screen presentation with a
/// cleared background is the one way out of that clipping that does not make
/// every screen host an overlay of its own. Its slide-up is suppressed at each
/// state change, so the panel fades in where it was anchored instead.
///
/// **The content is built eagerly, in the caller's `body`.** `Menu` built its
/// content when it opened, outside the owning view's observation tracking —
/// that is why the invite picker read its friend list into a local first.
/// Taking the content as a value in `init` moves that build back into the
/// caller's `body`, so an `@Observable` read inside it registers like any
/// other. Do not make `content` a stored closure without restoring those
/// locals at every call site.
public struct BrandMenu<Label: View, Content: View>: View {

    @State private var isOpen = false
    @State private var box = BrandMenuAnchorBox()

    private let label: Label
    private let content: Content


    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    public var body: some View {
        Button { setOpen(true) } label: { label }
            .background(BrandMenuAnchorReader(box: box))
            .fullScreenCover(isPresented: $isOpen) {
                BrandMenuPanel(box: box, close: { setOpen(false) }) { content }
                    .environment(\.brandMenuDismiss) { setOpen(false) }
            }
    }

    /// Opens and closes without the modal slide a full-screen cover would
    /// otherwise animate. The panel runs its own fade instead, so the change
    /// has to arrive unanimated — scoped to this one write rather than
    /// disabling animation for the trigger's whole subtree.
    private func setOpen(_ open: Bool) {
        var silent = Transaction()
        silent.disablesAnimations = true
        withTransaction(silent) { isOpen = open }
    }
}

/// The panel itself: scrim, card, and the arithmetic that puts the card under
/// the trigger rather than in the middle of the screen.
private struct BrandMenuPanel<Content: View>: View {

    let box: BrandMenuAnchorBox
    let close: () -> Void
    let content: Content

    init(box: BrandMenuAnchorBox, close: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.box = box
        self.close = close
        self.content = content()
    }

    @State private var panelHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            // The cover's own origin in the same space the anchor was measured
            // in. Subtracting it is what makes a `.global` rect usable as an
            // offset inside a presentation that may sit below the status bar.
            let origin = proxy.frame(in: .global).origin
            let size = proxy.size
            // Read at render, not at the tap: `fullScreenCover` builds its
            // content from the body evaluation that preceded the presentation,
            // so a value written in the same tick as `isOpen` arrives stale.
            let anchor = box.frame

            ZStack(alignment: .topLeading) {
                // Catches the tap that dismisses, and nothing else: the
                // screen behind the panel stays at its normal brightness, so
                // the outline below is what separates the two.
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.vertical, DesignTokens.Space.s)
                    .frame(width: BrandMenuMetrics.panelWidth, alignment: .leading)
                    .brandCard()
                    // The card's own border is a hairline meant to sit against
                    // a page. Over live content it disappears, so the panel
                    // takes the accent at selection weight instead.
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: DesignTokens.Radius.panel,
                            style: .continuous
                        )
                        .strokeBorder(
                            DesignTokens.Palette.accent,
                            lineWidth: DesignTokens.Stroke.selectionBorder
                        )
                    }
                    .background {
                        GeometryReader { panel in
                            Color.clear
                                .onAppear { panelHeight = panel.size.height }
                                .onChange(of: panel.size.height) { _, now in
                                    panelHeight = now
                                }
                        }
                    }
                    .offset(x: x(anchor, in: size, origin: origin), y: y(anchor, in: size, origin: origin))
                    // Hidden for the one frame before the height is known,
                    // which is the frame that would otherwise flash the panel
                    // at the wrong end of the trigger.
                    .opacity(panelHeight > 0 ? 1 : 0)
                    .animation(DesignTokens.Motion.snap, value: panelHeight > 0)
            }
        }
        .presentationBackground(.clear)
    }

    /// Trailing edges aligned — both triggers sit at the trailing end of their
    /// row — then pulled back inside the screen margins if that would hang the
    /// panel off an edge. This is the hand-rolled half of what the system
    /// popover did for free.
    private func x(_ anchor: CGRect, in size: CGSize, origin: CGPoint) -> CGFloat {
        let width = BrandMenuMetrics.panelWidth
        let preferred = anchor.maxX - origin.x - width
        let limit = size.width - width - Self.margin
        return min(max(preferred, Self.margin), max(limit, Self.margin))
    }

    /// Below the trigger when the panel fits there, above it when it does not.
    /// A row near the bottom of a friends list is the case that needs it.
    private func y(_ anchor: CGRect, in size: CGSize, origin: CGPoint) -> CGFloat {
        let below = anchor.maxY - origin.y + Self.gap
        guard below + panelHeight + Self.margin > size.height else { return below }
        let above = anchor.minY - origin.y - panelHeight - Self.gap
        return max(above, Self.margin)
    }

    private static var gap: CGFloat { DesignTokens.Space.s }
    private static var margin: CGFloat { DesignTokens.Space.m }
}

/// The panel's fixed metrics, out here because the panel and the arithmetic
/// that places it both need them and neither owns the other.
public enum BrandMenuMetrics {

    /// Wide enough for a display name at body size, narrow enough to sit under
    /// a trigger on a 375pt phone with both margins intact.
    public static let panelWidth: CGFloat = 240
}

/// One action inside a `BrandMenu`. Full-bleed row, brand type, pressed fill.
public struct BrandMenuRow: View {

    @Environment(\.brandMenuDismiss) private var dismiss

    private let title: String
    private let role: ButtonRole?
    private let action: () -> Void

    public init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(role: role) {
            // Dismiss first. An action can tear down the view that owns this
            // panel, and a dismissal asked for after that never lands.
            dismiss()
            action()
        } label: {
            Text(title)
        }
        .buttonStyle(BrandMenuRowStyle())
    }
}

/// A caption inside a `BrandMenu` — an empty list's explanation, not an action.
public struct BrandMenuCaption: View {

    private let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Space.m)
            .padding(.vertical, DesignTokens.Space.s)
    }
}

/// The row treatment, kept out of `ButtonStyles` because it is not one of the
/// three controls: it fills its row rather than sizing to its label, and it
/// takes its ink from the button's own `role`.
private struct BrandMenuRowStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignTokens.Typography.body)
            .foregroundStyle(
                configuration.role == .destructive
                    ? DesignTokens.Palette.danger
                    : DesignTokens.Palette.ink
            )
            .lineLimit(ButtonLabelFit.lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Space.m)
            .padding(.vertical, DesignTokens.Space.s)
            .background(configuration.isPressed ? DesignTokens.Palette.cellEmpty : .clear)
            .contentShape(Rectangle())
            .animation(DesignTokens.Motion.snap, value: configuration.isPressed)
    }
}

/// Closing is the panel's own business, not the presentation's: `DismissAction`
/// would animate the cover back out, and the fade belongs to the card.
private struct BrandMenuDismissKey: EnvironmentKey {
    // `@MainActor` is what makes the closure type `Sendable`, which a static
    // default has to be. It costs nothing: every caller is already on the main
    // actor, being a SwiftUI body.
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    var brandMenuDismiss: @MainActor () -> Void {
        get { self[BrandMenuDismissKey.self] }
        set { self[BrandMenuDismissKey.self] = newValue }
    }
}

/// Where the trigger is, in window coordinates, asked whenever the panel draws.
///
/// `GeometryProxy.frame(in: .global)` cannot do this job: it reads `.zero`
/// until the view is in a window, and a view whose geometry never changes
/// afterwards is never re-evaluated, so an anchor measured at `onAppear` can
/// stay zero for the life of the screen — which put the panel in the top-left
/// corner. Nor can the frame be measured at the tap and handed over as a
/// value: the cover builds its content from the body evaluation *before* the
/// presentation, so a rect written in the same tick as `isOpen` arrives stale
/// and lands the panel in that same corner. A reference read at draw time is
/// immune to both, because a `UIView` knows its window whenever it is asked.
@MainActor final class BrandMenuAnchorBox {

    fileprivate weak var view: UIView?

    var frame: CGRect {
        guard let view, let window = view.window else { return .zero }
        return view.convert(view.bounds, to: window)
    }
}

private struct BrandMenuAnchorReader: UIViewRepresentable {

    let box: BrandMenuAnchorBox

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        box.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        box.view = view
    }
}

