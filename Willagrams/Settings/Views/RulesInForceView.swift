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
            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                Text(verbatim: "THIS MATCH")
                    .monoLabelAccent()

                Text(verbatim: "Rules in force")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }

            // Ruled between the lines, the way the comp sets a readout table:
            // each rule is a separate claim and reads as one.
            VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DesignTokens.Space.m)
                        // Ruled above every line, including the first, where it
                        // reads as the head rule of the table. Uniform on
                        // purpose: skipping one would need a branch, and this
                        // view is not allowed to know which line it is on.
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(DesignTokens.Palette.hairline)
                                .frame(height: DesignTokens.Stroke.hairline)
                        }
                }
            }
            .padding(DesignTokens.Space.l)
            .brandCard()
            .frame(maxWidth: Self.panelWidth, alignment: .leading)
        }
        .padding(.leading, DesignTokens.Space.xl + DesignTokens.Space.l)
        .padding([.top, .trailing, .bottom], DesignTokens.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let panelWidth: CGFloat = 520
}
