//
//  ResultsView.swift
//  Willagrams
//
//  The end screen. Every value and every decision on it lives in
//  `ResultsModel`, which is where a test can execute them; this file draws them
//  and holds no branch that changes what the app does.
//
//  The board is the background, not a second screen: the result sits over the
//  board the match ended on, and that board is locked — `BoardView` takes the
//  lock as a plain boolean and refuses a pickup before a drag is ever built.
//

import SwiftUI
import WillagramsRules

struct ResultsView: View {

    let results: ResultsModel

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var headlineIn = false
    private let dictionary: any WordList

    init(results: ResultsModel, dictionary: any WordList) {
        self.results = results
        self.dictionary = dictionary
    }

    var body: some View {
        ZStack {
            boardLayer
            if results.isCardShown {
                card
                    .transition(.opacity)
                    .overlay { burst }
            }
        }
        .overlay(alignment: .bottom) {
            if !results.isCardShown { bar }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: results.isCardShown)
    }

    /// The shown board, panned and zoomed but never played. Keyed on the side so
    /// a switch re-frames instead of reusing the other board's camera.
    @ViewBuilder private var boardLayer: some View {
        if let board = results.shownBoard {
            ResultsBoard(board: board, dictionary: dictionary).id(results.shownSide)
        } else {
            ZStack {
                DesignTokens.Palette.boardSurface.ignoresSafeArea()
                Text(ResultsModel.opponentBoardMissing)
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(DesignTokens.Space.l)
            }
        }
    }

    /// Always-visible once the card is closed: board switch, the card back, and
    /// the two ways out.
    private var bar: some View {
        HStack(spacing: DesignTokens.Space.s) {
            Picker("Board", selection: Binding(
                get: { results.shownSide }, set: { results.show($0) }
            )) {
                Text(ResultsModel.yourBoardLabel).tag(ResultsBoardSide.yours)
                Text(ResultsModel.opponentBoardLabel).tag(ResultsBoardSide.opponents)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Button { results.reopenCard() } label: { Text(ResultsModel.showResultLabel) }
                .buttonStyle(.brandQuiet)
            if results.isRematchEnabled {
                Button { results.rematch() } label: { Text(ResultsModel.rematchLabel) }
                    .buttonStyle(.brandPrimary)
            }
            Button { results.mainMenu() } label: { Text(ResultsModel.mainMenuLabel) }
                .buttonStyle(.brandQuiet)
        }
        .padding(DesignTokens.Space.s)
        .brandCard()
        .padding(DesignTokens.Space.s)
    }

    /// Intrinsically sized and centred over the board: landscape iPhone through
    /// landscape iPad, no assumed viewport.
    private var card: some View {
        VStack(spacing: DesignTokens.Space.l) {
            Text(Self.kicker)
                .monoLabel()

            Text(results.headline)
                .font(DesignTokens.Typography.display)
                .tracking(DesignTokens.Typography.displayTracking)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .lineLimit(1)
                .allowsTightening(true)
                .accessibilityAddTraits(.isHeader)
                // A win scales in (a plain fade under reduce motion).
                .opacity(!results.didLocalPlayerWin || headlineIn ? 1 : 0)
                .scaleEffect(!results.didLocalPlayerWin || reduceMotion || headlineIn ? 1 : 0.4)

            if let reason = results.reason {
                Text(reason)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .multilineTextAlignment(.center)
            }

            // The opponent's board is one tap away whoever won.
            HStack(spacing: DesignTokens.Space.s) {
                Button(ResultsModel.yourBoardLabel) { results.show(.yours); results.closeCard() }
                Button(ResultsModel.opponentBoardLabel) { results.show(.opponents); results.closeCard() }
            }
            .buttonStyle(.brandQuiet)

            HStack(spacing: DesignTokens.Space.m) {
                // Absent, not disabled. There is nothing to rematch into on a
                // network match, and a greyed control invites a press that can
                // never work.
                if results.isRematchEnabled {
                    Button { results.rematch() } label: {
                        Text(ResultsModel.rematchLabel).resultsActionLabel()
                    }
                    .buttonStyle(.brandPrimary)
                }

                Button { results.mainMenu() } label: {
                    Text(ResultsModel.mainMenuLabel).resultsActionLabel()
                }
                .buttonStyle(.brandQuiet)
            }
        }
        .padding(verticalSizeClass == .compact ? DesignTokens.Space.l : DesignTokens.Space.xl)
        .brandCard()
        .overlay(alignment: .topTrailing) {
            Button { results.closeCard() } label: {
                Image(systemName: "xmark")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(ResultsModel.closeLabel)
        }
        .padding(DesignTokens.Space.l)
        .onAppear {
            guard results.didLocalPlayerWin else { return }
            withAnimation(reduceMotion ? .easeIn(duration: 0.4) : .spring(response: 0.5, dampingFraction: 0.55)) {
                headlineIn = true
            }
        }
    }

    /// Tiles in brand colours thrown over the card; touch-through. Reduce
    /// motion draws none (the headline fades instead).
    @ViewBuilder private var burst: some View {
        if results.showsBurst && !reduceMotion {
            TileBurst { results.burstFinished() }
                .allowsHitTesting(false)
        }
    }

    /// Screen chrome, not `Terminology`: that file names game concepts, and
    /// "the match is over" is a statement about the screen, not the game.
    private static let kicker = "MATCH OVER"
}

private extension View {

    /// The two end-of-match actions read as a matched pair, so they share a
    /// width rather than sizing to their labels.
    func resultsActionLabel() -> some View {
        frame(minWidth: 132, minHeight: 36)
    }
}

/// A burst of tile-coloured squares from the card's centre.
private struct TileBurst: View {
    let finished: () -> Void
    @State private var go = false
    private static let colors = [
        DesignTokens.Palette.accent, DesignTokens.Palette.tileFace,
        DesignTokens.Palette.tileEdge, DesignTokens.Palette.ink,
    ]
    private static let count = 28

    var body: some View {
        ZStack {
            ForEach(0..<Self.count, id: \.self) { i in
                let angle = Double(i) / Double(Self.count) * 2 * .pi
                let reach = CGFloat(120 + (i * 37) % 140)
                RoundedRectangle(cornerRadius: DesignTokens.Radius.tile)
                    .fill(Self.colors[i % Self.colors.count])
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(go ? Double(i * 53 % 360) : 0))
                    .offset(x: go ? cos(angle) * reach : 0, y: go ? sin(angle) * reach + 40 : 0)
                    .opacity(go ? 0 : 1)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4)) { go = true }
            Task { try? await Task.sleep(for: .seconds(1.5)); finished() }
        }
        .accessibilityHidden(true)
    }
}

/// Draws one final board. Input-locked, so a tile cannot be picked up, but the
/// camera still pans and zooms (`BoardGesture` turns a locked touch into a pan).
private struct ResultsBoard: View {
    @State private var board: Board
    @State private var model = BoardModel(inputLocked: ResultsModel.inputLocked)
    let dictionary: any WordList

    init(board: Board, dictionary: any WordList) {
        _board = State(initialValue: board)
        self.dictionary = dictionary
    }

    var body: some View {
        BoardView(
            board: $board, model: $model, camera: BoardCamera(),
            dictionary: dictionary, inputLocked: ResultsModel.inputLocked
        )
    }
}
