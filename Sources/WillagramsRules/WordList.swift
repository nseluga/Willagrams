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

    /// Loads the list bundled with the package.
    public init() throws {
        guard let url = Bundle.module.url(forResource: "dictionary", withExtension: "txt") else {
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
}

public enum WordListError: Error, Equatable, Sendable {
    case resourceMissing
}
