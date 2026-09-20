import Testing
import WillagramsRules
@testable import Match

@Suite("WILLA word list")
struct WillaWordListTests {

    @Test("WillaWordList accepts WILLA, defers the rest, and keeps the base's hash")
    func willaIsAWord() {
        let base = EnableWordList(words: ["cat"])
        let list = WillaWordList(base: base)

        #expect(base.contains("WILLA") == false, "the fixture already knows WILLA")
        #expect(list.contains("WILLA"))
        #expect(list.contains("willa"))
        #expect(list.contains("WILAL") == false)
        #expect(list.contains("CAT"))
        #expect(list.contains("dog") == false)
        #expect(list.canonicalHash == base.canonicalHash)
    }
}
