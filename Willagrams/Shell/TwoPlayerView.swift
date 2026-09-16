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
        .background {
            LinearGradient(
                colors: [DesignTokens.Palette.canvasTop, DesignTokens.Palette.canvasBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    /// Cancel · the screen's own mono label · a same-width trailing slot,
    /// empty here — item 7 puts the match-settings gear in it.
    private var topBar: some View {
        HStack(alignment: .center) {
            Button(Self.cancelLabel) { shell.returnToMenu() }
                .buttonStyle(.brandText)
            Spacer(minLength: DesignTokens.Space.m)
            Text(Self.screenLabel).monoLabel()
            Spacer(minLength: DesignTokens.Space.m)
            Color.clear.frame(width: Self.trailingSlotSide, height: Self.trailingSlotSide)
        }
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
    private static let startLabel = "Start"
    private static let joinLabel = "Join"

    private static let contentMaxWidth: CGFloat = 980
    private static let codeFieldID = "twoPlayer.codeField"
    private static let tileSide: CGFloat = 50
    private static let avatarSide: CGFloat = 44
    private static let trailingSlotSide: CGFloat = 44
}
