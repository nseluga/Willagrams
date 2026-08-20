import Foundation

/// The wire format this build speaks. Bump only when `MatchMessage` changes
/// shape, and add a golden fixture for the new version in the same commit.
public enum WireFormat {
    public static let current = 3
}

/// How many players one match may hold.
///
/// The lower bound is the game: one player has nobody to race. The upper bound
/// is the pool — six players at the largest sensible hand still leave tiles to
/// draw from 144, and a seventh does not.
public enum MatchLimits {
    public static let players = 2...6

    /// Tiles in a standard pool. `validatedStart` checks the opening deal
    /// against it, so a roster that cannot be dealt never starts a match.
    public static let poolSize = 144
}

/// Why the host turned down a request.
public enum RejectionReason: Codable, Sendable, Equatable {
    case poolEmpty
    case notEnoughTilesToSwap
    case notYourTurn
    case unknownPlayer

    /// The host opened the match with `swapEnabled: false`.
    ///
    /// Distinct from `notEnoughTilesToSwap`: that one is about the pool and may
    /// succeed later, this one holds for the whole match.
    case swapDisabled
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
    /// `options` carries the host's rule variants. Both devices validate their
    /// own boards, so the rules have to travel with the start or the two
    /// disagree about what a legal board is.
    ///
    /// `roster` is every player in the match, sorted ascending by `rawValue`.
    /// It is the only place the player set appears — the host is `roster[0]`,
    /// computed identically on every device, so there is still no negotiation
    /// message and no second source for the count.
    case start(
        version: Int,
        seed: UInt64,
        startingHandSize: Int,
        countdownSeconds: Int,
        options: MatchOptions,
        roster: [PlayerID]
    )

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

public extension MatchMessage {

    /// The fields of a `start` that has been checked, or nil if it has not.
    struct ValidatedStart: Sendable, Equatable {
        public let seed: UInt64
        public let startingHandSize: Int
        public let countdownSeconds: Int
        public let options: MatchOptions
        public let roster: [PlayerID]

        /// The player who runs the pool. `roster` is sorted, so this is the
        /// lowest `rawValue` and every device computes the same answer.
        public var host: PlayerID { roster[0] }
    }

    /// Checks a `start` that arrived from a peer.
    ///
    /// Returns nil for anything a well-behaved host would never send. This is
    /// the same clamp-at-the-boundary rule `MatchOptions.validated` follows,
    /// and for the same reason: every field here crossed a network.
    ///
    /// Refused, and why each one matters:
    ///
    /// - **Not this wire version.** Two builds that disagree about the shape
    ///   decode each other into nonsense rather than failing.
    /// - **An unsorted roster, or one holding a duplicate.** Both make devices
    ///   disagree about who `roster[0]` is, so two hosts run a pool or none
    ///   does — and the symptom is a match that never deals.
    /// - **A roster outside `MatchLimits.players`.**
    /// - **A roster this device is not in.** Nothing downstream has a sensible
    ///   answer for "which player am I".
    /// - **An opening deal the pool cannot cover.** The last player would
    ///   receive a short hand and the match would start unfair, with every
    ///   individual grant well-formed.
    /// - **A non-positive countdown or hand size.**
    func validatedStart(for local: PlayerID) -> ValidatedStart? {
        guard case let .start(version, seed, handSize, countdown, options, roster) = self,
              version == WireFormat.current,
              MatchLimits.players.contains(roster.count),
              handSize >= 0,
              countdown >= 0,
              roster.contains(local),
              Set(roster).count == roster.count,
              roster == roster.sorted(by: { $0.rawValue < $1.rawValue }),
              handSize <= MatchLimits.poolSize / roster.count
        else { return nil }

        return ValidatedStart(
            seed: seed,
            startingHandSize: handSize,
            countdownSeconds: countdown,
            options: options.validated,
            roster: roster
        )
    }
}
