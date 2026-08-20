import Foundation
import Testing
import WillagramsRules

@testable import Settings

@Suite("Dictionary catalogue")
struct DictionaryCatalogueTests {

    @Test("standard resolves to the bundled list, named for the player")
    func standardResolves() throws {
        let entry = try #require(try DictionaryCatalogue.entry(for: "standard"))
        #expect(entry.id == MatchOptions.standardDictionaryID)
        #expect(entry.name == "Standard")
        #expect(entry.list.contains("aardvark"))
    }

    /// Recomputed from the bundled file, not read back off the entry: this is
    /// the check that the catalogue hashes the list it actually hands out.
    @Test("standard's hash is the engine hash of the bundled list's contents")
    func standardHashMatchesEngineHashOfBundledFile() throws {
        let url = try #require(EnableWordList.bundledURL)
        let text = try String(contentsOf: url, encoding: .utf8)
        let words = text.split(separator: "\n").map(String.init)
        let entry = try #require(try DictionaryCatalogue.entry(for: "standard"))
        #expect(entry.hash == canonicalWordListHash(words))
    }

    @Test("standard's hash is the constant peers agree on")
    func standardHashMatchesPinnedConstant() throws {
        let entry = try #require(try DictionaryCatalogue.entry(for: "standard"))
        #expect(entry.hash == MatchOptions.standardDictionaryHash)
    }

    /// No fallback: two devices agreeing on an id they resolve differently is
    /// the desync the whole id+hash scheme exists to prevent.
    @Test("an unknown id returns nil rather than substituting the standard list")
    func unknownIDReturnsNil() throws {
        for id in ["", "Standard", "standard ", "enable", "nonesuch"] {
            #expect(try DictionaryCatalogue.entry(for: id)?.id == nil)
        }
    }
}
