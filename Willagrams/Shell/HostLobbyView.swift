import SwiftUI

/// The host's lobby: the code, who has it, and the two ways out.
///
/// Every branch here is over a value ``HostLobbyModel`` already published —
/// `phase`, `canStart`, `message`, `roster`. Nothing is inferred: "creating" is
/// not `inviteCode == nil`, because that is also true of a failure, and a view
/// holding that rule would show a spinner over an error.
///
/// Must stay listed in the `Shell` target's `exclude:` in
/// `Tests/ShellTests/Package.swift` — `SourceGuardrailTests` says so.
struct HostLobbyView: View {

    let shell: ShellModel
    let lobby: HostLobbyModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            Text(HostLobbyModel.title)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Palette.textPrimary)

            code

            roster

            if let message = lobby.message {
                Text(message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            actions
        }
        .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Space.xl)
        .background {
            LinearGradient(
                colors: [DesignTokens.Palette.canvasTop, DesignTokens.Palette.canvasBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    /// The code, at display size, with the system share sheet beside it. Big
    /// because it is the one thing on this screen a friend has to read off the
    /// glass — and monospaced so an O and a 0 are not the same shape.
    @ViewBuilder private var code: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            Text(HostLobbyModel.inviteCodeLabel).monoLabel()

            if let inviteCode = lobby.inviteCode {
                HStack(spacing: DesignTokens.Space.m) {
                    Text(inviteCode)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .foregroundStyle(DesignTokens.Palette.textPrimary)
                        .textSelection(.enabled)
                        .accessibilityLabel(Text(inviteCode.map(String.init).joined(separator: " ")))

                    ShareLink(item: inviteCode) {
                        Label(Self.shareLabel, systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.brandQuiet)
                }
            } else {
                Text(Self.creatingLabel)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
        }
    }

    private var roster: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            Text(Self.rosterLabel).monoLabel()

            ForEach(Array(lobby.roster.enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
            }

            if !lobby.canStart {
                Text(Self.waitingLabel)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: DesignTokens.Space.m) {
            Button { lobby.start() } label: {
                Text(Self.startLabel).frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.brandPrimary)
            .disabled(!lobby.canStart || lobby.phase != .waiting)

            Button { lobby.cancel() } label: {
                Text(Self.cancelLabel).frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.brandQuiet)
        }
        .frame(maxWidth: 480)
    }

    /// Screen chrome, per the `Terminology` fence: this screen names no game
    /// concept, so every label here is its own.
    private static let shareLabel = "Share the code"
    private static let creatingLabel = "Making a match…"
    private static let rosterLabel = "PLAYERS"
    private static let waitingLabel = "Waiting for your friend to join."
    private static let startLabel = "Start"
    private static let cancelLabel = "Cancel"

    private static let contentMaxWidth: CGFloat = 980
}
