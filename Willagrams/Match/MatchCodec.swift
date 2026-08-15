import Foundation
import WillagramsRules

/// Errors `MatchCodec.decode` can throw.
///
/// `data` in `decode` may be anything a peer chooses to send — every failure
/// path here returns one of these instead of trapping.
public enum MatchCodecError: Error, Equatable {
    /// A structurally valid `.start` whose wire version this build doesn't
    /// speak. Refused, not decoded.
    case unsupportedVersion(received: Int, expected: Int)

    /// The bytes don't decode as `MatchMessage` at all: truncated, wrong
    /// shape, or an unknown case. The underlying `DecodingError` is kept for
    /// logging but callers aren't required to switch on it.
    case malformedPayload(underlying: any Error)

    public static func == (lhs: MatchCodecError, rhs: MatchCodecError) -> Bool {
        switch (lhs, rhs) {
        case let (.unsupportedVersion(r1, e1), .unsupportedVersion(r2, e2)):
            return r1 == r2 && e1 == e2
        case (.malformedPayload, .malformedPayload):
            return true
        default:
            return false
        }
    }
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
            throw .malformedPayload(underlying: error)
        }

        if case let .start(version, _, _, _) = message, version != WireFormat.current {
            throw .unsupportedVersion(received: version, expected: WireFormat.current)
        }

        return message
    }
}
