import Foundation
import Testing
@testable import Match
import WillagramsRules

/// A peer controls every byte `MatchCodec.decode` sees. These tests throw
/// truncated and mutated bytes at it and assert only one thing: the process
/// is still standing afterward. A trap, a fatalError, or a hang would abort
/// the run before any `#expect` below could even fail — reaching the end of
/// each test is itself the assertion for the malformed-input cases.
@Suite("MatchCodec fuzzing")
struct MatchCodecFuzzTests {

    /// Deterministic PRNG so the mutation offsets below are reproducible,
    /// not flaky. Not cryptographic — a fixed-seed test double only.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private static func corpus() throws -> [Data] {
        var items = try MatchCodecTests.everyCase.map { try MatchCodec.encode($0) }

        let json = try Data(contentsOf: MatchCodecTests.goldenFixtureURL)
        let elements = try #require(try JSONSerialization.jsonObject(with: json) as? [Any])
        for element in elements {
            items.append(try JSONSerialization.data(withJSONObject: element))
        }
        return items
    }

    private static func attemptDecode(_ data: Data) {
        do {
            _ = try MatchCodec.decode(data)
        } catch {
            _ = error // statically a MatchCodecError via decode's typed throws.
        }
    }

    @Test("Every truncation prefix of every corpus message decodes or throws, never traps")
    func truncationNeverTraps() throws {
        for original in try Self.corpus() {
            for length in 0...original.count {
                Self.attemptDecode(Data(original.prefix(length)))
            }
        }
    }

    @Test("Seeded single-byte mutations of every corpus message decode or throw, never trap")
    func mutationNeverTraps() throws {
        var rng = SeededGenerator(seed: 0xC0FFEE)

        for original in try Self.corpus() where !original.isEmpty {
            for _ in 0..<10 {
                var mutated = original
                let offset = Int.random(in: 0..<mutated.count, using: &rng)
                mutated[mutated.startIndex + offset] = UInt8.random(in: 0...255, using: &rng)
                Self.attemptDecode(mutated)
            }
        }
    }

    @Test("Empty data fails to decode rather than trapping")
    func emptyDataFailsToDecode() {
        expectMalformedPayload(Data())
    }

    @Test("A bare JSON null fails to decode rather than trapping")
    func bareNullFailsToDecode() {
        expectMalformedPayload(Data("null".utf8))
    }

    @Test("A top-level JSON array fails to decode rather than trapping")
    func topLevelArrayFailsToDecode() {
        expectMalformedPayload(Data("[]".utf8))
    }

    @Test("An empty JSON object fails to decode rather than trapping")
    func emptyObjectFailsToDecode() {
        expectMalformedPayload(Data("{}".utf8))
    }

    @Test("A start case with the right key but missing fields fails to decode rather than trapping")
    func startWithMissingFieldsFailsToDecode() {
        expectMalformedPayload(Data(#"{"start":{}}"#.utf8))
    }

    @Test("A start case with a wrong field type fails to decode rather than trapping")
    func startWithWrongFieldTypeFailsToDecode() {
        let json = #"{"start":{"version":"one","seed":0,"startingHandSize":21,"countdownSeconds":3}}"#
        expectMalformedPayload(Data(json.utf8))
    }

    @Test("An unknown case name fails to decode rather than trapping")
    func unknownCaseNameFailsToDecode() {
        expectMalformedPayload(Data(#"{"notARealCase":{}}"#.utf8))
    }

    @Test("Deeply nested JSON fails to decode or is refused rather than trapping")
    func deeplyNestedJSONDoesNotTrap() {
        let depth = 1000
        let opening = String(repeating: "[", count: depth)
        let closing = String(repeating: "]", count: depth)
        Self.attemptDecode(Data((opening + closing).utf8))
    }

    private func expectMalformedPayload(_ data: Data) {
        #expect {
            try MatchCodec.decode(data)
        } throws: { error in
            guard case .malformedPayload = error as? MatchCodecError else { return false }
            return true
        }
    }
}
