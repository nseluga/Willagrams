import SwiftUI

/// "Play a Friend" and "Join a Friend", one screen with two modes — comp
/// screen 03. The two chips switch mode by calling `shell.playAFriend()` /
/// `shell.showJoin()`, which tear down whichever model is being left before
/// building the other; this view renders whichever model `ShellRootView` hands
/// it and branches on nothing about routing.
///
/// Every string and every derived value is a model's — `HostLobbyModel`'s or
/// `JoinModel`'s — except the screen chrome named here, per the `Terminology`
/// fence.
///
/// Must stay listed in the `Shell` target's `exclude:` in
/// `Tests/ShellTests/Package.swift` — `SourceGuardrailTests` says so.
struct TwoPlayerView: View {

    /// Which model this visit renders. The route already carries this
    /// decision — `.hostLobby` or `.join` — so it is handed in rather than
    /// inferred from which of `shell.hostLobby`/`shell.join` is non-nil, which
    /// would be the same fact read a second, more fragile way.
    enum Mode {
        case host(HostLobbyModel)
        case join(JoinModel)
    }

    let shell: ShellModel
    let mode: Mode

    /// Tracks the join field so its container can be scrolled into view the
    /// moment the keyboard covers it — see `joinField`. Unused in host mode.
    @FocusState private var codeFieldFocused: Bool

    @State private var didCopyCode = false

    /// Whether the host's match-settings sheet is up. Host mode only.
    @State private var showsSettings = false

    private var isHost: Bool {
        if case .host = mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            topBar

            VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
                Text(isHost ? HostLobbyModel.title : JoinModel.title)
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                Text(isHost ? Self.hostSubtitle : Self.joinSubtitle)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            chips

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
                        codeSection

                        if case .join(let join) = mode {
                            joinField(join).id(Self.codeFieldID)
                            joinStatus(join)
                        }

                        if isHost {
                            hostActions
                        }

                        if let message {
                            Text(message)
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Palette.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: codeFieldFocused) { _, isFocused in
                    guard isFocused else { return }
                    withAnimation {
                        proxy.scrollTo(Self.codeFieldID, anchor: .center)
                    }
                }
            }

            primaryButton
        }
        .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenPadding()
        .background { canvas }
    }

    /// Cancel · the screen's own mono label · the match-settings gear, host
    /// mode only. In join mode the slot is a same-width spacer, so the label
    /// sits in the same place on both modes of one screen.
    private var topBar: some View {
        HStack(alignment: .center) {
            Button(Self.cancelLabel) { shell.returnToMenu() }
                .buttonStyle(.brandText)
            Spacer(minLength: DesignTokens.Space.m)
            Text(Self.screenLabel).monoLabel()
            Spacer(minLength: DesignTokens.Space.m)
            if case .host(let lobby) = mode {
                settingsButton(lobby)
            } else {
                Color.clear.frame(width: Self.trailingSlotSide, height: Self.trailingSlotSide)
            }
        }
    }

    /// The host's match settings: the same rules solo plays under, minus the
    /// opponent. Unavailable from the moment Start is pressed — `.start` has
    /// carried the values by then, and one edited after it left would be a rule
    /// only this device believed.
    private func settingsButton(_ lobby: HostLobbyModel) -> some View {
        Button {
            lobby.loadOptions()
            showsSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(DesignTokens.Typography.button)
                .frame(width: Self.trailingSlotSide, height: Self.trailingSlotSide)
        }
        .buttonStyle(.plain)
        .foregroundStyle(DesignTokens.Palette.textPrimary)
        .accessibilityLabel(HostLobbyModel.settingsLabel)
        .disabled(!lobby.canEditSettings)
        .sheet(isPresented: $showsSettings) { settingsSheet(lobby) }
    }

    /// One screen, not a panel pasted onto one: this screen's own title, one
    /// card holding the starting hand and then the settings lane's rows
    /// embedded as they ship, and Done as the primary button at the bottom —
    /// the same shape as Start below the lobby.
    ///
    /// There is no second copy of any rule row here: everything under the
    /// hairline is `MatchOptionsView`'s, bound straight to the model's form.
    private func settingsSheet(_ lobby: HostLobbyModel) -> some View {
        @Bindable var lobby = lobby
        return VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            Text(HostLobbyModel.settingsLabel)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)

            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
                    Stepper(value: $lobby.handSize, in: SoloSetup.handSizeRange) {
                        HStack {
                            Text(SoloSetup.handSizeLabel)
                                .foregroundStyle(DesignTokens.Palette.textPrimary)
                            Spacer()
                            Text(String(lobby.handSize))
                                .foregroundStyle(DesignTokens.Palette.textSecondary)
                        }
                        .font(DesignTokens.Typography.body)
                    }
                    .tint(DesignTokens.Palette.accent)

                    if let form = Binding($lobby.optionsForm) {
                        hairline
                        MatchOptionsView(form: form, embedded: true)
                    }
                }
                .padding(DesignTokens.Space.l)
                .brandCard()
                .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
            }

            Button { showsSettings = false } label: {
                Text(Self.doneLabel).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.brandPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .screenPadding()
        .background { canvas }
    }

    private var hairline: some View {
        Rectangle()
            .fill(DesignTokens.Palette.hairline)
            .frame(height: DesignTokens.Stroke.hairline)
    }

    /// The screen's ground, shared by the lobby and its settings sheet so the
    /// two never read as different surfaces.
    private var canvas: some View {
        LinearGradient(
            colors: [DesignTokens.Palette.canvasTop, DesignTokens.Palette.canvasBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    /// "Host a game" / "Join a game" — the mode switch itself.
    private var chips: some View {
        HStack(spacing: DesignTokens.Space.s) {
            chip(Self.hostChipLabel, isSelected: isHost) { shell.playAFriend() }
            chip(Self.joinChipLabel, isSelected: !isHost) { shell.showJoin() }
        }
    }

    private func chip(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(DesignTokens.Typography.buttonCompact)
                .foregroundStyle(isSelected ? DesignTokens.Palette.onInk : DesignTokens.Palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignTokens.Space.s)
                .background(isSelected ? DesignTokens.Palette.ink : Color.clear, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(DesignTokens.Palette.hairline, lineWidth: DesignTokens.Stroke.hairline)
                }
        }
        .buttonStyle(.plain)
    }

    /// The six tiles: the host's invite code once it exists, or the guest's
    /// typed characters. `CodeTiles` is the plain value behind this — the
    /// mapping from mode and code to six boxes is decidable without a view.
    private var codeSection: some View {
        Group {
            switch mode {
            case .host(let lobby):
                if let code = lobby.inviteCode {
                    codeTiles(mode: .host, code: code)
                } else {
                    Text(Self.creatingLabel)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                }
            case .join(let join):
                codeTiles(mode: .join, code: join.code)
            }
        }
    }

    private func codeTiles(mode: CodeTileMode, code: String) -> some View {
        HStack(spacing: DesignTokens.Space.codeTileGap) {
            ForEach(Array(CodeTile.tiles(mode: mode, code: code).enumerated()), id: \.offset) { _, tile in
                codeTile(tile)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder private func codeTile(_ tile: CodeTile) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.tile, style: .continuous)
        switch tile {
        case .filled(let character, let accent):
            Text(String(character))
                .font(DesignTokens.Typography.tileLetter)
                .foregroundStyle(accent ? DesignTokens.Palette.onAccent : DesignTokens.Palette.tileLetter)
                .frame(width: Self.tileSide, height: Self.tileSide)
                .background(accent ? DesignTokens.Palette.accent : DesignTokens.Palette.tileFace, in: shape)
                .brandShadow(DesignTokens.Shadow.tile)
        case .empty:
            shape
                .strokeBorder(DesignTokens.Palette.hairline, style: StrokeStyle(lineWidth: DesignTokens.Stroke.hairline, dash: [4]))
                .frame(width: Self.tileSide, height: Self.tileSide)
        }
    }

    /// Monospaced and uppercased for the same reason the host's tiles are: an
    /// O and a 0 must not be the same shape on either side of the handoff.
    private func joinField(_ join: JoinModel) -> some View {
        TextField(Self.fieldPrompt, text: Bindable(join).code)
            .font(.system(size: 17, weight: .semibold, design: .default))
            .foregroundStyle(DesignTokens.Palette.textPrimary)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .textFieldStyle(.plain)
            .padding(DesignTokens.Space.m)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(DesignTokens.Palette.cellEmpty, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                    .strokeBorder(DesignTokens.Palette.hairline, lineWidth: DesignTokens.Stroke.hairline)
            }
            .focused($codeFieldFocused)
            .onSubmit { join.join() }
    }

    /// Tells the guest what `join.phase` already knows: in flight, or in — the
    /// model decides the words, this only picks which of its published states
    /// to draw.
    @ViewBuilder private func joinStatus(_ join: JoinModel) -> some View {
        switch join.phase {
        case .entering:
            EmptyView()
        case .joining:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
        case .waiting:
            Text(join.waitingLine)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Copy/Share, then the roster: a seated player "Ready", an open seat
    /// dashed. Host mode only — moved across from `HostLobbyView` intact.
    @ViewBuilder private var hostActions: some View {
        if case .host(let lobby) = mode {
            VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
                if let code = lobby.inviteCode {
                    HStack(spacing: DesignTokens.Space.m) {
                        Button(didCopyCode ? Self.copiedLabel : Self.copyLabel) {
                            ShellModel.pasteboard(code)
                            didCopyCode = true
                        }
                        .buttonStyle(.brandQuiet)
                        .frame(maxWidth: .infinity)

                        ShareLink(item: code) {
                            Label(Self.shareLabel, systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.brandQuiet)
                        .frame(maxWidth: .infinity)
                    }
                }

                ForEach(Array(lobby.roster.enumerated()), id: \.offset) { _, name in
                    seatedRow(name)
                }
                if !lobby.canStart {
                    openSeatRow
                }
            }
        }
    }

    private func seatedRow(_ name: String) -> some View {
        HStack(spacing: DesignTokens.Space.m) {
            Text(String(name.first ?? "?"))
                .font(DesignTokens.Typography.tileLetter)
                .foregroundStyle(DesignTokens.Palette.tileLetter)
                .frame(width: Self.avatarSide, height: Self.avatarSide)
                .background(DesignTokens.Palette.tileFace, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.tile, style: .continuous))

            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                Text(name)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                Text(Self.readyLabel)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Space.m)
        .background(DesignTokens.Palette.surface, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous))
    }

    private var openSeatRow: some View {
        HStack(spacing: DesignTokens.Space.m) {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.tile, style: .continuous)
                .strokeBorder(DesignTokens.Palette.hairline, style: StrokeStyle(lineWidth: DesignTokens.Stroke.hairline, dash: [4]))
                .frame(width: Self.avatarSide, height: Self.avatarSide)

            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                Text(Self.openSeatLabel)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                Text(Self.waitingLabel)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Space.m)
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                .strokeBorder(DesignTokens.Palette.hairline, style: StrokeStyle(lineWidth: DesignTokens.Stroke.hairline, dash: [4]))
        }
    }

    private var message: String? {
        switch mode {
        case .host(let lobby): return lobby.message
        case .join(let join): return join.message
        }
    }

    /// Start (host) or Join (join, disabled until six characters — the same
    /// `canJoin` the model refuses on).
    private var primaryButton: some View {
        Group {
            switch mode {
            case .host(let lobby):
                Button { lobby.start() } label: {
                    Text(Self.startLabel).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.brandPrimary)
                .disabled(!lobby.canStart || lobby.phase != .waiting)
            case .join(let join):
                Button { join.join() } label: {
                    Text(Self.joinLabel).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.brandPrimary)
                .disabled(!join.canJoin)
            }
        }
    }

    /// Screen chrome, per the `Terminology` fence: this screen names no game
    /// concept, so every label here is its own.
    private static let cancelLabel = "Cancel"
    private static let screenLabel = "TWO PLAYER"
    private static let hostChipLabel = "Host a game"
    private static let joinChipLabel = "Join a game"
    private static let hostSubtitle = "Share the code below. One friend, one seat."
    private static let joinSubtitle = "Enter the code from your friend’s screen."
    private static let creatingLabel = "Making a match…"
    private static let fieldPrompt = "Type the six characters"
    private static let copyLabel = "Copy"
    private static let copiedLabel = "Copied"
    private static let shareLabel = "Share"
    private static let readyLabel = "Ready"
    private static let openSeatLabel = "Open seat"
    private static let waitingLabel = "Waiting for your friend to join."
    private static let doneLabel = "Done"
    private static let startLabel = "Start"
    private static let joinLabel = "Join"

    private static let contentMaxWidth: CGFloat = 980
    private static let codeFieldID = "twoPlayer.codeField"
    private static let tileSide: CGFloat = 50
    private static let avatarSide: CGFloat = 44
    private static let trailingSlotSide: CGFloat = 44
}
