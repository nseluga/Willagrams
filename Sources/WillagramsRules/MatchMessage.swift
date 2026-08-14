import Foundation

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
    case start(seed: UInt64, startingHandSize: Int, countdownSeconds: Int)

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
    case win(player: PlayerID, placements: [Placement], tiles: [Tile])

    case resign(player: PlayerID)

    /// Host refusing a request.
    case rejected(reason: RejectionReason)
}
