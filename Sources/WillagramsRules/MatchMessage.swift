import Foundation

/// The wire format this build speaks. Bump only when `MatchMessage` changes
/// shape, and add a golden fixture for the new version in the same commit.
public enum WireFormat {
    public static let current = 1
}

/// Why the host turned down a request.
public enum RejectionReason: Codable, Sendable, Equatable {
    case poolEmpty
    case notEnoughTilesToSwap
    case notYourTurn
    case unknownPlayer
}

/// Everything two devices say to each other during a match.
///
/// The host owns the pool; peers ask, the host answers. Grants carry the
/// actual tiles rather than letting each device draw from its own copy, so a
/// dropped or reordered message can never leave the two bags disagreeing.
///
/// **Adding or reordering a case is a wire break.** Two app versions that
/// disagree here fail to decode, and the symptom is a match that silently
/// stops rather than an error anyone sees.
public enum MatchMessage: Codable, Sendable, Equatable {
    /// Host opens the match. The seed makes the shuffle replayable.
    ///
    /// `version` is the wire format, not the app version — bump it only when
    /// this enum changes shape, and refuse a match whose host sends a version
    /// this build does not know.
    case start(version: Int, seed: UInt64, startingHandSize: Int, countdownSeconds: Int)

    /// "I have placed everything" — a request for everyone to take one.
    case drawRequest(player: PlayerID)

    /// Host's answer to a draw: these tiles, to this player.
    case grant(player: PlayerID, tiles: [Tile])

    /// "Take this back, give me three."
    case swapRequest(player: PlayerID, returning: Tile)

    case swapGrant(player: PlayerID, tiles: [Tile], returned: Tile)

    /// No tiles left. The next completed board ends the match.
    case poolExhausted

    /// A win, with the board behind it so the end screen can show both.
    ///
    /// `placements` is `Board.placementList` — every tile the winner played,
    /// letters included. Tiles still in hand are not sent: a winning board has
    /// none, and unplaced scratch tiles are nobody else's business.
    case win(player: PlayerID, placements: [Placement])

    case resign(player: PlayerID)

    /// Host refusing a request.
    case rejected(reason: RejectionReason)
}
