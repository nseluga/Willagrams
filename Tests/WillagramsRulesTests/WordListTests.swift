import Foundation
import Testing
@testable import WillagramsRules

@Suite("Word list")
struct WordListTests {
    @Test("The bundled ENABLE list loads with the recorded word count")
    func bundledListLoads() throws {
        let list = try EnableWordList()
        #expect(list.count == 172_823)
    }

    @Test("Lookup is case-insensitive and rejects non-words")
    func lookupIsCaseInsensitive() throws {
        let list = try EnableWordList()

        #expect(list.contains("cat"))
        #expect(list.contains("CAT"))
        #expect(list.contains("Zyzzyva"))
        #expect(!list.contains("qqqq"))
        #expect(!list.contains(""))
        #expect(!list.contains("cat!"))
    }

    @Test("No entry contains a non-letter, and none is shorter than two letters")
    func entriesAreCleanLetters() throws {
        let url = try #require(EnableWordList.bundledURL)
        let text = try String(contentsOf: url, encoding: .utf8)
        let offenders = text.split(separator: "\n").filter { line in
            line.count < 2 || line.contains(where: { !($0.isLetter && $0.isLowercase && $0.isASCII) })
        }
        #expect(offenders.isEmpty, "found \(offenders.count) malformed entries, e.g. \(offenders.prefix(3))")
    }

    @Test("1,000 lookups stay under 50ms once loaded")
    func lookupIsFast() throws {
        let list = try EnableWordList()
        let probes = (0..<1000).map { _ in String((0..<5).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! }) }

        let start = ContinuousClock.now
        for probe in probes { _ = list.contains(probe) }
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(50), "1,000 lookups took \(elapsed)")
    }

    @Test("An injected list backs validation without loading the bundle")
    func injectedListWorks() {
        let list = EnableWordList(words: ["cat", "cot"])

        #expect(list.contains("CAT"))
        #expect(!list.contains("dog"))
    }
}
