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

/// The in-match controls, in three corners around the board.
///
/// One bar across the bottom put the pool readout — a thing you read, never
/// press — inside the run of things you press, and left the whole top of the
/// table empty. So the readout goes up and out of the way, and the controls
/// split by what they cost: the two moves you make all match on the left, the
/// one that ends it on the right, far from them.
///
/// The bag goes top-*leading*, opposite `BoardView`'s recenter control: two
/// things cannot have the same corner, and the one you read belongs on the
/// side you read from.
struct MatchHUD: View {

    let hud: MatchHUDModel

    var body: some View {
        ZStack {
            pool
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // The two moves of an ordinary turn, together.
            HStack(spacing: DesignTokens.Space.m) {
                Button(hud.drawLabel) { hud.draw() }
                    .buttonStyle(.brandPrimary)
                    .disabled(!hud.isDrawEnabled)

                Button(hud.swapLabel) { if let tile = hud.swappableTile { hud.swap(tile) } }
                    .buttonStyle(.brandQuiet)
                    .disabled(!hud.isSwapEnabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            // Centre, and only when it can be pressed — see
            // `MatchHUDModel.isWinEnabled`. Not beside Draw: it arrives
            // mid-match, under a thumb that has been pressing Draw in that spot
            // all game, and ending the match is not a thing to mis-tap into.
            if hud.isWinEnabled {
                Button(hud.winLabel) { hud.claimWin() }
                    .buttonStyle(.brandPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }

            resign
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .padding(DesignTokens.Space.m)
    }

    /// The supply, as a bag with its count on it.
    ///
    /// The count is the readout; the bag is what makes it legible without a
    /// word beside it. `Terminology.pool` is still the accessibility label, so
    /// the frozen name for the supply is what VoiceOver reads — dropping the
    /// visible word is a layout decision, not a rename.
    private var pool: some View {
        ZStack {
            Image(systemName: Self.poolSymbol)
                .font(.system(size: Self.poolSymbolSize, weight: .regular))
                // The app's own ink, not a system grey: the bag is a piece of
                // the table, the same colour as the Draw button beneath it.
                .foregroundStyle(DesignTokens.Palette.ink)
            Text(hud.poolValue)
                .font(DesignTokens.Typography.monoLabel)
                .foregroundStyle(DesignTokens.Palette.onInk)
                // The bag's drawstring takes the top third of the glyph, so
                // centring the number in the frame puts it on the neck rather
                // than on the body.
                .offset(y: Self.poolValueDrop)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hud.poolLabel)
        .accessibilityValue(hud.poolValue)
    }

    private static let poolSymbol = "bag.fill"
    private static let poolSymbolSize: CGFloat = 56
    private static let poolValueDrop: CGFloat = 8

    /// Two presses, never one: arming shows the confirmation, and only the
    /// confirmation resigns. Both branches render state the model already
    /// decided.
    @ViewBuilder private var resign: some View {
        HStack(spacing: DesignTokens.Space.m) {
            if hud.resignArmed {
                Button(hud.resignCancelLabel) { hud.cancelResign() }
                    .buttonStyle(.brandText)
                Button(hud.resignConfirmLabel) { hud.confirmResign() }
                    .buttonStyle(.brandQuiet)
                    .foregroundStyle(DesignTokens.Palette.danger)
            } else {
                Button(hud.resignLabel) { hud.armResign() }
                    .buttonStyle(.brandText)
            }
        }
    }
}
