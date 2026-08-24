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

/// The in-match controls, pinned to the four places a thumb can reach without
/// crossing the board.
///
/// - The bag sits top-leading. It is where tiles come from, and
///   ``MatchView`` flies new ones out of that corner, so the count and the
///   source are the same object rather than two things the player has to relate.
/// - The call sits dead centre and is *absent* until it can be pressed. It is
///   the one control that ends the match, so it appears at the moment it becomes
///   true and never sits greyed out inviting a press that cannot land.
/// - Draw and Swap sit bottom-leading, Resign bottom-trailing — the ending
///   apart from the two the player reaches for.
///
/// Top-trailing is left empty on purpose: `BoardView` overlays its recenter
/// control there, and a HUD that covered it would take the player's only way
/// back to their own tiles.
struct MatchHUD: View {

    let hud: MatchHUDModel

    /// How much bigger the call reads than an ordinary control. Big enough to
    /// be the thing you see when it appears, which is the whole point of it
    /// only appearing when it is true.
    private static let callScale: CGFloat = 1.35

    var body: some View {
        ZStack {
            bag
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            call
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            HStack(spacing: DesignTokens.Space.m) {
                // Disabled on `isDrawPressable`, not `isDrawEnabled`: a press
                // that the board refuses has to LAND, or the refusal is never
                // counted and the board never flashes what is wrong with it.
                Button(hud.drawLabel) { hud.draw() }
                    .buttonStyle(.brandPrimary)
                    .disabled(!hud.isDrawPressable)

                Button(hud.swapLabel) { if let tile = hud.swappableTile { hud.swap(tile) } }
                    .buttonStyle(.brandQuiet)
                    .disabled(!hud.isSwapEnabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            resign
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .padding(DesignTokens.Space.m)
        // Intrinsically sized throughout: landscape iPhone through landscape
        // iPad, no assumed viewport.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The supply, drawn as the thing it is. The number rides the bag rather
    /// than sitting beside it, so one glance answers both "how many" and "from
    /// where".
    /// Half again the size of an ordinary glyph on this screen. A
    /// `scaleEffect`, not a bigger font: the number rides the bag, so the two
    /// have to grow together or the count slides off it.
    private static let bagScale: CGFloat = 1.5

    private var bag: some View {
        Image(systemName: Self.bagSymbol)
            .font(DesignTokens.Typography.title)
            .foregroundStyle(DesignTokens.Palette.ink)
            .overlay(alignment: .bottom) {
                Text(hud.poolValue)
                    .font(DesignTokens.Typography.monoLabel)
                    .foregroundStyle(DesignTokens.Palette.onInk)
                    .padding(.bottom, DesignTokens.Space.xs)
            }
            .scaleEffect(Self.bagScale)
            // The scale is drawing only, so the layout still reserves the
            // unscaled glyph. The padding is what keeps the grown bag off the
            // edge it would otherwise bleed over.
            .padding(DesignTokens.Space.s)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(hud.poolLabel) \(hud.poolValue)")
    }

    /// The only SF Symbol on this screen beside the recenter arrow, and named
    /// once so there is one string to change.
    static let bagSymbol = "bag.fill"

    /// Shown only when the model says the call would be accepted — see
    /// ``MatchHUDModel/isWinEnabled``. There is no disabled rendering of this
    /// control, so no `.disabled` here either.
    @ViewBuilder private var call: some View {
        if hud.isWinEnabled {
            Button { hud.claimWin() } label: {
                Text(hud.winLabel)
                    .font(DesignTokens.Typography.title)
                    .padding(DesignTokens.Space.s)
            }
            .buttonStyle(.brandPrimary)
            .scaleEffect(Self.callScale)
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// Two presses, never one: arming shows the confirmation, and only the
    /// confirmation resigns. Both branches render state the model already
    /// decided.
    @ViewBuilder private var resign: some View {
        if hud.resignArmed {
            HStack(spacing: DesignTokens.Space.s) {
                Button(hud.resignCancelLabel) { hud.cancelResign() }
                    .buttonStyle(.brandText)
                Button(hud.resignConfirmLabel) { hud.confirmResign() }
                    .buttonStyle(.brandQuiet)
                    .foregroundStyle(DesignTokens.Palette.danger)
            }
        } else {
            Button(hud.resignLabel) { hud.armResign() }
                .buttonStyle(.brandText)
        }
    }
}
