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
        GeometryReader { proxy in
            let layout = Layout(width: proxy.size.width)

            HStack(alignment: .top, spacing: DesignTokens.Space.xl) {
                identity(layout)

                Spacer(minLength: DesignTokens.Space.xl)

                actions
                    // The action column is fixed in proportion, not in points:
                    // two buttons with short labels, sized off the same measure
                    // as the rest so they neither strand mid-air on a 13-inch
                    // iPad nor crowd the mark on a phone.
                    .frame(width: layout.actionColumnWidth)
            }
            // Capped and centred rather than pinned to the screen edges. Past
            // the cap a wider device gets margin, not a wider dead band between
            // the two columns.
            .frame(maxWidth: layout.contentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DesignTokens.Space.xl)
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

    /// Every measure on this screen, derived from the width it actually got.
    ///
    /// One layout for every device rather than an iPad file and an iPhone file:
    /// there is no two-way split to make. iPad Pro 13-inch, iPad 11-inch, an
    /// iPhone in landscape and an iPad in Split View — which reports `.pad`
    /// while handing the app a phone-width window — are four different widths,
    /// and a size class answers none of them. The comp was drawn at
    /// ``compWidth``; everything here is that drawing read at the width to hand.
    private struct Layout {

        let contentWidth: CGFloat

        init(width: CGFloat) {
            contentWidth = min(width, MenuView.contentMaxWidth)
        }

        /// Clamped at both ends: the mark is the screen, so it may not shrink
        /// to a stamp on a phone or swell past the tagline on a 13-inch iPad.
        var wordmarkCell: CGFloat {
            min(max((contentWidth * 0.052).rounded(), 26), 64)
        }

        var taglineWidth: CGFloat { (contentWidth * 0.32).rounded() }

        var actionColumnWidth: CGFloat {
            min(max((contentWidth * 0.30).rounded(), 220), 340)
        }
    }

    private func identity(_ layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            Spacer(minLength: 0)

            WordmarkTiles(cell: layout.wordmarkCell)
                #if DEBUG
                // Quiet way in to the style gallery. No visible control, so it
                // adds nothing to the menu's two actions.
                .onLongPressGesture { showingStyleGallery = true }
                #endif

            Text(Self.tagline)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: layout.taglineWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
            Spacer(minLength: 0)

            Text(Self.actionsLabel)
                .monoLabel()

            // Into the setup screen, not into a match: what the far end plays
            // like and what the rules are get chosen before the deal, because
            // afterwards is too late to change either.
            Button { shell.showSoloSetup() } label: {
                Text(SoloSetup.title).menuActionLabel()
            }
            .buttonStyle(.brandPrimary)

            Button { shell.showHowToPlay() } label: {
                Text(HowToPlay.title).menuActionLabel()
            }
            .buttonStyle(.brandQuiet)

            Spacer(minLength: 0)
        }
    }

    /// Not `Terminology`: that file is the frozen IP fence and names game
    /// concepts, not screens. The two action labels are the screens' own
    /// chrome — `SoloSetup.title` and `HowToPlay.title`.
    private static let actionsLabel = "PLAY"

    /// The one sentence that says what the game is. The game concepts in it come
    /// through `Terminology`, so the fence holds here too.
    private static let tagline =
        "One shared \(Terminology.pool). One connected grid. First empty rack wins."

    /// The width the design comp was drawn at. Nothing is pinned to it — it is
    /// the ceiling the content stops growing at, so a wider screen adds margin
    /// rather than stretching a two-column menu across a metre of glass.
    private static let contentMaxWidth: CGFloat = 980
}

private extension View {

    /// The action column's buttons span it and stand at the comp's control
    /// height. The height is on the label because the button style owns the
    /// padding around it: 36 plus two `Space.s` insets is the 52pt control.
    func menuActionLabel() -> some View {
        frame(maxWidth: .infinity, minHeight: 36)
    }
}
