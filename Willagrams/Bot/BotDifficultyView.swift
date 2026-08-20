//
//  BotDifficultyView.swift
//  Willagrams
//
//  The difficulty screen. Every string and every decision on it lives in
//  `BotDifficultyMenu`, which is where a test can execute them; this file draws
//  them and holds no branch that changes what the app does.
//
//  It owns no match state and starts nothing — a press reports a preset and the
//  Shell, which owns navigation, decides what follows.
//
//  Every visual value here resolves through `DesignTokens`. No literal number,
//  colour, font or duration appears below, and `BotDifficultySourceTests`
//  fails the build if one does.
//
//  This file imports SwiftUI, so it is listed in the `Bot` target's `exclude:`
//  in `Tests/BotTests/Package.swift`.
//
//  This file must never import GameKit.
//

import SwiftUI

struct BotDifficultyView: View {

    let menu: BotDifficultyMenu

    var body: some View {
        VStack(spacing: DesignTokens.Space.l) {
            Text(BotDifficultyMenu.title)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)

            // Intrinsically sized and centred: landscape iPhone through
            // landscape iPad, no assumed viewport.
            ForEach(BotDifficultyMenu.choices, id: \.title) { choice in
                Button { menu.select(choice) } label: { label(for: choice) }
                    .buttonStyle(.brandQuiet)
            }

            Button(BotDifficultyMenu.backLabel) { menu.back() }
                .buttonStyle(.brandText)
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

    /// One row's two lines. A function, not a computed property with a
    /// condition in it: nothing here reads anything but the choice handed in.
    private func label(for choice: BotDifficultyChoice) -> some View {
        VStack(spacing: DesignTokens.Space.xs) {
            Text(choice.title)
                .font(DesignTokens.Typography.button)
                .foregroundStyle(DesignTokens.Palette.textPrimary)

            Text(choice.detail)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
    }
}
