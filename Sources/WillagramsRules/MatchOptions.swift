import CryptoKit
import Foundation

/// The rule variants a host chooses before the match opens.
///
/// Travels on `.start`, so both devices enforce the same rules. Each device
/// validates its own board locally — two devices disagreeing about the minimum
/// word length or the word list disagree about what a legal board is, and the
/// symptom is one player's word rejected on the other's screen mid-match,
/// looking like a bug rather than a configuration mismatch.
///
/// The word list travels as an identity plus a content hash, never as a list:
/// ENABLE is 172k words and 1.7 MB. The id says which list; the hash catches a
/// build skew where two devices resolve the same id to different content.
public struct MatchOptions: Codable, Sendable, Equatable {
    /// Shortest word the dictionary will accept.
    public var minimumWordLength: Int

    /// When false, the host refuses every swap request.
    public var swapEnabled: Bool

    /// Which word list is in force, e.g. `"standard"`.
    public var dictionaryID: String

    /// Content hash of that list, per ``canonicalWordListHash(_:)``.
    public var dictionaryHash: String

    public init(
        minimumWordLength: Int,
        swapEnabled: Bool,
        dictionaryID: String,
        dictionaryHash: String
    ) {
        self.minimumWordLength = minimumWordLength
        self.swapEnabled = swapEnabled
        self.dictionaryID = dictionaryID
        self.dictionaryHash = dictionaryHash
    }

    // MARK: - Bounds

    /// Two is the floor `BoardAnalysis` already enforces: a run of one tile is
    /// not a word. Fifteen is past the longest word any board fits.
    public static let lengthRange = 2...15

    /// Long enough for any identifier or a SHA-256 hex digest, short enough
    /// that a peer cannot hand us an unbounded string.
    public static let identifierLimit = 64

    /// Exactly today's shipped behavior: two-letter words legal, swap on,
    /// bundled ENABLE.
    public static let standard = MatchOptions(
        minimumWordLength: 2,
        swapEnabled: true,
        dictionaryID: standardDictionaryID,
        dictionaryHash: standardDictionaryHash
    )

    public static let standardDictionaryID = "standard"

    /// The bundled list's hash, pinned rather than computed.
    ///
    /// Computing it costs a sort over 172k strings, and the file cannot change
    /// at runtime — so the constant is the fast path and
    /// `MatchOptionsTests.standardHashMatchesTheBundledList` is what keeps it
    /// honest. Change `dictionary.txt` and that test fails loudly, which is the
    /// point: a silently stale hash would refuse every match.
    public static let standardDictionaryHash =
        "212ad761133bbe21fa93aefb59e03a5d012bc2f858816fd178b57fcd047832e1"

    // MARK: - Trust boundary

    /// A copy with every field forced inside its bounds.
    ///
    /// Options arrive from another device. Nothing here traps: an out-of-range
    /// minimum clamps, an oversized or non-hex identifier truncates and filters,
    /// matching the clamp-don't-trap style `MatchSession.applyStart` already
    /// uses for `startingHandSize` and `countdownSeconds`.
    public var validated: MatchOptions {
        MatchOptions(
            minimumWordLength: min(
                max(Self.lengthRange.lowerBound, minimumWordLength),
                Self.lengthRange.upperBound
            ),
            swapEnabled: swapEnabled,
            dictionaryID: String(
                dictionaryID.lowercased()
                    .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                    .prefix(Self.identifierLimit)
            ),
            dictionaryHash: String(
                dictionaryHash.lowercased()
                    .filter { $0.isHexDigit }
                    .prefix(Self.identifierLimit)
            )
        )
    }
}

/// A word list that also refuses anything shorter than `minimum`.
///
/// A decorator rather than a change to validation: `BoardAnalysis.words()`
/// returns every run of two or more and defers validity to the injected list,
/// so rejecting a short word here turns it into an *invalid word* — which
/// blocks the Draw gate and shows the player why — rather than a run that is
/// silently ignored.
public struct MinimumLengthWordList: WordList {
    private let base: any WordList
    private let minimum: Int

    public init(base: any WordList, minimum: Int) {
        self.base = base
        self.minimum = minimum
    }

    public func contains(_ word: String) -> Bool {
        word.count >= minimum && base.contains(word)
    }
}

/// A stable hash of a word set, identical on both devices for identical content.
///
/// Normalized and ordered before hashing — lowercased, deduplicated, sorted,
/// newline-joined — because `Set` iteration order differs between processes and
/// a hash that depended on it would refuse every match.
public func canonicalWordListHash(_ words: some Sequence<String>) -> String {
    let canonical = Set(words.map { $0.lowercased() })
        .sorted()
        .joined(separator: "\n")
    return SHA256.hash(data: Data(canonical.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}
