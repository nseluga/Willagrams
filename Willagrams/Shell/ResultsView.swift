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

    /// The board `BoardView` draws. A `@State` because the binding demands one;
    /// nothing on this screen writes it, because nothing on this screen can move
    /// a tile.
    @State private var board: Board
    @State private var model: BoardModel
    private let dictionary: any WordList

    init(results: ResultsModel, dictionary: any WordList) {
        self.results = results
        self.dictionary = dictionary
        _board = State(initialValue: results.board)
        _model = State(initialValue: BoardModel(inputLocked: ResultsModel.inputLocked))
    }

    var body: some View {
        BoardView(
            board: $board,
            model: $model,
            camera: BoardCamera(),
            dictionary: dictionary,
            inputLocked: ResultsModel.inputLocked
        )
        .overlay { card }
    }

    /// Intrinsically sized and centred over the board: landscape iPhone through
    /// landscape iPad, no assumed viewport.
    private var card: some View {
        VStack(spacing: DesignTokens.Space.l) {
            Text(results.headline)
                .font(DesignTokens.Typography.display)
                .tracking(DesignTokens.Typography.displayTracking)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .lineLimit(1)
                .allowsTightening(true)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: DesignTokens.Space.m) {
                Button(ResultsModel.rematchLabel) { results.rematch() }
                    .buttonStyle(.brandPrimary)
                    .disabled(!results.isRematchEnabled)

                Button(ResultsModel.mainMenuLabel) { results.mainMenu() }
                    .buttonStyle(.brandQuiet)
            }
        }
        .padding(DesignTokens.Space.xl)
        .brandCard()
        .padding(DesignTokens.Space.l)
    }
}
