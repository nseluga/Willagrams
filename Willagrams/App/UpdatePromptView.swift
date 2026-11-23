import SwiftUI

/// Mounted over the whole app by `WillagramsApp`: asks for an update when an
/// online button was tapped on a build the store has passed. All decisions are
/// `ShellModel`'s; this only draws them.
struct UpdatePromptView: View {

    let shell: ShellModel

    var body: some View {
        if shell.showsUpdatePrompt {
            ZStack {
                Color.black.opacity(0.4).ignoresSafeArea()
                VStack(spacing: DesignTokens.Space.m) {
                    Text(ShellModel.updateTitle)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Palette.textPrimary)
                        .multilineTextAlignment(.center)
                    Button(ShellModel.updateButtonLabel) { UIApplication.shared.open(shell.updateLink) }
                        .buttonStyle(.brandPrimary)
                    Button(ShellModel.updateDismissLabel) { shell.showsUpdatePrompt = false }
                        .buttonStyle(.brandQuiet)
                }
                .padding(DesignTokens.Space.l)
                .background(DesignTokens.Palette.canvasBottom)
                .frame(maxWidth: 420)
                .padding(DesignTokens.Space.m)
            }
        }
    }
}
