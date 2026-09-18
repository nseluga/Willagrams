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
    @State private var anchor: CGRect = .zero

    private let label: Label
    private let content: Content

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    public var body: some View {
        Button { setOpen(true) } label: { label }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: BrandMenuAnchorKey.self,
                        value: proxy.frame(in: .global)
                    )
                }
            }
            .onPreferenceChange(BrandMenuAnchorKey.self) { anchor = $0 }
            .fullScreenCover(isPresented: $isOpen) {
                BrandMenuPanel(anchor: anchor, close: { setOpen(false) }) { content }
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

    let anchor: CGRect
    let close: () -> Void
    let content: Content

    init(anchor: CGRect, close: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.anchor = anchor
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

            ZStack(alignment: .topLeading) {
                DesignTokens.Palette.ink.opacity(Self.dimOpacity)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.vertical, DesignTokens.Space.s)
                    .frame(width: BrandMenuMetrics.panelWidth, alignment: .leading)
                    .brandCard()
                    .background {
                        GeometryReader { panel in
                            Color.clear.preference(
                                key: BrandMenuHeightKey.self,
                                value: panel.size.height
                            )
                        }
                    }
                    .offset(x: x(in: size, origin: origin), y: y(in: size, origin: origin))
                    // Hidden for the one frame before the height is known,
                    // which is the frame that would otherwise flash the panel
                    // at the wrong end of the trigger.
                    .opacity(panelHeight > 0 ? 1 : 0)
                    .animation(DesignTokens.Motion.snap, value: panelHeight > 0)
            }
            .onPreferenceChange(BrandMenuHeightKey.self) { panelHeight = $0 }
        }
        .presentationBackground(.clear)
    }

    /// Trailing edges aligned — both triggers sit at the trailing end of their
    /// row — then pulled back inside the screen margins if that would hang the
    /// panel off an edge. This is the hand-rolled half of what the system
    /// popover did for free.
    private func x(in size: CGSize, origin: CGPoint) -> CGFloat {
        let width = BrandMenuMetrics.panelWidth
        let preferred = anchor.maxX - origin.x - width
        let limit = size.width - width - Self.margin
        return min(max(preferred, Self.margin), max(limit, Self.margin))
    }

    /// Below the trigger when the panel fits there, above it when it does not.
    /// A row near the bottom of a friends list is the case that needs it.
    private func y(in size: CGSize, origin: CGPoint) -> CGFloat {
        let below = anchor.maxY - origin.y + Self.gap
        guard below + panelHeight + Self.margin > size.height else { return below }
        let above = anchor.minY - origin.y - panelHeight - Self.gap
        return max(above, Self.margin)
    }

    private static var dimOpacity: Double { 0.35 }
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

private struct BrandMenuAnchorKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct BrandMenuHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
