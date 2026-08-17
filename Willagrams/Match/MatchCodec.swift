import Foundation
import WillagramsRules

/// Errors `MatchCodec.decode` can throw.
///
/// `data` in `decode` may be anything a peer chooses to send — every failure
/// path here returns one of these instead of trapping.
public enum MatchCodecError: Error, Equatable, Sendable {
    /// A structurally valid `.start` whose wire version this build doesn't
    /// speak. Refused, not decoded.
    case unsupportedVersion(received: Int, expected: Int)

    /// The bytes don't decode as `MatchMessage` at all: truncated, wrong
    /// shape, or an unknown case.
    ///
    /// Carries the underlying `DecodingError`'s description rather than the
    /// error itself: `DecodingError` is not `Sendable`, and this error travels
    /// from the transport's async streams into the session, which is observed
    /// on the main actor. A string is as much as a log line ever wanted.
    case malformedPayload(description: String)
}

/// Encodes and decodes `MatchMessage` for the wire.
///
/// `decode(_:)` is the only entry point callers should use for bytes that
/// arrived from a peer: it is where the version gate lives, so a caller who
/// goes through it can never come away with a `.start` carrying a version
/// this build doesn't know — a mismatch throws instead of returning a value.
public enum MatchCodec {
    public static func encode(_ message: MatchMessage) throws -> Data {
        try JSONEncoder().encode(message)
    }

    public static func decode(_ data: Data) throws(MatchCodecError) -> MatchMessage {
        let message: MatchMessage
        do {
            message = try JSONDecoder().decode(MatchMessage.self, from: data)
        } catch {
            throw .malformedPayload(description: String(describing: error))
        }

        if case let .start(version, _, _, _, _) = message, version != WireFormat.current {
            throw .unsupportedVersion(received: version, expected: WireFormat.current)
        }

        return message
    }
}
