//
//  BotDifficultyMenu.swift
//  Willagrams
//
//  Everything the difficulty screen says and the one thing it does, as state a
//  test can execute. `BotDifficultyView` renders this and decides nothing.
//
//  NO SwiftUI here — this file is pure state, so it compiles into the macOS
//  `Bot` test target and must NOT be listed in that target's `exclude:`.
//
//  This file must never import GameKit.
//

/// One row on the difficulty screen: the preset, and the two lines that name it.
///
/// The copy lives beside the preset rather than inside the view, because the
/// macOS test target cannot compile a view.
public struct BotDifficultyChoice: Sendable, Equatable {

    public let difficulty: BotDifficulty
    /// The row's loud line.
    public let title: String
    /// The quiet line under it — what the preset feels like to play against,
    /// not the numbers behind it.
    public let detail: String

    public init(difficulty: BotDifficulty, title: String, detail: String) {
        self.difficulty = difficulty
        self.title = title
        self.detail = detail
    }
}

/// The difficulty screen's whole content and its whole behaviour.
///
/// It owns no match state and starts nothing: a press reports a preset to the
/// caller's closure, and the Shell decides what that means.
public struct BotDifficultyMenu: Sendable {

    /// The three presets in the order they are offered. A `let` on the type, so
    /// the view holds no `switch` over presets and a test reads the same list
    /// the screen draws.
    public static let choices: [BotDifficultyChoice] = [
        BotDifficultyChoice(
            difficulty: .easy,
            title: "Easy",
            detail: "Lays one tile at a time, and takes its time doing it."
        ),
        BotDifficultyChoice(
            difficulty: .medium,
            title: "Medium",
            detail: "Rearranges its own board, at a conversational pace."
        ),
        BotDifficultyChoice(
            difficulty: .hard,
            title: "Hard",
            detail: "Every move it knows, played quickly."
        ),
    ]

    /// Local chrome, not `Terminology`: that file is the frozen IP fence and
    /// names game concepts, not screens.
    public static let title = "Choose a difficulty"
    public static let backLabel = "Back"

    private let onChoose: @Sendable (BotDifficulty) -> Void
    private let onBack: @Sendable () -> Void

    public init(
        onChoose: @escaping @Sendable (BotDifficulty) -> Void,
        onBack: @escaping @Sendable () -> Void
    ) {
        self.onChoose = onChoose
        self.onBack = onBack
    }

    /// Reports the pressed row's preset. One press, one call.
    public func select(_ choice: BotDifficultyChoice) {
        onChoose(choice.difficulty)
    }

    /// Reports the back control. Nothing else here knows where back goes.
    public func back() {
        onBack()
    }
}
