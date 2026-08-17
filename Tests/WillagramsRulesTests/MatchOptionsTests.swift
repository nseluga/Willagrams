import Foundation
import Testing
@testable import WillagramsRules

@Suite("MatchOptions")
struct MatchOptionsTests {

    /// Keeps the pinned constant honest. `MatchOptions.standardDictionaryHash`
    /// is hardcoded so a match start costs no sort over 172k words — this is
    /// what fails when `dictionary.txt` changes and the constant does not.
    @Test func standardHashMatchesTheBundledList() throws {
        let list = try EnableWordList()
        #expect(list.canonicalHash == MatchOptions.standardDictionaryHash)
    }

    @Test func standardIsTodaysShippedBehavior() {
        #expect(MatchOptions.standard.minimumWordLength == 2)
        #expect(MatchOptions.standard.swapEnabled)
        #expect(MatchOptions.standard.dictionaryID == "standard")
    }

    @Test func validationClampsAndFiltersEverythingFromAPeer() {
        let hostile = MatchOptions(
            minimumWordLength: -5,
            swapEnabled: false,
            dictionaryID: String(repeating: "x/\u{0000}", count: 90),
            dictionaryHash: String(repeating: "ZZ", count: 90)
        ).validated

        #expect(hostile.minimumWordLength == 2)
        #expect(hostile.dictionaryID.count <= MatchOptions.identifierLimit)
        #expect(hostile.dictionaryID.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        // "ZZ" is not hex, so the filter takes it to empty rather than truncating junk.
        #expect(hostile.dictionaryHash.isEmpty)

        #expect(MatchOptions(
            minimumWordLength: 99, swapEnabled: true, dictionaryID: "a", dictionaryHash: "ab"
        ).validated.minimumWordLength == 15)
    }

    @Test func aStandardOptionsRoundTripIsUnchangedByValidation() {
        #expect(MatchOptions.standard.validated == MatchOptions.standard)
    }

    @Test func theMinimumLengthDecoratorRejectsShortWordsAndDefersTheRest() {
        let base = EnableWordList(words: ["at", "cat", "house"])
        let wrapped = MinimumLengthWordList(base: base, minimum: 3)

        #expect(base.contains("at"))
        #expect(!wrapped.contains("at"))
        #expect(wrapped.contains("cat"))
        #expect(!wrapped.contains("zebra"), "still defers validity to the base list")
    }

    @Test func hashingIsOrderAndDuplicateIndependentButContentSensitive() {
        let a = canonicalWordListHash(["cat", "at", "house"])
        let b = canonicalWordListHash(["house", "cat", "at", "cat"])
        let c = canonicalWordListHash(["cat", "at", "house", "dog"])

        #expect(a == b, "Set iteration order must never reach the digest")
        #expect(a != c, "one word's difference changes the hash")
        #expect(a == canonicalWordListHash(["CAT", "At", "HOUSE"]))
    }
}
