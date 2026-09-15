import WillagramsRules

/// Any word list, plus WILLA.
///
/// App-layer on purpose: the canonical list and its hash stay exactly what
/// both devices pinned, so the start's dictionary-hash gate still matches.
/// The one extra word lives only here.
public struct WillaWordList: WordList {
    public static let word = "willa"

    public let base: any WordList

    public init(base: any WordList) {
        self.base = base
    }

    /// Case-insensitive, matching `EnableWordList`.
    public func contains(_ word: String) -> Bool {
        word.lowercased() == Self.word || base.contains(word)
    }

    /// The BASE's hash, never one including WILLA — see the type comment.
    /// Nil when the base carries no canonical hash of its own.
    public var canonicalHash: String? {
        (base as? EnableWordList)?.canonicalHash ?? (base as? WillaWordList)?.canonicalHash
    }
}
