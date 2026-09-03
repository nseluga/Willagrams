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

    /// How much bigger the call reads than an ordinary control. Big enough to
    /// be the thing you see when it appears, which is the whole point of it
    /// only appearing when it is true.
    private static let callScale: CGFloat = 1.35

    var body: some View {
        ZStack {
            pool
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // The two moves of an ordinary turn, together.
            HStack(spacing: DesignTokens.Space.m) {
                // Disabled on `isDrawPressable`, not `isDrawEnabled`: a press
                // that the board refuses has to LAND, or the refusal is never
                // counted and the board never flashes what is wrong with it.
                Button(hud.drawLabel) { hud.draw() }
                    .buttonStyle(.brandPrimary)
                    .disabled(!hud.isDrawPressable)

                // Absent, not disabled, when the rules have no swap in them —
                // see `MatchHUDModel.isSwapOffered`. A control that cannot work
                // for the whole match is not part of this game's furniture.
                if hud.isSwapOffered {
                    // Disabled on `isSwapPressable`, not `isSwapEnabled`, for
                    // the reason Draw is: a refused press has to LAND, or the
                    // pool running too low to swap is never shown to anyone.
                    Button(hud.swapLabel) { hud.swapPressed() }
                        .buttonStyle(.brandQuiet)
                        .disabled(!hud.isSwapPressable)
                }
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
            PoolBag()
                // The app's own ink, not a system grey: the bag is a piece of
                // the table, the same colour as the Draw button beneath it.
                .fill(DesignTokens.Palette.ink)

            // The drawstring, in the cream the tiles are. Drawn rather than
            // cut out of the sack so it reads as a cord tied round the neck
            // instead of a gap in the silhouette.
            Capsule(style: .continuous)
                .fill(DesignTokens.Palette.onInk)
                .frame(width: Self.bagSize * 0.30, height: Self.bagSize * 0.055)
                .offset(y: -Self.bagSize * 0.19)

            // The count in the tile face, not in a mono label: it is a number
            // of tiles, and every other number of tiles in this app is set in
            // that face. Sat on the body, below the neck the drawstring takes.
            Text(hud.poolValue)
                .font(DesignTokens.Typography.tileLetter)
                .foregroundStyle(DesignTokens.Palette.onInk)
                .offset(y: Self.poolValueDrop)
        }
        .frame(width: Self.bagSize, height: Self.bagSize)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hud.poolLabel)
        .accessibilityValue(hud.poolValue)
    }

    /// Half again the old glyph. The bag is the only readout on the board and
    /// it sits in a corner by itself, so it can afford the room.
    private static let bagSize: CGFloat = 96
    private static let poolValueDrop: CGFloat = Self.bagSize * 0.19

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

/// The tile bag, drawn rather than borrowed.
///
/// SF Symbols has no cartoon sack in it. `bag.fill` is a shopping tote with
/// square shoulders and straight handles — a piece of another app's furniture,
/// sitting on a table made of fat rounded cream tiles. This is the same two
/// curves the tiles are: a cinched neck over a heavy round body, with the mouth
/// domed open so it reads as something you reach into.
///
/// Normalised to its rect throughout, so the one size constant on `MatchHUD`
/// is the only number that sets how big it draws.
private struct PoolBag: Shape {

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        /// The three measures that make a sack rather than a bottle: a mouth
        /// that flares OUT at the top because the cloth is gathered, a cinch
        /// under it, and a belly wider than either.
        let mouth = w * 0.26
        let cinch = w * 0.20
        let side = w * 0.45
        let mouthTop = h * 0.07
        let cinchY = h * 0.31
        let widestY = h * 0.68
        let bottom = h * 0.97

        var path = Path()
        path.move(to: CGPoint(x: cx - mouth, y: mouthTop))
        // The mouth, domed rather than flat — a straight cut reads as a jar.
        path.addQuadCurve(
            to: CGPoint(x: cx + mouth, y: mouthTop),
            control: CGPoint(x: cx, y: mouthTop - h * 0.055)
        )
        // In to the cinch, then out to the belly, round the base and back up.
        // The belly controls sit outside the curve so the sides bulge instead
        // of running straight down to the bottom.
        path.addQuadCurve(
            to: CGPoint(x: cx + cinch, y: cinchY),
            control: CGPoint(x: cx + mouth * 0.92, y: cinchY - h * 0.06)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx + side, y: widestY),
            control: CGPoint(x: cx + side * 1.02, y: cinchY + (widestY - cinchY) * 0.30)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: bottom),
            control: CGPoint(x: cx + side * 0.95, y: bottom)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx - side, y: widestY),
            control: CGPoint(x: cx - side * 0.95, y: bottom)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx - cinch, y: cinchY),
            control: CGPoint(x: cx - side * 1.02, y: cinchY + (widestY - cinchY) * 0.30)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx - mouth, y: mouthTop),
            control: CGPoint(x: cx - mouth * 0.92, y: cinchY - h * 0.06)
        )
        path.closeSubpath()
        return path
    }
}
