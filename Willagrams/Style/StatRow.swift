import SwiftUI

/// One `label — value` line in a settings or results table.
///
/// The value carries the weight because it is the part that changes; the label
/// sits in the secondary ink because on a screen of eight rows the labels are
/// scaffolding. A trailing hairline is opt-in so a caller can drop it on the
/// last row without the table looking unfinished.
public struct StatRow: View {

    private let label: String
    private let value: String
    private let showsDivider: Bool

    public init(label: String, value: String, showsDivider: Bool = true) {
        self.label = label
        self.value = value
        self.showsDivider = showsDivider
    }

    public var body: some View {
        VStack(spacing: DesignTokens.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.m) {
                Text(label)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)

                Spacer(minLength: DesignTokens.Space.m)

                Text(value)
                    .font(DesignTokens.Typography.button)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
            }

            if showsDivider {
                Rectangle()
                    .fill(DesignTokens.Palette.hairline)
                    .frame(height: DesignTokens.Stroke.hairline)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
