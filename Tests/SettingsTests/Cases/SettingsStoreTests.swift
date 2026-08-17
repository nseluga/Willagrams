import Foundation
import Testing
import WillagramsRules

@testable import Settings

/// A throwaway defaults suite, unique per test, torn down with the value.
///
/// Every test that touched `.standard` would leak into the developer's own
/// preferences and into the next test, so each one gets its own suite name and
/// `removePersistentDomain` on the way out.
private final class TemporarySuite {
    let name = "SettingsStoreTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}

@Suite("Settings store")
struct SettingsStoreTests {

    @Test("options survive a round trip through a fresh store")
    func roundTripsThroughAFreshStore() {
        let suite = TemporarySuite()
        let options = MatchOptions(
            minimumWordLength: 5,
            swapEnabled: false,
            dictionaryID: MatchOptions.standardDictionaryID,
            dictionaryHash: MatchOptions.standardDictionaryHash
        )

        SettingsStore(defaults: suite.defaults).save(options)

        // A second store over the same suite: proves the value came off the
        // defaults, not out of the writer's own memory.
        #expect(SettingsStore(defaults: suite.defaults).load() == options)
    }

    @Test("the shipped defaults round trip unchanged")
    func standardRoundTrips() {
        let suite = TemporarySuite()
        SettingsStore(defaults: suite.defaults).save(.standard)
        #expect(SettingsStore(defaults: suite.defaults).load() == MatchOptions.standard)
    }

    @Test("an empty suite reads as the shipped defaults")
    func emptySuiteReadsAsStandard() {
        let suite = TemporarySuite()
        #expect(SettingsStore(defaults: suite.defaults).load() == MatchOptions.standard)
    }

    @Test("malformed bytes read as the shipped defaults without trapping")
    func malformedBytesReadAsStandard() {
        let suite = TemporarySuite()
        suite.defaults.set(Data([0xFF, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]), forKey: "matchOptions")
        #expect(SettingsStore(defaults: suite.defaults).load() == MatchOptions.standard)
    }

    @Test("well-formed JSON of the wrong shape reads as the shipped defaults")
    func wrongShapeJSONReadsAsStandard() {
        let suite = TemporarySuite()
        suite.defaults.set(Data(#"{"minimumWordLength":"five"}"#.utf8), forKey: "matchOptions")
        #expect(SettingsStore(defaults: suite.defaults).load() == MatchOptions.standard)
    }

    @Test("a stored value that is not data at all reads as the shipped defaults")
    func nonDataValueReadsAsStandard() {
        let suite = TemporarySuite()
        suite.defaults.set("not data", forKey: "matchOptions")
        #expect(SettingsStore(defaults: suite.defaults).load() == MatchOptions.standard)
    }

    /// Stored options are a trust boundary: the file is user-writable, so a
    /// decodable-but-out-of-range value clamps rather than reaching the match.
    @Test("an out-of-range stored length clamps instead of loading as written")
    func outOfRangeLengthClamps() throws {
        let suite = TemporarySuite()
        let rogue = MatchOptions(
            minimumWordLength: 99,
            swapEnabled: true,
            dictionaryID: MatchOptions.standardDictionaryID,
            dictionaryHash: MatchOptions.standardDictionaryHash
        )
        suite.defaults.set(try JSONEncoder().encode(rogue), forKey: "matchOptions")

        #expect(
            SettingsStore(defaults: suite.defaults).load().minimumWordLength
                == MatchOptions.lengthRange.upperBound
        )
    }
}
