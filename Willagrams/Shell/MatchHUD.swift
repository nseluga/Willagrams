//
//  MatchHUD.swift
//  Willagrams
//
//  The in-match controls. Every value and every decision on this screen lives
//  in `MatchHUDModel`, which is where they can be executed by a test; this file
//  draws them and holds no branch that changes what the app does.
//
//  Nothing here reports the opponent. There is no row for their tiles, their
//  board or their presence, and `MatchHUDModel` publishes nothing to build one
//  from.
//

import SwiftUI
import WillagramsRules

/// The bar of in-match controls, laid out bottom-leading.
///
/// The corner matters: `BoardView` overlays its recenter control top-trailing,
/// and a HUD that covered it would take the player's only way back to their own
/// tiles. This is the opposite corner.
struct MatchHUD: View {

    let hud: MatchHUDModel

    var body: some View {
        HStack(spacing: DesignTokens.Space.m) {
            pool

            Button(hud.drawLabel) { hud.draw() }
                .buttonStyle(.brandPrimary)
                .disabled(!hud.isDrawEnabled)

            Button(hud.swapLabel) { if let tile = hud.swappableTile { hud.swap(tile) } }
                .buttonStyle(.brandQuiet)
                .disabled(!hud.isSwapEnabled)

            Button(hud.winLabel) { hud.claimWin() }
                .buttonStyle(.brandPrimary)
                .disabled(!hud.isWinEnabled)

            resign
        }
        .padding(DesignTokens.Space.m)
        // Bottom-leading, and intrinsically sized: landscape iPhone through
        // landscape iPad, no assumed viewport.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var pool: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            Text(hud.poolLabel)
                .font(DesignTokens.Typography.monoLabel)
                .tracking(DesignTokens.Typography.monoLabelTracking)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
            Text(hud.poolValue)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Two presses, never one: arming shows the confirmation, and only the
    /// confirmation resigns. Both branches render state the model already
    /// decided.
    @ViewBuilder private var resign: some View {
        if hud.resignArmed {
            Button(hud.resignConfirmLabel) { hud.confirmResign() }
                .buttonStyle(.brandQuiet)
                .foregroundStyle(DesignTokens.Palette.danger)
            Button(hud.resignCancelLabel) { hud.cancelResign() }
                .buttonStyle(.brandText)
        } else {
            Button(hud.resignLabel) { hud.armResign() }
                .buttonStyle(.brandText)
        }
    }
}
