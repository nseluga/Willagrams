import SwiftUI

/// The root screen: the wordmark, the one thing the app can currently play, and
/// a way into the rules.
///
/// No Host or Join row — there is no `GKMatchTransport` behind either, and a
/// disabled control is a promise someone has to keep, then delete. There is no
/// Settings row either: the settings that exist are the ones a solo match is
/// played under, and they are on the way into that match rather than parked in
/// a screen of their own.
///
/// The rules are a mark in the corner rather than a second full-width button.
/// One action reads as one action; two equally loud buttons read as a choice,
/// and the rules are not one — they are the thing you glance at on the way.
///
/// The view makes no routing decision: the action calls a ``ShellModel``
/// transition and the route it produces is asserted in `ShellModelTests`.
struct MenuView: View {

    let shell: ShellModel

    #if DEBUG
    @State private var showingStyleGallery = false
    #endif

    var body: some View {
        // The mark is sized from the space it is given rather than from a
        // constant, so it fills a landscape iPhone and an iPad alike instead of
        // sitting small in the middle of either.
        GeometryReader { proxy in
            VStack(spacing: DesignTokens.Space.l) {
                WordmarkView(tileSize: tileSize(in: proxy.size))
                    #if DEBUG
                    // Quiet way in to the style gallery. No visible control, so
                    // it adds nothing to the menu's two actions.
                    .onLongPressGesture { showingStyleGallery = true }
                    #endif

                // Into the setup screen, not into a match: what the far end
                // plays like and what the rules are get chosen before the deal,
                // because afterwards is too late to change either.
                Button(SoloSetup.title) { shell.showSoloSetup() }
                    .buttonStyle(.brandPrimary)
            }
            .padding(DesignTokens.Space.m)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // The rules, top-trailing. An overlay rather than a row in the stack,
        // so it sits in the corner without moving the wordmark off centre.
        .overlay(alignment: .topTrailing) {
            Button { shell.showHowToPlay() } label: {
                Image(systemName: Self.rulesSymbol)
                    .font(DesignTokens.Typography.title)
            }
            .buttonStyle(.brandText)
            .padding(DesignTokens.Space.m)
            .accessibilityLabel(HowToPlay.title)
        }
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

    /// The largest tile that leaves the mark inside the screen with room for
    /// the button under it. The grid is `Wordmark`'s, so a mark that grew a
    /// column would be fitted for without touching this.
    private func tileSize(in size: CGSize) -> CGFloat {
        let across = size.width / (CGFloat(Wordmark.columns) * Self.seamed)
        let down = (size.height - Self.chrome) / (CGFloat(Wordmark.rows) * Self.seamed)
        return max(Self.minimumTile, min(across, down))
    }

    private static let minimumTile: CGFloat = 24

    /// The button under the mark, the gap over it and the screen padding. The
    /// mark takes what is left, which is what keeps it off the bottom edge in
    /// landscape.
    private static let chrome: CGFloat = 120

    /// One tile plus its seam, matching `WordmarkView`'s own step. Fitting to
    /// the bare tile size would size the mark for a grid with no gaps in it.
    private static let seamed: CGFloat = 1.06

    /// The rules mark. The screen's own name is `HowToPlay.title`, which is what
    /// the control announces to VoiceOver — the glyph is the drawing of it, not
    /// a second name for it.
    private static let rulesSymbol = "questionmark.circle"
}
