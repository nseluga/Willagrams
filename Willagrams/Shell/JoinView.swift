import SwiftUI

/// The guest's screen: a code field, then the wait for the host.
///
/// Every branch here is over a value ``JoinModel`` already published — `phase`,
/// `message`, `canJoin`, `waitingLine`. The clamp on the field is the model's
/// too: `code` sanitises itself on every write, so this is a plain binding and
/// not a second rule about what a code may contain.
///
/// Must stay listed in the `Shell` target's `exclude:` in
/// `Tests/ShellTests/Package.swift` — `SourceGuardrailTests` says so.
struct JoinView: View {

    let shell: ShellModel
    @Bindable var join: JoinModel

    /// Tracks the code field so its container can be scrolled into view the
    /// moment the keyboard covers it — see `field`.
    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            // Scrolls so a phone in landscape, keyboard up, still reaches the
            // field; the buttons below stay pinned.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
                        Text(JoinModel.title)
                            .font(DesignTokens.Typography.title)
                            .foregroundStyle(DesignTokens.Palette.textPrimary)

                        if join.phase == .waiting {
                            Text(join.waitingLine)
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(DesignTokens.Palette.textSecondary)
                        } else {
                            field
                                .id(Self.codeFieldID)
                        }

                        if let message = join.message {
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

            actions
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

    /// Monospaced and uppercased for the same reason the host's code is: an O
    /// and a 0 must not be the same shape on either side of the handoff.
    private var field: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            Text(HostLobbyModel.inviteCodeLabel).monoLabel()

            // Join sits beside the field, not in the actions row below: with
            // the keyboard up on a landscape phone, the actions row can slide
            // off-screen, but this row scrolls up with the field.
            HStack(spacing: DesignTokens.Space.m) {
                TextField(Self.fieldPrompt, text: $join.code)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .frame(maxWidth: 320, alignment: .leading)
                    .focused($codeFieldFocused)
                    .onSubmit { join.join() }

                Button { join.join() } label: {
                    Text(Self.joinLabel).frame(minHeight: 36)
                }
                .buttonStyle(.brandPrimary)
                .disabled(!join.canJoin)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: DesignTokens.Space.m) {
            Button { join.cancel() } label: {
                Text(Self.cancelLabel).frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.brandQuiet)
        }
        .frame(maxWidth: 480)
    }

    /// Screen chrome, per the `Terminology` fence: this screen names no game
    /// concept, so every label here is its own.
    private static let fieldPrompt = "ABC123"
    private static let joinLabel = "Join"
    private static let cancelLabel = "Cancel"

    private static let contentMaxWidth: CGFloat = 980
    private static let codeFieldID = "join.codeField"
}
