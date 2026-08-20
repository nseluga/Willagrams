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
        VStack(spacing: DesignTokens.Space.l) {
            Text(HowToPlay.title)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)

            // Scrolls rather than shrinks: landscape iPhone through landscape
            // iPad, no assumed viewport, and the copy stays at body size.
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
                    ForEach(HowToPlay.rules) { rule in
                        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                            Text(rule.title)
                                .font(DesignTokens.Typography.button)
                                .foregroundStyle(DesignTokens.Palette.textPrimary)
                            Text(rule.body)
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(DesignTokens.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            Button(HowToPlay.backLabel) { shell.returnToMenu() }
                .buttonStyle(.brandPrimary)
        }
        .padding(DesignTokens.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(
                colors: [DesignTokens.Palette.canvasTop, DesignTokens.Palette.canvasBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}
