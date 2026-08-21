//
//  HowToPlayView.swift
//  Willagrams
//
//  The rules screen. Every word on it lives in `HowToPlay`, and the one control
//  calls a `ShellModel` transition — this file draws them and decides nothing.
//
//  It reads no match state, because there is none to read: the route that leads
//  here carries nothing and is only reachable from the menu.
//

import SwiftUI

struct HowToPlayView: View {

    let shell: ShellModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            ScreenHeader(
                title: HowToPlay.title,
                backTitle: HowToPlay.backLabel,
                onBack: { shell.returnToMenu() }
            ) {
                Text(Self.ruleCountLabel).monoLabel()
            }

            // Two columns, because a rule is three lines and a single column in
            // a landscape frame is a 900pt line length nobody finishes. Still
            // scrolls: the count comes from `HowToPlay`, not from this layout.
            ScrollView {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: DesignTokens.Space.m) {
                    ForEach(Array(HowToPlay.rules.enumerated()), id: \.element.id) { index, rule in
                        card(rule, number: index + 1)
                    }
                }
                .padding(.bottom, DesignTokens.Space.m)
            }
        }
        .padding(.leading, DesignTokens.Space.xl + DesignTokens.Space.l)
        .padding([.top, .trailing, .bottom], DesignTokens.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            LinearGradient(
                colors: [DesignTokens.Palette.canvasTop, DesignTokens.Palette.canvasBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private func card(_ rule: HowToPlay.Rule, number: Int) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            Text(Self.number(number))
                .monoLabelAccent()

            Text(rule.title)
                .font(DesignTokens.Typography.button)
                .foregroundStyle(DesignTokens.Palette.textPrimary)

            Text(rule.body)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.l)
        .brandCard()
    }

    /// Zero-padded so the kickers sit on one optical width down the column.
    private static func number(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static let ruleCountLabel = "\(HowToPlay.rules.count) RULES"

    private static let columns = [
        GridItem(.flexible(), spacing: DesignTokens.Space.m, alignment: .top),
        GridItem(.flexible(), spacing: DesignTokens.Space.m, alignment: .top),
    ]
}
