import Testing
import WillagramsRules
@testable import Settings

/// The summary is what the joining player reads instead of asking. So the
/// counts are the point: a summary that always prints three lines would tell a
/// standard match it is not standard.
@Suite("Rules summary")
struct RulesSummaryTests {

    static func lines(_ options: MatchOptions, name: String = "Enable") -> [String] {
        RulesSummary.lines(for: options, dictionaryName: name, swapName: "Swap")
    }

    @Test("Standard options are one line, the word list")
    func standardIsOneLine() {
        let lines = Self.lines(.standard)
        #expect(lines.count == 1)
        #expect(lines[0] == "Word list: Enable")
    }

    @Test("Two changed rules add exactly two lines")
    func changedRulesEachAddALine() {
        var options = MatchOptions.standard
        options.swapEnabled = false
        options.minimumWordLength = 4

        let lines = Self.lines(options)
        #expect(lines.count == 3)
        #expect(lines[0] == "Shortest word: 4 letters")
        #expect(lines[1] == "Swap: off")
        #expect(lines[2] == "Word list: Enable")
    }

    @Test("One changed rule adds exactly one line")
    func oneChangeIsTwoLines() {
        var options = MatchOptions.standard
        options.swapEnabled = false
        #expect(Self.lines(options).count == 2)

        var longer = MatchOptions.standard
        longer.minimumWordLength = 5
        #expect(Self.lines(longer).count == 2)
    }

    @Test("Order is stable across two calls with the same options")
    func orderIsStable() {
        var options = MatchOptions.standard
        options.swapEnabled = false
        options.minimumWordLength = 4
        #expect(Self.lines(options) == Self.lines(options))
    }

    /// A value outside ``MatchOptions/lengthRange`` is not a rule the host
    /// chose — it is clamped, and the line must describe the clamped value.
    @Test("Out-of-range options read as their validated form")
    func outOfRangeIsValidated() {
        var options = MatchOptions.standard
        options.minimumWordLength = 99
        #expect(Self.lines(options) == ["Shortest word: 15 letters", "Word list: Enable"])

        var atFloor = MatchOptions.standard
        atFloor.minimumWordLength = 1
        #expect(Self.lines(atFloor).count == 1)
    }

    /// The swap word is the caller's to supply, so the summary never spells a
    /// game word itself.
    @Test("The swap line is spelled by the caller")
    func swapWordComesFromTheCaller() {
        var options = MatchOptions.standard
        options.swapEnabled = false
        let lines = RulesSummary.lines(for: options, dictionaryName: "Enable", swapName: "Exchange")
        #expect(lines.contains("Exchange: off"))
    }

    @Test("Nothing is read from the catalogue")
    func summaryIsPure() throws {
        let source = try String(
            contentsOf: MatchOptionsViewSourceTests.root
                .appendingPathComponent("Willagrams/Settings/Model/RulesSummary.swift"),
            encoding: .utf8
        )
        for banned in ["DictionaryCatalogue", "SettingsStore", "import SwiftUI", "DesignTokens"] {
            #expect(!source.contains(banned), "RulesSummary reaches for \(banned)")
        }
    }
}
