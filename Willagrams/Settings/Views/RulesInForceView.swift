import SwiftUI

/// The rules in force, so the joining player sees what the host chose.
///
/// Deliberately dumb: ``RulesSummary`` decides which rules are worth a line and
/// how each reads; this only stacks the lines it is handed. No rule is
/// interpreted here — a check on `swapEnabled` or a length in this file would be
/// a second copy of the rule that travels, free to disagree with it.
public struct RulesInForceView: View {

    private let form: MatchOptionsForm

    public init(form: MatchOptionsForm) {
        self.form = form
    }

    private var lines: [String] {
        RulesSummary.lines(
            for: form.options,
            dictionaryName: form.dictionaryName,
            swapName: Terminology.swap
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            Text(verbatim: "Rules in force")
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Palette.textPrimary)

            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(DesignTokens.Space.m)
            .brandCard()
        }
        .padding(DesignTokens.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
