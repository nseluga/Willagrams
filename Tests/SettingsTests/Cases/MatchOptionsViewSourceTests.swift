import Foundation
import Testing

/// The view is Xcode-only — no SwiftPM target compiles `Willagrams/Settings/Views`,
/// and adding one would put an app path in a package manifest. So it is checked
/// the way `Tests/StyleTests` checks the style views: by reading the source.
///
/// What matters here is not that it renders, but that it stays *thin* — every
/// bound the model owns must be absent from the view, or the rule that travels
/// and the rule on screen can drift apart.
@Suite("Match options view source")
struct MatchOptionsViewSourceTests {

    /// Repo root, four levels up from `Tests/SettingsTests/Cases/`.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Cases
        .deletingLastPathComponent()   // SettingsTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    static func source() throws -> String {
        try String(
            contentsOf: root.appendingPathComponent("Willagrams/Settings/Views/MatchOptionsView.swift"),
            encoding: .utf8
        )
    }

    /// Drops `//` line comments so prose about a rule is not read as the rule.
    static func stripped() throws -> String {
        try source()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.contains("//") ? $0.prefix(upTo: $0.range(of: "//")!.lowerBound) : $0 }
            .joined(separator: "\n")
    }

    @Test("The view exists and renders the form")
    func viewRendersTheForm() throws {
        let text = try Self.stripped()
        #expect(text.contains("struct MatchOptionsView: View"))
        #expect(text.contains("@Binding private var form: MatchOptionsForm"))
        for binding in ["$form.minimumWordLength", "$form.swapEnabled", "form.dictionaryName"] {
            #expect(text.contains(binding), "the view never renders \(binding)")
        }
    }

    @Test("Every value on screen is a DesignTokens key")
    func viewIsBuiltFromTokens() throws {
        let text = try Self.stripped()
        for token in ["DesignTokens.Space", "DesignTokens.Typography", "DesignTokens.Palette",
                      "DesignTokens.Stroke"] {
            #expect(text.contains(token), "the view does not use \(token)")
        }
        for literal in ["cornerRadius:", "lineWidth:", "duration:", "Color.black", "Color.white",
                        "Color.gray", "colorScheme"] {
            #expect(!text.contains(literal), "the view hardcodes \(literal)")
        }
    }

    /// The clamp lives in the model. A range on the stepper, a `min`/`max`, or a
    /// catalogue lookup in the view would be a second place the rule lives.
    @Test("The view validates nothing")
    func viewDoesNoValidation() throws {
        let text = try Self.stripped()
        for check in ["lengthRange", "min(", "max(", "clamp", "DictionaryCatalogue",
                      "Stepper(value: $form.minimumWordLength, in:", "validated"] {
            #expect(!text.contains(check), "the view validates: \(check)")
        }
        // maxWidth: .infinity is layout, not a bound — and is the only `maxW`.
        #expect(!text.contains("MatchOptions("), "the view builds options itself")
    }

    @Test("The swap control is labelled from Terminology")
    func swapIsLabelledFromTerminology() throws {
        let text = try Self.stripped()
        #expect(text.contains("Terminology.swap"), "the swap control is not labelled from Terminology")
        // Every game word on screen must come from Terminology, so no string
        // literal in the view may be a game word at all. The IP fence itself is
        // `TerminologyFenceTests`, which already scans every literal under
        // `Willagrams/` — not repeated here, where the banned list would become
        // a second copy of it living under `Tests/`.
        #expect(!text.contains("Text(\"S"), "the view spells a game word itself")
    }
}
