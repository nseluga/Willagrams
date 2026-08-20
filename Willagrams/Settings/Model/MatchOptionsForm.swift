import WillagramsRules

/// What went wrong while editing the options.
public enum MatchOptionsFormError: Error, Equatable, Sendable {
    /// No word list ships under that id — see ``DictionaryCatalogue``.
    case unknownDictionary(String)
}

/// The host's editable match options, and every rule about what is editable.
///
/// All bounds live here: the view sets values and never checks them, so a
/// control that forgets its own limits still cannot produce options outside
/// them. `minimumWordLength` clamps to ``MatchOptions/lengthRange`` on write,
/// and the dictionary is only ever changed by resolving an id in
/// ``DictionaryCatalogue`` — the id and hash are taken from the *same* entry, so
/// ``options`` cannot describe a list under a hash that is not its own.
///
/// The id is normalized before the lookup, using ``MatchOptions/validated`` so
/// the rule is the engine's and not a second copy of it. Otherwise an id that
/// survives validation in one form ("STANDARD" → "standard") but is looked up in
/// another resolves to nothing, and the lookup key stops being the stored key.
///
/// Resolving costs a hash over the whole word list, so it happens once per
/// change of selection — never per keystroke and never in ``options``, which
/// only reads what the last resolution stored.
public struct MatchOptionsForm: Equatable, Sendable {

    /// When false, the host refuses every ``Terminology/swap`` request.
    public var swapEnabled: Bool

    private var storedMinimum: Int

    /// Shortest word the dictionary will accept. Writes clamp to
    /// ``MatchOptions/lengthRange`` — 1 stores 2, 99 stores 15.
    public var minimumWordLength: Int {
        get { storedMinimum }
        set {
            storedMinimum = min(
                max(MatchOptions.lengthRange.lowerBound, newValue),
                MatchOptions.lengthRange.upperBound
            )
        }
    }

    /// The selected list's id, as the catalogue spells it.
    public private(set) var dictionaryID: String

    /// That list's player-facing name.
    public private(set) var dictionaryName: String

    /// That list's content hash, taken from the same entry as the id.
    public private(set) var dictionaryHash: String

    /// A form on today's shipped defaults: ``MatchOptions/standard``.
    public init() throws {
        self.swapEnabled = MatchOptions.standard.swapEnabled
        self.storedMinimum = MatchOptions.standard.minimumWordLength
        let entry = try Self.entry(for: MatchOptions.standard.dictionaryID)
        self.dictionaryID = entry.id
        self.dictionaryName = entry.name
        self.dictionaryHash = entry.hash
    }

    /// Switches to the word list `id` names.
    ///
    /// Throws ``MatchOptionsFormError/unknownDictionary(_:)`` and leaves the
    /// selection untouched if no such list ships — substituting one would leave
    /// two devices playing different words under one agreed id.
    public mutating func selectDictionary(_ id: String) throws {
        let wanted = Self.normalized(id)
        guard wanted != dictionaryID else { return }
        let entry = try Self.entry(for: wanted)
        dictionaryID = entry.id
        dictionaryName = entry.name
        dictionaryHash = entry.hash
    }

    /// What the host has chosen, ready to travel on `.start`.
    public var options: MatchOptions {
        MatchOptions(
            minimumWordLength: minimumWordLength,
            swapEnabled: swapEnabled,
            dictionaryID: dictionaryID,
            dictionaryHash: dictionaryHash
        )
    }

    // MARK: - Lookup

    private static func entry(for id: String) throws -> DictionaryEntry {
        guard let entry = try DictionaryCatalogue.entry(for: normalized(id)) else {
            throw MatchOptionsFormError.unknownDictionary(id)
        }
        return entry
    }

    /// The id in the exact form ``MatchOptions/validated`` would store it, so
    /// the id looked up and the id sent are the same string.
    private static func normalized(_ id: String) -> String {
        MatchOptions(
            minimumWordLength: MatchOptions.lengthRange.lowerBound,
            swapEnabled: true,
            dictionaryID: id,
            dictionaryHash: ""
        ).validated.dictionaryID
    }
}
