import WillagramsRules

/// One selectable word list: what the player sees, the list itself, and the
/// content hash that travels on `.start` beside the id.
public struct DictionaryEntry: Sendable {
    public var id: String
    public var name: String
    public var list: any WordList
    public var hash: String

    public init(id: String, name: String, list: any WordList, hash: String) {
        self.id = id
        self.name = name
        self.list = list
        self.hash = hash
    }
}

/// The `dictionaryID` → word list mapping.
///
/// One entry today, deliberately: "standard" is the bundled ENABLE list, which
/// is exactly what every match has always used. Further lists are added here,
/// never synthesized.
public enum DictionaryCatalogue {

    /// The entry for `id`, or nil if no such list ships.
    ///
    /// An unknown id returns nil and never falls back to the standard list. A
    /// silent substitution would leave two devices playing different word lists
    /// under one agreed id — the desync this lookup exists to prevent.
    ///
    /// Throws only when the bundled list itself fails to load.
    // ponytail: builds and hashes the list on every call (a sort over ~170k
    // words). Fine for a settings screen; memoize if a caller ever puts this
    // on a hot path.
    public static func entry(for id: String) throws -> DictionaryEntry? {
        guard id == MatchOptions.standardDictionaryID else { return nil }
        let list = try EnableWordList()
        return DictionaryEntry(
            id: MatchOptions.standardDictionaryID,
            name: "Standard",
            list: list,
            hash: list.canonicalHash
        )
    }
}
