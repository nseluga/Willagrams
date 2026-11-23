import Foundation

/// Decides whether this build is older than the App Store's, which is when
/// online play asks for an update first. Every doubt answers "not blocked":
/// a network problem, a bad answer, or an App Review build that is ahead of
/// the store must never lock anyone out.
public enum UpdateGate {

    /// One request: it carries only the bundle ID.
    public static let lookupURL = URL(string: "https://itunes.apple.com/lookup?bundleId=com.willagrams.Willagrams")!

    /// Returns the lookup's body. Injected so tests never touch the network.
    public typealias Lookup = @Sendable () async throws -> Data

    public static let liveLookup: Lookup = {
        try await URLSession.shared.data(from: lookupURL).0
    }

    /// Whether the store's version is newer than `running`.
    public static func isBlocked(running: String, lookup: Lookup) async -> Bool {
        guard let data = try? await lookup(), let store = storeVersion(in: data) else { return false }
        return isNewer(store, than: running)
    }

    /// `results[0].version` of the lookup answer, or nil when it is not there.
    static func storeVersion(in data: Data) -> String? {
        struct Answer: Decodable {
            struct Result: Decodable { let version: String }
            let results: [Result]
        }
        return (try? JSONDecoder().decode(Answer.self, from: data))?.results.first?.version
    }

    /// Numeric compare, part by part, so "1.10" is newer than "1.9" and "1.0"
    /// equals "1.0.0". A part that is not a number makes the answer false.
    static func isNewer(_ store: String, than running: String) -> Bool {
        let a = store.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        let b = running.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !a.contains(nil), !b.contains(nil) else { return false }
        let x = a.compactMap { $0 }, y = b.compactMap { $0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
