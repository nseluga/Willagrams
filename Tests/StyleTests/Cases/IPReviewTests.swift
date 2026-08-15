import Foundation
import Testing

/// The IP review is prose, but three of its contents are load-bearing enough
/// to be worth a check: the full banned list, a pointer at the test that
/// enforces it, and the vocabulary table it documents.
@Suite("IP review")
struct IPReviewTests {

    static let text: String = {
        (try? String(contentsOf: StyleRepo.root.appendingPathComponent("docs/ip-review.md"), encoding: .utf8)) ?? ""
    }()

    @Test("It lists every term that must never ship")
    func listsTheBannedTerms() {
        let lowered = Self.text.lowercased()
        for term in ["bunch", "split", "peel", "dump", "bananas", "rotten"] {
            #expect(lowered.contains(term), "the review never names \(term)")
        }
    }

    @Test("It points at the test that enforces the fence")
    func pointsAtTheFence() {
        #expect(Self.text.contains("TerminologyFenceTests"))
    }

    @Test("It records every Terminology value as the distinct term")
    func coversTheVocabulary() throws {
        let terminology = try String(
            contentsOf: StyleRepo.styleDir.appendingPathComponent("Terminology.swift"),
            encoding: .utf8
        )
        for value in StyleRepo.matches(#"static let \w+ = "([^"]+)""#, in: terminology) {
            #expect(Self.text.contains(value), "the review does not account for \"\(value)\"")
        }
    }
}
