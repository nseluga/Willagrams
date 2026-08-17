import SwiftUI
import WillagramsRules

/// The countdown screen: the board, with a card over it.
///
/// An overlay, not a screen of its own, so the tiles arriving underneath are
/// seen arriving rather than appearing fully formed on the next screen. The
/// board is the same `BoardView` the match uses, holding the same board the
/// caller owns — this view swaps nothing out when the countdown ends.
///
/// It makes no decision: `CountdownOverlay` answers whether anything shows and
/// what it says, and that is executed in `CountdownOverlayTests`. There is no
/// timer here — the seconds are whatever `MatchSession` reports.
///
/// No motion of its own either. The deal animation belongs to a later item and
/// is authored on the board, not here.
struct CountdownView: View {

    /// The only source of the count. Observed, so each second it reports is a
    /// new body.
    let session: MatchSession

    /// The board and its model, owned by the caller: the tiles the deal lands
    /// arrive in these while the card is still up.
    @Binding var board: Board
    @Binding var model: BoardModel

    let dictionary: any WordList

    var body: some View {
        BoardView(
            board: $board,
            model: $model,
            camera: BoardCamera(),
            dictionary: dictionary,
            // Nothing is placeable before the match starts, and the board keeps
            // its own lock rather than this view covering it with a shield.
            inputLocked: true
        )
        .overlay {
            if let overlay = CountdownOverlay(session: session) {
                card(overlay)
            }
        }
    }

    /// A card, deliberately intrinsically sized and centred: it leaves the board
    /// visible around it at every viewport, iPhone through iPad, and there is no
    /// scrim over the tiles.
    private func card(_ overlay: CountdownOverlay) -> some View {
        VStack(spacing: DesignTokens.Space.s) {
            Text(overlay.title)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
            Text(String(overlay.secondsRemaining))
                .font(DesignTokens.Typography.display)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                // The card must not resize under each new digit.
                .monospacedDigit()
        }
        .padding(DesignTokens.Space.xl)
        .brandCard()
        .accessibilityElement(children: .combine)
    }
}
