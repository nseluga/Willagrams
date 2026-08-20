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

    var body: some View {
        GeometryReader { proxy in
            BoardView(
                board: $matchBoard.board,
                model: $matchBoard.model,
                // Where the surface starts looking. `BoardView` owns the live
                // camera from here on and publishes no way to read it back, so
                // this is the starting value and not a two-way wire — see the
                // engineer report.
                camera: matchBoard.camera,
                dictionary: dictionary,
                // The refusal count, not a flag: `BoardView` keys its flash on
                // the value changing, so a second refusal flashes again.
                completionAttempts: hud.completionAttempts
            )
            .overlay { MatchHUD(hud: hud) }
            // The measured size, handed over as-is. In `.onChange`, never in
            // the body: writing an observed property while SwiftUI is
            // evaluating a body is a mutation-during-update. `initial: true`
            // so the first layout is delivered too — without it the first
            // delivery would land against a zero viewport.
            .onChange(of: proxy.size, initial: true) {
                matchBoard.viewport = CGRect(origin: .zero, size: proxy.size)
            }
        }
    }
}
