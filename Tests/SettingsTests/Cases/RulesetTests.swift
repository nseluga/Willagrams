import Foundation
import Testing
import WillagramsRules

@testable import Settings

@Suite("Ruleset catalogue")
struct RulesetTests {

    @Test("holds exactly one preset")
    func catalogueHasOneEntry() {
        #expect(Ruleset.catalogue.count == 1)
    }

    @Test("that preset is named Standard")
    func theEntryIsNamedStandard() {
        #expect(Ruleset.catalogue.first?.name == "Standard")
    }

    @Test("Standard's options are the shipped defaults")
    func standardOptionsMatchMatchOptionsStandard() {
        #expect(Ruleset.catalogue.first?.options == MatchOptions.standard)
    }

    /// The symlink is the point: a copied tree would still pass every test
    /// above while drifting from the app's real sources.
    @Test("SettingsSrc is a symlink to the app's settings model")
    func settingsSrcIsASymlink() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let link = packageRoot.appendingPathComponent("SettingsSrc")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(target == "../../Willagrams/Settings/Model")
    }
}
