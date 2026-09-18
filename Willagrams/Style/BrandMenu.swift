import SwiftUI

/// A dropdown that reads as Willagrams rather than as stock iOS.
///
/// **Why a popover and not a hand-built panel.** `Menu` renders UIKit's system
/// popup, which ignores `DesignTokens` entirely — that is the whole complaint.
/// A `.popover` held to popover form in compact width is the smallest thing
/// that lets us draw the rows ourselves while the system keeps the parts worth
/// keeping: anchoring to the trigger, flipping near a screen edge, dismissal on
/// an outside tap, and the presentation's own `DismissAction`.
///
/// **The content is built eagerly, in the caller's `body`.** `Menu` builds its
/// content when it opens, which is outside the owning view's observation
/// tracking — that is why the invite picker used to read its friend list into a
/// local first. Taking the content as a value in `init` moves that build back
/// into the caller's `body`, so an `@Observable` read inside it registers like
/// any other. Do not make `content` a stored closure without restoring those
/// locals at every call site.
public struct BrandMenu<Label: View, Content: View>: View {

    /// Narrow enough for a two-word action, wide enough that a display name
    /// does not wrap on the first row.
    public static var minimumWidth: CGFloat { 200 }

    @State private var isOpen = false

    private let label: Label
    private let content: Content

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    public var body: some View {
        Button { isOpen = true } label: { label }
            .popover(isPresented: $isOpen) {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.vertical, DesignTokens.Space.s)
                    .frame(minWidth: Self.minimumWidth, alignment: .leading)
                    .presentationCompactAdaptation(.popover)
                    .presentationBackground(DesignTokens.Palette.surface)
            }
    }
}

/// One action inside a `BrandMenu`. Full-bleed row, brand type, pressed fill.
public struct BrandMenuRow: View {

    @Environment(\.dismiss) private var dismiss

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
            // popover, and a dismissal asked for after that never lands.
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
