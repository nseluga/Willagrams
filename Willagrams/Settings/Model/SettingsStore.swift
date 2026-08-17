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
        return stored.validated
    }

    /// Writes `options` to the suite, replacing whatever was there.
    public func save(_ options: MatchOptions) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
