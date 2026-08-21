import SwiftUI

/// The root screen: the wordmark, the one thing the app can currently play, and
/// the rules for it.
///
/// No Host, Join or Settings row. There is no `GKMatchTransport` behind the
/// first two and no settings surface behind the third, and a disabled control
/// is a promise someone has to keep, then delete.
///
/// The view makes no routing decision: the action calls a ``ShellModel``
/// transition and the route it produces is asserted in `ShellModelTests`.
///
/// Laid out in two columns because the app is landscape-only: the mark and what
/// the game is on the left, the two things you can do on the right. A centred
/// stack in a 4:3 landscape frame leaves the width unused and pushes the
/// actions below the optical centre.
struct MenuView: View {

    let shell: ShellModel

    #if DEBUG
    @State private var showingStyleGallery = false
    #endif

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.xl) {
            identity

            Spacer(minLength: DesignTokens.Space.xl)

            actions
                // The action column is fixed rather than proportional: these
                // are two buttons with short labels, and a column that grows
                // with the iPad's width would strand them mid-air.
                .frame(width: Self.actionColumnWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, DesignTokens.Space.xl + DesignTokens.Space.l)
        .padding([.top, .trailing, .bottom], DesignTokens.Space.xl)
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

    private var identity: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            Spacer(minLength: 0)

            WordmarkTiles(cell: Self.wordmarkCell)
                #if DEBUG
                // Quiet way in to the style gallery. No visible control, so it
                // adds nothing to the menu's two actions.
                .onLongPressGesture { showingStyleGallery = true }
                #endif

            Text(Self.tagline)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.taglineWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
            Spacer(minLength: 0)

            Text(Self.actionsLabel)
                .monoLabel()

            Button { shell.startSoloPractice() } label: {
                Text(Self.soloPracticeLabel).menuActionLabel()
            }
            .buttonStyle(.brandPrimary)

            Button { shell.showHowToPlay() } label: {
                Text(HowToPlay.title).menuActionLabel()
            }
            .buttonStyle(.brandQuiet)

            Spacer(minLength: 0)
        }
    }

    /// Local copy, not `Terminology`: that file is the frozen IP fence and names
    /// game concepts, not screens. The rules row's label is `HowToPlay.title`,
    /// which is that screen's own chrome.
    private static let soloPracticeLabel = "Solo Practice"
    private static let actionsLabel = "PLAY"

    /// The one sentence that says what the game is. The game concepts in it come
    /// through `Terminology`, so the fence holds here too.
    private static let tagline =
        "One shared \(Terminology.pool). One connected grid. First empty rack wins."

    private static let wordmarkCell: CGFloat = 30
    private static let taglineWidth: CGFloat = 320
    private static let actionColumnWidth: CGFloat = 300
}

private extension View {

    /// The action column's buttons span it and stand at the comp's control
    /// height. The height is on the label because the button style owns the
    /// padding around it: 36 plus two `Space.s` insets is the 52pt control.
    func menuActionLabel() -> some View {
        frame(maxWidth: .infinity, minHeight: 36)
    }
}
