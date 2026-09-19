//
//  MatchView.swift
//  Willagrams
//
//  The in-match screen: the board, with the controls over it. Composition only
//  — every value, every decision and every derived string on this screen is
//  already answered by `MatchBoard` and `MatchHUDModel`, which is where a test
//  can execute them.
//
//  It computes NO coordinate. The one geometric fact it knows is how big the
//  surface came out, and that is handed to `MatchBoard` unchanged for
//  `BoardLayout` to use — this file never reads it back or does arithmetic on
//  it. It makes no routing decision and holds no branch that changes what the
//  app does.
//

import SwiftUI
import WillagramsRules

/// The board surface with the in-match HUD over it.
///
/// ## Bindings, not copies
///
/// `board` and `model` go down as bindings straight off `MatchBoard`, so a
/// committed drag writes into the very value `MatchBoard.sync()` mirrors into
/// the session. A copy here would fork the board: the surface would show the
/// move and the session would not have it.
///
/// ## Staleness
///
/// This view stores nothing derived — only the two models it was handed, which
/// are classes owned by `MatchRun`. There is no cached board, no memoized
/// label and no reference to `ShellModel`, so there is nothing here to
/// invalidate and nothing to retain the shell.
///
/// ## The corners
///
/// `BoardView` puts its recenter control top-trailing and `MatchHUD` lays
/// itself out bottom-leading. Opposite corners, so the HUD never covers the
/// player's only way back to their own tiles — and the HUD is drawn in a
/// separate overlay rather than inside the board so neither can resize the
/// other.
struct MatchView: View {

    /// The live board state. `@Bindable` so `board` and `model` can be passed
    /// down as bindings rather than as values read out of it.
    @Bindable var matchBoard: MatchBoard

    let hud: MatchHUDModel

    let dictionary: any WordList

    /// The same switch `MatchHUD` reads for its bag size.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var hudInsets: EdgeInsets {
        let insets = MatchHUDLayout(isCompact: verticalSizeClass == .compact).boardInsets
        return EdgeInsets(top: insets.top, leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing)
    }

    var body: some View {
        GeometryReader { proxy in
            BoardView(
                board: $matchBoard.board,
                model: $matchBoard.model,
                // Where the surface starts looking. `BoardView` owns the live
                // camera and reports where it comes to rest through
                // `onCameraSettled`, so a delivery lands in the player's view.
                camera: matchBoard.camera,
                dictionary: dictionary,
                // Locked while something covers the board. `BoardView` writes
                // this into its model, which cancels a drag in flight.
                inputLocked: matchBoard.inputLocked,
                // The refusal count, not a flag: `BoardView` keys its flash on
                // the value changing, so a second refusal flashes again.
                completionAttempts: hud.completionAttempts,
                // The delivery, handed straight through: which tiles just came
                // out of the bag, and a token that changes each time some did.
                arriving: matchBoard.arrivingTileIDs,
                arrivalToken: matchBoard.arrivalToken,
                // The HUD's footprint, from the same layout `MatchHUD` sizes
                // itself with, so recenter frames tiles clear of the bag and
                // the control row. Solo and online both render through here.
                chromeInsets: hudInsets,
                onCameraSettled: matchBoard.cameraSettled
            )
            .overlay { MatchHUD(hud: hud) }
            .overlay {
                switch matchBoard.overlay {
                case .reconnecting:
                    ReconnectingOverlay()
                // The same card the pre-match countdown shows, over a board
                // with tiles already on it. `MatchBoard.overlay` decided that
                // this is a count and not a freeze; nothing is decided here.
                case let .resuming(secondsRemaining):
                    CountdownCard(
                        title: Terminology.countdownTitle, secondsRemaining: secondsRemaining)
                case nil:
                    EmptyView()
                }
            }
            // The measured size, handed over as-is. In `.onChange`, never in
            // the body: writing an observed property while SwiftUI is
            // evaluating a body is a mutation-during-update. `initial: true`
            // so the first layout is delivered too — without it the first
            // delivery would land against a zero viewport.
            .onChange(of: proxy.size, initial: true) {
                matchBoard.viewport = CGRect(origin: .zero, size: proxy.size)
            }
            .onChange(of: verticalSizeClass, initial: true) {
                matchBoard.insets = MatchHUDLayout(isCompact: verticalSizeClass == .compact).boardInsets
            }
        }
    }
}


/// The dim over a board nobody can play, saying that the match is being held
/// and that it is being held on the opponent.
///
/// Decides nothing: whether it is on screen at all is `MatchBoard.overlay`,
/// and the lock that makes it honest is `MatchBoard.inputLocked`. It takes no
/// peer, because there is nothing readable to say about one — see
/// ``MatchBoard/reconnectingLine``.
struct ReconnectingOverlay: View {

    var body: some View {
        ZStack {
            // The dim itself. `DesignTokens` is frozen and has no scrim, so
            // the one the comp asks for is built here from the ink it does
            // define — local to this view, like `BoardView.recenterLabel`.
            DesignTokens.Palette.ink.opacity(Self.dimOpacity).ignoresSafeArea()
            VStack(spacing: DesignTokens.Space.s) {
                Text(MatchBoard.reconnectingTitle)
                    .monoLabel()
                    .textCase(.uppercase)
                // A sentence, so it wraps rather than truncating, and clamped
                // narrow enough that it wraps on a phone instead of spanning
                // the whole landscape board.
                Text(MatchBoard.reconnectingLine)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.lineWidth)
            }
            .padding(DesignTokens.Space.xl)
            .brandCard()
        }
        .accessibilityElement(children: .combine)
    }

    private static let dimOpacity: Double = 0.35
    private static let lineWidth: CGFloat = 320
}
