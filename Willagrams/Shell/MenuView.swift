import SwiftUI

/// The root screen: the wordmark and the six things Home can do —
/// ``MenuLayout/actions``, in that fixed order.
///
/// On a portrait phone it is one column: the mute control top-right, the
/// wordmark near the top sized from the available width, a flexible gap,
/// then the PLAY actions anchored to the bottom. On a landscape phone or an
/// iPad it stays the existing two-column layout — the mark on the left, the
/// actions on the right — with the same six slots.
///
/// There is no Join row: Join a Friend is reached from the Play a Friend
/// screen, not from Home. There is no Settings row either: the settings that
/// exist are the ones a solo match is played under, and they are on the way
/// into that match rather than parked in a screen of their own.
///
/// The view makes no routing decision: each action calls a ``ShellModel``
/// transition and the route it produces is asserted in `ShellModelTests`.
struct MenuView: View {

    let shell: ShellModel

    #if DEBUG
    @State private var showingStyleGallery = false
    #endif

    var body: some View {
        GeometryReader { proxy in
            let layout = MenuLayout(size: proxy.size)

            // The compact grid and the smaller wordmark/spacing are the
            // primary sizing mechanism — they are what fits a landscape
            // phone. `ViewThatFits` stays only as the fallback for the
            // largest accessibility Dynamic Type sizes, where scrolling
            // beats clipping.
            if layout.isPortrait {
                ViewThatFits(in: .vertical) {
                    portraitColumn(layout)
                    ScrollView { portraitColumn(layout) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .screenPadding()
            } else {
                let widths = WidthLayout(width: proxy.size.width)
                ViewThatFits(in: .vertical) {
                    columns(widths, layout)
                    ScrollView { columns(widths, layout) }
                }
                // Capped and centred rather than pinned to the screen edges.
                // Past the cap a wider device gets margin, not a wider dead
                // band between the two columns.
                .frame(maxWidth: widths.contentWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .screenPadding()
            }
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
    private struct WidthLayout {

        let contentWidth: CGFloat

        init(width: CGFloat) {
            contentWidth = min(width, MenuView.contentMaxWidth)
        }

        /// Kept in sync by hand with `MenuLayout`'s own width clamp for the
        /// wordmark — see the note there on why the two can't share code.
        var identityColumnWidth: CGFloat {
            min(max((contentWidth * 0.34).rounded(), 260), 420)
        }

        var actionColumnWidth: CGFloat {
            min(max((contentWidth * 0.30).rounded(), 220), 340)
        }
    }

    /// The two columns as a centered group with a fixed gutter between them
    /// — not an expanding spacer stretched to the content width, which is
    /// what used to strand the mark in the top-left corner and the actions
    /// against the right edge with a dead gap in between. Both columns have
    /// a bounded width, so the `HStack`'s intrinsic width is less than the
    /// screen's, and the enclosing `.frame(maxWidth: .infinity)` centers it.
    private func columns(_ widths: WidthLayout, _ layout: MenuLayout) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.xl) {
            identity(widths, layout)
                .frame(width: widths.identityColumnWidth)

            actions(layout)
                // The action column is fixed in proportion, not in points:
                // two buttons with short labels, sized off the same measure
                // as the rest so they neither strand mid-air on a 13-inch
                // iPad nor crowd the mark on a phone.
                .frame(width: widths.actionColumnWidth)
        }
    }

    private func identity(_ widths: WidthLayout, _ layout: MenuLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            Spacer(minLength: 0)

            // `MenuLayout.wordmarkHeight` is the mark's overall height; the
            // 5x5 grid's per-cell size is that divided by its five rows.
            WordmarkTiles(cell: layout.wordmarkHeight / 5)
                #if DEBUG
                // Quiet way in to the style gallery. No visible control, so it
                // adds nothing to the menu's actions.
                .onLongPressGesture { showingStyleGallery = true }
                #endif

            Spacer(minLength: 0)
        }
    }

    private func actions(_ layout: MenuLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            Spacer(minLength: 0)

            // The mute control rides the section label rather than the button
            // stack: it is chrome, not a seventh thing to play. Icon only, at
            // the label's weight, so it never competes with the PLAY actions.
            HStack {
                Text(Self.actionsLabel)
                    .monoLabel()

                Spacer(minLength: 0)

                muteButton
            }

            primaryActions
            quietActions(layout)
            onlineUnavailableCaption

            Spacer(minLength: 0)
        }
    }

    /// The single-column portrait Home: mute top-right, wordmark near the
    /// top sized from the available width, a flexible gap, then the PLAY
    /// actions anchored to the bottom.
    private func portraitColumn(_ layout: MenuLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            HStack {
                Spacer(minLength: 0)
                muteButton
            }

            HStack {
                Spacer(minLength: 0)
                WordmarkTiles(cell: layout.wordmarkHeight / 5)
                    #if DEBUG
                    .onLongPressGesture { showingStyleGallery = true }
                    #endif
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: layout.spacing) {
                Text(Self.actionsLabel).monoLabel()
                primaryActions
                quietActions(layout)
                onlineUnavailableCaption
            }
        }
    }

    private var muteButton: some View {
        Button { shell.toggleMute() } label: {
            Image(systemName: shell.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .imageScale(.medium)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DesignTokens.Palette.textSecondary)
        .accessibilityLabel(shell.isMuted ? Self.soundOffLabel : Self.soundOnLabel)
    }

    /// The two loud actions, in ``MenuLayout/actions``' order: Multiplayer —
    /// disabled until the feature ships, with its "Coming soon" caption
    /// underneath — then Play a Friend, off until the anonymous sign-in
    /// lands.
    @ViewBuilder
    private var primaryActions: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            Button {} label: {
                Text(Self.multiplayerTitle).menuActionLabel()
            }
            .buttonStyle(.brandPrimary)
            .disabled(true)

            Text(Self.multiplayerComingSoon)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
        }
        .padding(.bottom, DesignTokens.Space.s)

        Button { shell.playAFriend() } label: {
            Text(HostLobbyModel.title).menuActionLabel()
        }
        .buttonStyle(.brandPrimary)
        .disabled(!shell.canPlayOnline)
    }

    private var onlineUnavailableCaption: some View {
        Group {
            if let reason = shell.onlineUnavailableReason {
                Text(reason)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The four quiet actions, in a grid: two columns on a phone (portrait
    /// or landscape) so they read as two rows instead of four, one column on
    /// an iPad where height was never the constraint.
    ///
    /// Two columns means a narrower label than `QuietButtonStyle`'s own
    /// `verticalSizeClass`-only compact switch accounts for — a portrait
    /// phone is vertically regular, so without this the style's 20pt font
    /// wraps "Solo Practice" onto two lines and blows the portrait content
    /// budget. Setting the font directly on each `Text` (closer to the leaf
    /// than the style's own `.font()`, which wraps `configuration.label`
    /// from outside) wins over the style's choice; iPad's single column
    /// keeps the style's normal font untouched.
    private func quietActions(_ layout: MenuLayout) -> some View {
        let font: Font? = layout.quietColumns == 2 ? DesignTokens.Typography.buttonCompact : nil
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: DesignTokens.Space.m, alignment: .top),
            count: layout.quietColumns
        )
        return LazyVGrid(columns: columns, alignment: .leading, spacing: layout.spacing) {
            // Into the setup screen, not into a match: what the far end plays
            // like and what the rules are get chosen before the deal, because
            // afterwards is too late to change either.
            Button { shell.showSoloSetup() } label: {
                Text(SoloSetup.title).menuActionLabel(font: font)
            }
            .buttonStyle(.brandQuiet)

            // Your own row: a name to change and the code a friend needs. Off
            // until sign-in lands — there is no profile to show yet.
            Button { shell.showProfile() } label: {
                Text(ProfileModel.title).menuActionLabel(font: font)
            }
            .buttonStyle(.brandQuiet)
            .disabled(shell.currentProfile == nil)

            // Who you play with, and who is waiting on an answer. Gated on the
            // same signed-in row the profile is: `friendships()` is read as
            // somebody.
            Button { shell.showFriends() } label: {
                Text(FriendsModel.title).menuActionLabel(font: font)
            }
            .buttonStyle(.brandQuiet)
            .disabled(shell.currentProfile == nil)

            Button { shell.showHowToPlay() } label: {
                Text(HowToPlay.title).menuActionLabel(font: font)
            }
            .buttonStyle(.brandQuiet)
        }
    }

    /// Not `Terminology`: that file is the frozen IP fence and names game
    /// concepts, not screens.
    private static let actionsLabel = "PLAY"

    /// The mute control's two states, read aloud. Chrome, so local constants
    /// and not `Terminology` — the label states what is true now, so a muted
    /// app reads "Sound off".
    private static let soundOnLabel = "Sound on"
    private static let soundOffLabel = "Sound off"

    /// The disabled primary action's title and its reason caption. Chrome,
    /// so a local constant and not `Terminology` — there is no game concept
    /// named "Multiplayer" for the fence to guard.
    private static let multiplayerTitle = "Multiplayer"
    private static let multiplayerComingSoon = "Coming soon"

    /// The width the design comp was drawn at. Nothing is pinned to it — it is
    /// the ceiling the content stops growing at, so a wider screen adds margin
    /// rather than stretching a two-column menu across a metre of glass.
    private static let contentMaxWidth: CGFloat = 980
}

private extension View {

    /// The action column's buttons span it and stand at the comp's control
    /// height. The height is on the label because the button style owns the
    /// padding around it: 36 plus two `Space.s` insets is the 52pt control.
    ///
    /// `font`, when given, overrides the button style's own choice — see the
    /// note on `quietActions` for why a two-column grid needs this. Applying
    /// `.font(nil)` unconditionally would still plant an environment override
    /// that shadows the button style's font even when no override is wanted,
    /// so the modifier is only attached when `font` is non-nil.
    @ViewBuilder
    func menuActionLabel(font: Font? = nil) -> some View {
        if let font {
            self.font(font).frame(maxWidth: .infinity, minHeight: 36)
        } else {
            self.frame(maxWidth: .infinity, minHeight: 36)
        }
    }
}
