import SwiftUI

/// The host's options screen.
///
/// Deliberately dumb: every control writes straight to ``MatchOptionsForm``,
/// which owns the bounds. The stepper carries no range of its own — the clamp
/// is the model's, and a control that could enforce it here would be a second
/// copy of the rule that could disagree with the one that travels.
///
/// Every value on screen is a `DesignTokens` key and every game word is a
/// `Terminology` constant.
public struct MatchOptionsView: View {

    @Binding private var form: MatchOptionsForm

    public init(form: Binding<MatchOptionsForm>) {
        self._form = form
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            Text(verbatim: "Match options")
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Palette.textPrimary)

            VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
                minimumLength
                divider
                swap
                divider
                wordList
            }
            .padding(DesignTokens.Space.m)
            .brandCard()
        }
        .padding(DesignTokens.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(canvas)
    }

    // MARK: - Ground

    private var canvas: some View {
        LinearGradient(
            colors: [DesignTokens.Palette.canvasTop, DesignTokens.Palette.canvasBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var divider: some View {
        Rectangle()
            .fill(DesignTokens.Palette.hairline)
            .frame(height: DesignTokens.Stroke.hairline)
    }

    // MARK: - Controls

    private var minimumLength: some View {
        Stepper(value: $form.minimumWordLength) {
            row(
                title: "Shortest word",
                detail: "\(form.minimumWordLength) letters"
            )
        }
    }

    private var swap: some View {
        Toggle(isOn: $form.swapEnabled) {
            row(
                title: Terminology.swap,
                detail: "Return one tile to the \(Terminology.pool), take three"
            )
        }
        .tint(DesignTokens.Palette.accent)
    }

    /// Read-only: one list ships, so there is nothing to pick between yet.
    /// A picker arrives with the second entry in `DictionaryCatalogue`.
    private var wordList: some View {
        row(title: "Word list", detail: form.dictionaryName)
    }

    private func row(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            Text(title)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
            Text(detail)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
