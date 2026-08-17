import Foundation
import Testing
import WillagramsRules

@testable import Settings

@Suite("Match options form")
struct MatchOptionsFormTests {

    @Test("An untouched form is exactly today's shipped behavior")
    func untouchedFormIsStandard() throws {
        #expect(try MatchOptionsForm().options == MatchOptions.standard)
    }

    @Test("The minimum clamps to the engine's range on write")
    func minimumClamps() throws {
        var form = try MatchOptionsForm()

        form.minimumWordLength = 1
        #expect(form.minimumWordLength == 2)
        #expect(form.options.minimumWordLength == 2)

        form.minimumWordLength = 99
        #expect(form.minimumWordLength == 15)
        #expect(form.options.minimumWordLength == 15)

        form.minimumWordLength = -100
        #expect(form.minimumWordLength == MatchOptions.lengthRange.lowerBound)

        // A value already inside the range is stored as written.
        form.minimumWordLength = 7
        #expect(form.minimumWordLength == 7)
    }

    @Test("The hash is the catalogue's hash for the selected id")
    func hashComesFromTheCatalogue() throws {
        let form = try MatchOptionsForm()
        let entry = try #require(try DictionaryCatalogue.entry(for: form.options.dictionaryID))
        #expect(form.options.dictionaryHash == entry.hash)
    }

    /// The carried defect this form has to close: the catalogue matches an id
    /// exactly while `MatchOptions.validated` lowercases it, so a form that
    /// looked up one spelling and stored another would emit a hash belonging to
    /// no entry. Feeding it an id that differs only in case is what catches it.
    @Test("An id differing only in case resolves, and stays self-consistent")
    func oddlySpelledIDNormalizesBeforeLookup() throws {
        for spelling in ["STANDARD", "Standard", "sTaNdArD"] {
            var form = try MatchOptionsForm()
            form.minimumWordLength = 5
            try form.selectDictionary(spelling)

            let options = form.options
            #expect(options.dictionaryID == MatchOptions.standardDictionaryID)

            // The id it sends must be an id the catalogue can resolve...
            let entry = try #require(try DictionaryCatalogue.entry(for: options.dictionaryID))
            // ...to the very hash it sent.
            #expect(options.dictionaryHash == entry.hash)
            // ...and must survive the peer-side trust boundary unchanged.
            #expect(options.validated == options)
        }
    }

    @Test("An unknown id is refused and leaves the selection untouched")
    func unknownIDIsRefused() throws {
        var form = try MatchOptionsForm()
        form.swapEnabled = false

        for id in ["", "enable", "nonesuch", "standard-2"] {
            #expect(throws: MatchOptionsFormError.unknownDictionary(id)) {
                try form.selectDictionary(id)
            }
        }

        #expect(form.options.dictionaryID == MatchOptions.standardDictionaryID)
        #expect(form.options.dictionaryHash == MatchOptions.standardDictionaryHash)
        #expect(form.swapEnabled == false)
    }

    @Test("Every field the host can change reaches the produced options")
    func editsReachTheOptions() throws {
        var form = try MatchOptionsForm()
        form.swapEnabled = false
        form.minimumWordLength = 4

        #expect(form.options == MatchOptions(
            minimumWordLength: 4,
            swapEnabled: false,
            dictionaryID: MatchOptions.standardDictionaryID,
            dictionaryHash: MatchOptions.standardDictionaryHash
        ))
    }
}
