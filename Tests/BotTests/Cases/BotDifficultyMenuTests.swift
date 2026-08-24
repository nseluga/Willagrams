import Foundation
import Testing
@testable import Bot

/// The difficulty screen's content and its one action, executed without ever
/// building a view — the macOS test target cannot compile SwiftUI, which is why
/// every string and every decision lives in `BotDifficultyMenu`.
@Suite("Bot difficulty menu")
struct BotDifficultyMenuTests {

    /// Counts what the screen reported. A class so the closure can write to it.
    private final class Reported: @unchecked Sendable {
        var presets: [BotDifficulty] = []
        var backs = 0
    }

    private func menu(_ reported: Reported) -> BotDifficultyMenu {
        BotDifficultyMenu(
            onChoose: { reported.presets.append($0) },
            onBack: { reported.backs += 1 }
        )
    }

    @Test("The screen offers exactly the three presets")
    func offersThreePresets() {
        #expect(BotDifficultyMenu.choices.map(\.difficulty) == [.easy, .medium, .hard])
    }

    @Test("Selecting a row reports that preset exactly once")
    func selectionReportsOnce() {
        for choice in BotDifficultyMenu.choices {
            let reported = Reported()
            menu(reported).select(choice)
            #expect(reported.presets == [choice.difficulty], "\(choice.title) reported \(reported.presets)")
            #expect(reported.backs == 0, "\(choice.title) also reported back")
        }
    }

    @Test("Back reports back and no preset")
    func backReportsBack() {
        let reported = Reported()
        menu(reported).back()
        #expect(reported.backs == 1)
        #expect(reported.presets.isEmpty)
    }

    @Test("Every row carries a title and a detail line")
    func everyRowIsLabelled() {
        for choice in BotDifficultyMenu.choices {
            #expect(!choice.title.isEmpty)
            #expect(!choice.detail.isEmpty)
        }
        #expect(Set(BotDifficultyMenu.choices.map(\.title)).count == BotDifficultyMenu.choices.count)
    }

    /// The presets have to be *distinguishable* — three rows that play the same
    /// are three rows that lie — and easy has to be the one that reaches least and waits longest.
    ///
    @Test("The three presets differ in depth and pace, and easy is the shallowest and slowest")
    func presetsDiffer() {
        let presets: [BotDifficulty] = [.easy, .medium, .hard]
        #expect(Set(presets.map(\.ladderDepth)).count == presets.count)
        #expect(Set(presets.map(\.thinkDelay)).count == presets.count)
        #expect(BotDifficulty.easy.ladderDepth == presets.map(\.ladderDepth).min())
        #expect(BotDifficulty.easy.thinkDelay == presets.map(\.thinkDelay).max())
    }
}
