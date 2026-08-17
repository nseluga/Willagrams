import Foundation
import Testing

/// No SwiftPM target compiles `Willagrams/Settings/Views`, so the view is
/// checked by reading its source, like `MatchOptionsViewSourceTests`.
///
/// The negative assertions are the point: they go red the day rule logic
/// migrates out of ``RulesSummary`` and into the view, where it would be a
/// second copy of the rule that travels.
@Suite("Rules in force view source")
struct RulesInForceViewSourceTests {

    static func stripped() throws -> String {
        let text = try String(
            contentsOf: MatchOptionsViewSourceTests.root
                .appendingPathComponent("Willagrams/Settings/Views/RulesInForceView.swift"),
            encoding: .utf8
        )
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.contains("//") ? $0.prefix(upTo: $0.range(of: "//")!.lowerBound) : $0 }
            .joined(separator: "\n")
    }

    @Test("The view exists and renders the summary lines")
    func viewRendersTheLines() throws {
        let text = try Self.stripped()
        #expect(text.contains("struct RulesInForceView: View"))
        #expect(text.contains("RulesSummary.lines("))
        #expect(text.contains("ForEach(lines"))
    }

    @Test("Every value on screen is a DesignTokens key")
    func viewIsBuiltFromTokens() throws {
        let text = try Self.stripped()
        for token in ["DesignTokens.Space", "DesignTokens.Typography", "DesignTokens.Palette"] {
            #expect(text.contains(token), "the view does not use \(token)")
        }
        for literal in ["cornerRadius:", "lineWidth:", "duration:", "Color.black", "Color.white",
                        "Color.gray", "colorScheme"] {
            #expect(!text.contains(literal), "the view hardcodes \(literal)")
        }
    }

    /// Which rules earn a line, and how each reads, is the model's.
    @Test("The view interprets no rule")
    func viewInterpretsNothing() throws {
        let text = try Self.stripped()
        for check in ["swapEnabled", "minimumWordLength", "MatchOptions.standard", "lengthRange",
                      "validated", "DictionaryCatalogue", "letters", "Word list",
                      "if ", "min(", "max("] {
            #expect(!text.contains(check), "the view interprets a rule: \(check)")
        }
    }

    @Test("The swap word comes from Terminology")
    func swapWordComesFromTerminology() throws {
        let text = try Self.stripped()
        #expect(text.contains("Terminology.swap"), "the view does not source the swap word")
        #expect(!text.contains("\"Swap"), "the view spells a game word itself")
    }
}
