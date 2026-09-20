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

            // A single portrait column: the opponent presets over the match
            // rules, scrolled so a small phone never clips them. The start
            // action sits outside this scroll view, anchored to the screen's
            // bottom edge below.
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
                    opponent(setup: setup)
                    rules(setup: setup)
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
        .screenPadding()
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

    /// What the match itself is played under: the starting hand, which is this
    /// screen's own, and then the settings lane's own options screen, embedded
    /// as it ships. There is no second copy of those rows here — the toggle and
    /// the length control are `MatchOptionsView`'s, bound straight to the
    /// `MatchOptionsForm` `SoloSetup` loaded on the way in.
    ///
    /// The form is nil only when the bundled word list failed to read, which is
    /// the model's state to hold, not a decision this view takes.
    private func rules(setup: SoloSetup) -> some View {
        @Bindable var setup = setup
        return VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            stepper(
                SoloSetup.handSizeLabel,
                value: $setup.handSize,
                in: SoloSetup.handSizeRange
            )
            if let form = Binding($setup.optionsForm) {
                MatchOptionsView(form: form)
            }
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
