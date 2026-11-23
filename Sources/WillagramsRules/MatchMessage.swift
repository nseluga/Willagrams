import Foundation

/// The wire format this build speaks. Bump only when `MatchMessage` changes
/// shape, and add a golden fixture for the new version in the same commit.
public enum WireFormat {
    public static let current = 5
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
/// **Renaming a case or changing what it carries is a wire break. Adding an
/// optional case is not.** Each case encodes under its own name, so a new case
/// leaves every existing payload exactly as it was. A build that has never
/// heard of a case fails to decode that one message and drops it, and the
/// match carries on. So a case may be added without bumping ``WireFormat``
/// only when the match stays correct with the other side ignoring it, which
/// rules out anything that moves a tile or decides a winner. The optional cases
/// sit under "Optional kinds" at the foot of this enum. Any change to an existing
/// case still needs a bump: two builds that disagree there fail to decode, and
/// the symptom is a match that silently stops rather than an error anyone sees.
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

    /// Host's answer to THIS player's own draw request, and the opening deal.
    /// Goes straight to the rack.
    ///
    /// A draw gives every player a tile, so a device receives tiles for two
    /// different reasons; ``obligation`` is the other one. They were one case,
    /// and the receiver told them apart by guessing from its own count of
    /// unanswered requests. The guess is wrong whenever the two cross on the
    /// wire — both players drawing at once, which is most of a late match — and
    /// the cost of being wrong is a spent credit, a tile that silently skips the
    /// obligation, and a Draw gate that reopens while a request is still in
    /// flight. The host has always known which is which. Now it says so.
    case grant(player: PlayerID, tiles: [Tile])

    /// A tile this player owes because somebody ELSE drew. Held behind the
    /// obligation until they press Draw, which is what reopens their board.
    case obligation(player: PlayerID, tiles: [Tile])

    /// "Take this back, give me three."
    case swapRequest(player: PlayerID, returning: Tile)

    case swapGrant(player: PlayerID, tiles: [Tile], returned: Tile)

    /// No tiles left. The next completed board ends the match.
    ///
    /// Reaches every player — both boards need the latch — but names who asked,
    /// for the same reason ``grant`` does: it is an answer to exactly one
    /// request, and only that player may spend a credit on it.
    case poolExhausted(requester: PlayerID)

    /// A win, with the board behind it so the end screen can show both.
    ///
    /// `placements` is `Board.placementList` — every tile the winner played,
    /// letters included. Tiles still in hand are not sent: a winning board has
    /// none, and unplaced scratch tiles are nobody else's business.
    case win(player: PlayerID, placements: [Placement])

    case resign(player: PlayerID)

    /// Host refusing a request.
    case rejected(reason: RejectionReason)

    /// Host's pool size after it moved, so a guest's bag can show a number.
    ///
    /// Informational only: the host's pool stays the one authority, and a
    /// guest never draws, swaps or ends a match on this value. Off the wire it
    /// is untrusted — a receiver drops a negative count or one above
    /// ``MatchLimits/poolSize`` rather than showing it.
    case poolCount(remaining: Int)

    // MARK: Optional kinds
    //
    // Added after wire v5 with no version bump. A v5 build that predates them
    // drops each one on arrival, so nothing here may be needed for the match to
    // stay correct. Each states a fact rather than flipping a switch, so a
    // repeat, or a re-send after a reconnect, changes nothing.

    /// What one player wants: the match paused (`wanted: true`) or running.
    ///
    /// From any player, to everyone. It is a wish, never the state: a match
    /// pauses and resumes only on ``pauseState``.
    case pauseVote(player: PlayerID, wanted: Bool)

    /// Whether the match is paused. Sent by the host only.
    ///
    /// The host decides this for the same reason it runs the pool: one
    /// authority, so two devices cannot end up disagreeing. A message does not
    /// carry its sender, so the one check a receiver can make is the host's:
    /// the host drops any `pauseState` it receives, as it drops a `grant`.
    ///
    /// The host sends `paused: true` only once every player in the roster has a
    /// `pauseVote(wanted: true)` on record. A build that drops these kinds never
    /// votes, so it is never paused against while it plays on.
    case pauseState(paused: Bool)

    /// A player's board as it stood when the match ended, so the other end
    /// screen can show it. Never sent while the match is still being played.
    ///
    /// `placements` is `Board.placementList`, as on ``win``, and is untrusted
    /// in the same way: the receiver rebuilds a board from it or shows none.
    case finalBoard(player: PlayerID, placements: [Placement])

    /// How long a game the player opening the match asked for: `half: true` is
    /// a pool of half the standard size. Sent just before ``start``.
    ///
    /// Only the device that runs the pool acts on it, and only before the match
    /// has started. A build that drops it deals a standard pool, and so does a
    /// match where it never arrives: the game is then longer than was asked
    /// for, and still correct, because there is one pool either way and every
    /// other device learns its size from ``poolCount``.
    ///
    /// The device that opens the match uses its own choice and ignores this
    /// kind off the wire, so a peer cannot override the opener there. The
    /// sender cannot be checked beyond that. A half pool covers a smaller
    /// opening hand: the opener offers only hands a half pool can deal, and the
    /// device that runs the pool clamps the hand to the pool it builds.
    case gameLength(half: Bool)

    /// A pause ran its whole limit, so the match is over with no winner. Sent
    /// by the host only, and believed by a guest only while it is paused.
    ///
    /// Safe to lose and safe to drop. A guest that never hears it reaches the
    /// same end a few seconds later by its own clock, started when it heard the
    /// pause. A build that drops these kinds never votes, so it is never paused
    /// against, and this is never sent to it.
    case matchVoided
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
