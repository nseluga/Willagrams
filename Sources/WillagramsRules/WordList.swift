import Foundation

/// The dictionary a board is validated against.
///
/// A protocol so tests can inject a handful of words instead of loading 172k,
/// and so the word list can be swapped without touching validation.
public protocol WordList: Sendable {
    /// Case-insensitive. Returns false for anything containing a non-letter.
    func contains(_ word: String) -> Bool
}

/// ENABLE, loaded from the bundled `dictionary.txt`.
///
/// Backed by a `Set` — 172k entries costs a few MB and makes lookup O(1).
/// A trie would shrink memory, but nothing here needs prefix queries.
public struct EnableWordList: WordList {
    private let words: Set<String>

    public var count: Int { words.count }

    /// Where the bundled list lives.
    ///
    /// Exposed because `Bundle.module` inside a test target resolves to *that*
    /// target's bundle, not this one — a test cannot look the file up itself.
    public static var bundledURL: URL? {
        Bundle.module.url(forResource: "dictionary", withExtension: "txt")
    }

    /// Loads the list bundled with the package.
    public init() throws {
        guard let url = Self.bundledURL else {
            throw WordListError.resourceMissing
        }
        try self.init(contentsOf: url)
    }

    public init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        words = Set(text.split(separator: "\n").map(String.init))
    }

    /// For tests and previews.
    public init(words: some Sequence<String>) {
        self.words = Set(words.map { $0.lowercased() })
    }

    public func contains(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }

    /// This list's content hash, per ``canonicalWordListHash(_:)``.
    ///
    /// Computed on demand, not stored: it costs a sort over every word, and the
    /// only callers are the settings catalogue building a `MatchOptions` and the
    /// test that pins ``MatchOptions/standardDictionaryHash``. Neither is on a
    /// hot path. For the bundled list, prefer the pinned constant.
    public var canonicalHash: String {
        canonicalWordListHash(words)
    }
}

public enum WordListError: Error, Equatable, Sendable {
    case resourceMissing
}
