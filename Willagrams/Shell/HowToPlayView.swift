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
        VStack(spacing: DesignTokens.Space.m) {
            Text(HowToPlay.title)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)

            // Columns rather than one narrow strip down the middle: the rules
            // are short blocks, and a wide screen fits two or three of them
            // side by side instead of leaving half the width empty.
            //
            // Inside a `ScrollView` regardless, because a phone in portrait
            // fits one column and still overflows. `LazyVGrid` is the whole
            // adaptation — no size class is read and no branch is taken here.
            ScrollView {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: DesignTokens.Space.l) {
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.bottom, DesignTokens.Space.m)
            }
            .scrollIndicators(.visible)

            Button(HowToPlay.backLabel) { shell.returnToMenu() }
                .buttonStyle(.brandPrimary)
        }
        .padding(DesignTokens.Space.l)
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

    /// As many columns as fit at a readable width, which is one on a phone in
    /// portrait and two or three on anything wider.
    private static let columns = [
        GridItem(.adaptive(minimum: 320), spacing: DesignTokens.Space.l, alignment: .topLeading)
    ]
}
