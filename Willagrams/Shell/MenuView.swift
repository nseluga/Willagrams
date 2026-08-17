import SwiftUI

/// The root screen: the wordmark and the one thing the app can currently do.
///
/// No Host, Join or Settings row. There is no `GKMatchTransport` behind the
/// first two and no settings surface behind the third, and a disabled control
/// is a promise someone has to keep, then delete.
///
/// The view makes no routing decision: the action calls a ``ShellModel``
/// transition and the route it produces is asserted in `ShellModelTests`.
struct MenuView: View {

    let shell: ShellModel

    #if DEBUG
    @State private var showingStyleGallery = false
    #endif

    var body: some View {
        VStack(spacing: DesignTokens.Space.xl) {
            Text(Self.title)
                .font(DesignTokens.Typography.display)
                .tracking(DesignTokens.Typography.displayTracking)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .lineLimit(1)
                .allowsTightening(true)
                .accessibilityAddTraits(.isHeader)
                #if DEBUG
                // Quiet way in to the style gallery. No visible control, so the
                // menu still offers exactly one thing.
                .onLongPressGesture { showingStyleGallery = true }
                #endif

            Button(Self.soloPracticeLabel) { shell.startSoloPractice() }
                .buttonStyle(.brandPrimary)
        }
        // Relative sizing only: landscape iPhone through landscape iPad, no
        // assumed viewport. The stack is intrinsically sized and centred.
        .padding(DesignTokens.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(
                colors: [DesignTokens.Palette.canvasTop, DesignTokens.Palette.canvasBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        #if DEBUG
        .sheet(isPresented: $showingStyleGallery) { StyleGallery() }
        #endif
    }

    /// Local copy, not `Terminology`: that file is the frozen IP fence and names
    /// game concepts, not screens.
    private static let title = "Willagrams"
    private static let soloPracticeLabel = "Solo Practice"
}
