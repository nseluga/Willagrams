import Foundation
import WillagramsRules

/// Persists the host's chosen ``MatchOptions`` across launches.
///
/// The defaults suite is injected rather than reached for, so tests run against
/// a throwaway suite instead of the developer's real preferences.
///
/// Stored bytes are a trust boundary — the file is user-writable and survives
/// app versions — so a read that fails for any reason (absent key, wrong type,
/// truncated or malformed JSON, a field the current schema no longer accepts)
/// answers ``MatchOptions/standard`` instead of trapping, and a decode that
/// succeeds is still routed through ``MatchOptions/validated``.
public struct SettingsStore {
    private static let key = "matchOptions"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The stored options, or ``MatchOptions/standard`` if none decode.
    public func load() -> MatchOptions {
        guard
            let data = defaults.data(forKey: Self.key),
            let stored = try? JSONDecoder().decode(MatchOptions.self, from: data)
        else { return .standard }
        var options = stored.validated
        // The hash is derived from the bundled list, not a choice the host
        // made — and these bytes outlive the build that wrote them. A build
        // shipping a new list would otherwise replay the old list's hash on
        // `.start`, and `applyStart` refuses that silently on both devices.
        // The pinned constant, not `DictionaryCatalogue`: resolving through
        // the catalogue sorts 172k words on a path the lobby is on.
        if options.dictionaryID == MatchOptions.standardDictionaryID {
            options.dictionaryHash = MatchOptions.standardDictionaryHash
        }
        return options
    }

    /// Writes `options` to the suite, replacing whatever was there.
    public func save(_ options: MatchOptions) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        defaults.set(data, forKey: Self.key)
    }

    // MARK: - The starting hand
    //
    // Not part of `MatchOptions`: the wire's options describe the rules both
    // devices validate against, and the opening deal is not one of them. It is
    // still a setting a host chooses and expects to find again, so it is stored
    // beside them under its own key.

    private static let handSizeKey = "startingHandSize"

    /// What a suite that has never been written answers. Absent and zero read
    /// the same way out of `UserDefaults`, and zero is not a hand anyone chose.
    public static let defaultHandSize = 21

    /// The stored starting hand, or ``defaultHandSize``. Bounds are the
    /// caller's — the same rule ``load()`` follows by deferring to `validated`.
    public func loadHandSize() -> Int {
        let stored = defaults.integer(forKey: Self.handSizeKey)
        return stored > 0 ? stored : Self.defaultHandSize
    }

    public func saveHandSize(_ handSize: Int) {
        defaults.set(handSize, forKey: Self.handSizeKey)
    }
}
