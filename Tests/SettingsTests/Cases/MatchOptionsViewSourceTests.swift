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
    static func strip(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.contains("//") ? $0.prefix(upTo: $0.range(of: "//")!.lowerBound) : $0 }
            .joined(separator: "\n")
    }

    static func stripped() throws -> String {
        strip(try source())
    }

    /// Comment-stripped source of any file, by repo-relative path.
    static func strippedFile(_ path: String) throws -> String {
        strip(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
    }

    /// Every `.swift` under `Willagrams/`.
    static func appSources() throws -> [URL] {
        let app = root.appendingPathComponent("Willagrams")
        let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
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

    /// Solo practice is a single-player screen, so nothing on it may say HOST.
    /// The non-embedded header is solo's only — the host lobby embeds the rows
    /// and draws its own eyebrow — so the literal is banned outright, by a scan
    /// of every app source rather than a pair of named paths that a third call
    /// site could slip past. The host lobby's own eyebrow is pinned present in
    /// the same test, so deleting it to satisfy the scan turns this red too.
    @Test("Solo shows no HOST eyebrow and the host lobby keeps its own")
    func soloHasNoHostEyebrow() throws {
        let view = try Self.stripped()
        #expect(!view.contains("HOST"), "MatchOptionsView still spells HOST")
        #expect(!view.contains(".monoLabel()"), "MatchOptionsView still draws an eyebrow")

        let solo = try Self.strippedFile("Willagrams/Shell/SoloSetupView.swift")
        #expect(solo.contains("MatchOptionsView(form: form)"), "solo no longer renders the options view")
        #expect(!solo.contains("embedded: true"), "solo switched to the embedded card")
        #expect(!solo.contains("HOST"), "SoloSetupView spells HOST")

        let lobby = try Self.strippedFile("Willagrams/Shell/TwoPlayerView.swift")
        #expect(lobby.contains("Text(Self.screenLabel).monoLabel()"), "the host lobby lost its eyebrow")
        #expect(
            lobby.range(of: #"screenLabel = "[^"]+""#, options: .regularExpression) != nil,
            "the host lobby's screenLabel is missing or empty"
        )

        var scanned = 0
        for file in try Self.appSources() {
            let text = try Self.strip(String(contentsOf: file, encoding: .utf8))
            scanned += 1
            #expect(!text.contains("\"HOST\""), "\(file.lastPathComponent) hard-codes \"HOST\"")
        }
        #expect(scanned >= 50, "the app source scan found only \(scanned) files")
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
