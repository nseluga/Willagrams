import SwiftUI

/// The bar every non-menu screen starts with: a way back on the left, the
/// screen's name next to it, and an optional mono label pinned right for
/// whatever that screen counts — a page number, a pool size, a status.
///
/// It takes a closure rather than a route because `Style` knows nothing about
/// navigation, and it takes the back title as a string because the words on
/// this app's screens live in the shell, not here.
public struct ScreenHeader<Trailing: View>: View {

    private let title: String
    private let backTitle: String
    private let onBack: () -> Void
    private let trailing: Trailing

    public init(
        title: String,
        backTitle: String,
        onBack: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.backTitle = backTitle
        self.onBack = onBack
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.m) {
            Button(backTitle, action: onBack)
                .buttonStyle(.brandText)

            Text(title)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: DesignTokens.Space.m)

            trailing
        }
    }
}

public extension ScreenHeader where Trailing == EmptyView {

    /// A header with nothing to count on the right.
    init(title: String, backTitle: String, onBack: @escaping () -> Void) {
        self.init(title: title, backTitle: backTitle, onBack: onBack) { EmptyView() }
    }
}
