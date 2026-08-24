import SwiftUI
import WillagramsRules

/// The app root: a `switch` over ``ShellModel/route`` and nothing else.
///
/// No navigation container of any kind — a guardrail test enforces that by
/// name. The screens are full-bleed modes rather than a drill-down hierarchy,
/// so a nav bar would be hidden on every one of them, and a navigation path
/// lives inside a View where no test in this repo can reach it.
/// This view holds no navigation state and makes no routing decision — it
/// renders whatever route `ShellModel` reports.
///
/// ## The three match screens
///
/// `.countdown`, `.match` and `.results` each read `ShellModel.run`. That run
/// used to be `#if DEBUG` — `SoloMatch` owned a `FakeTransport` that must not
/// reach a shipping build — so this file fenced their bodies. The far end is a
/// shipping `BotMatch` on a `LocalMatchLink` now, so nothing here is fenced and
/// solo practice ships.
///
/// A run that is nevertheless absent renders nothing rather than crashing or
/// fabricating a second session — the transition that failed to build one is
/// the defect, and it is `ShellModel`'s to fix.
struct ShellRootView: View {

    let shell: ShellModel

    var body: some View {
        Group {
            switch shell.route {
            case .menu: MenuView(shell: shell)
            case .soloSetup: SoloSetupView(shell: shell)
            case .howToPlay: HowToPlayView(shell: shell)
            case .countdown: countdown
            case .match: match
            case .results: results
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Palette.canvasTop)
    }

    /// The board, with the count over it. Reads the run's session (the count),
    /// its `MatchBoard` (the tiles the deal is landing) and its dictionary.
    /// Bindings, not copies: the deal writes into the very board the match
    /// screen goes on to show.
    @ViewBuilder private var countdown: some View {
        if let run = shell.run {
            @Bindable var matchBoard = run.board
            CountdownView(
                session: run.session,
                board: $matchBoard.board,
                model: $matchBoard.model,
                dictionary: run.dictionary
            )
            // `MatchSession` runs the countdown and flips its own status to
            // `.playing` when the last second lands. Nothing was carrying that
            // fact to the route, so the app sat on `.countdown` forever: the
            // card vanished, the board stayed, and the HUD never arrived.
            // Still no decision here — `CountdownOverlay` answers whether the
            // count is over, exactly as it answers whether the card shows, and
            // `ShellModel.countdownFinished` owns the transition.
            .onChange(of: CountdownOverlay(session: run.session) == nil, initial: true) { _, isOver in
                if isOver { shell.countdownFinished() }
            }
        }
    }

    /// The board, with the HUD over it. Reads the run's `MatchBoard`, its
    /// `MatchHUDModel` and its dictionary — the same instances the countdown
    /// just showed, so nothing is rebuilt across the transition.
    @ViewBuilder private var match: some View {
        if let run = shell.run {
            MatchView(matchBoard: run.board, hud: run.hud, dictionary: run.dictionary)
        }
    }

    /// The end screen over the board the match ended on. Reads the run's
    /// `results(board:)` factory — the one place the two ways out are wired —
    /// and its dictionary.
    @ViewBuilder private var results: some View {
        if let run = shell.run {
            ResultsView(results: run.results(board: run.board.board), dictionary: run.dictionary)
        }
    }

}
