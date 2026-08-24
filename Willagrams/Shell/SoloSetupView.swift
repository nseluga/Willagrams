//
//  SoloSetupView.swift
//  Willagrams
//
//  The solo setup screen. Every string and every bound on it lives in
//  `SoloSetup`, and the two controls that leave call `ShellModel` transitions —
//  this file draws them and holds no branch that changes what the app does.
//
//  This file imports SwiftUI, so it is listed in the `Shell` target's
//  `exclude:` in `Tests/ShellTests/Package.swift`.
//

import SwiftUI
import WillagramsRules

struct SoloSetupView: View {

    let shell: ShellModel

    var body: some View {
        @Bindable var setup = shell.soloSetup

        VStack(spacing: DesignTokens.Space.m) {
            Text(SoloSetup.title)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)

            // Two columns side by side when the screen is wide, one under the
            // other when it is not. `ViewThatFits` measures — no size class is
            // read and no branch is taken on state.
            ScrollView {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DesignTokens.Space.xl) {
                        opponent(setup: setup).frame(minWidth: Self.columnWidth)
                        rules(setup: setup).frame(minWidth: Self.columnWidth)
                    }
                    VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
                        opponent(setup: setup)
                        rules(setup: setup)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, DesignTokens.Space.m)
            }
            .scrollIndicators(.visible)

            HStack(spacing: DesignTokens.Space.m) {
                Button(SoloSetup.backLabel) { shell.returnToMenu() }
                    .buttonStyle(.brandText)
                Button(SoloSetup.startLabel) { shell.startSoloPractice() }
                    .buttonStyle(.brandPrimary)
            }
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

    /// How narrow a column may get before the two stop sitting side by side.
    private static let columnWidth: CGFloat = 340

    /// What the match itself is played under. The bounds are `SoloSetup`'s and
    /// the engine's — this column names none of its own.
    private func rules(setup: SoloSetup) -> some View {
        @Bindable var setup = setup
        return VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            stepper(
                SoloSetup.handSizeLabel,
                value: $setup.handSize,
                in: SoloSetup.handSizeRange
            )
            stepper(
                SoloSetup.minimumWordLengthLabel,
                value: $setup.minimumWordLength,
                in: MatchOptions.lengthRange
            )
            Toggle(SoloSetup.swapLabel, isOn: $setup.swapEnabled)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .tint(DesignTokens.Palette.accent)
        }
    }

    /// The three presets, as rows that show which one is chosen. The copy is
    /// `BotDifficultyMenu`'s — this screen adds none of its own.
    private func opponent(setup: SoloSetup) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            Text(SoloSetup.opponentLabel)
                .font(DesignTokens.Typography.monoLabel)
                .tracking(DesignTokens.Typography.monoLabelTracking)
                .foregroundStyle(DesignTokens.Palette.textSecondary)

            ForEach(SoloSetup.difficulties, id: \.title) { choice in
                Button { setup.difficulty = choice.difficulty } label: {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                        Text(choice.title)
                            .font(DesignTokens.Typography.button)
                        Text(choice.detail)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.brandQuiet)
                // The chosen row wears the ring the board uses for a held tile.
                // No branch on state beyond the comparison itself.
                .overlay {
                    RoundedRectangle(
                        cornerRadius: DesignTokens.Radius.panel,
                        style: .continuous
                    )
                    .strokeBorder(
                        setup.difficulty == choice.difficulty
                            ? DesignTokens.Palette.accent
                            : .clear,
                        lineWidth: DesignTokens.Stroke.selectedRing
                    )
                }
            }
        }
    }

    /// One numeric row. `Stepper` owns the bounds too, but `SoloSetup` clamps on
    /// write regardless — a control that forgot its limits still could not
    /// produce a setup outside them.
    private func stepper(
        _ label: String,
        value: Binding<Int>,
        in range: ClosedRange<Int>
    ) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(label)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                Spacer()
                Text(String(value.wrappedValue))
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
            .font(DesignTokens.Typography.body)
        }
        .tint(DesignTokens.Palette.accent)
    }
}
