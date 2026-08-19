//
//  BackendContracts.swift
//  Willagrams
//
//  The backend seam, pinned by `/foundation`. Same shape the match layer got:
//  a protocol plus a fake, so `account` and `friends` build and test with no
//  Supabase project, exactly as `match` built against `FakeTransport`.
//
//  This file must never import Supabase. The SDK lives behind the protocol, in
//  the `online` lane's concrete client. Keeping it out here is what lets the
//  `account`, `friends` and `online` test packages compile at engine speed.
//
//  `protected:` in MAP.md — three lanes read these shapes.
//

import Foundation
import WillagramsRules

// MARK: - Coding

/// How every row above decodes. Pinned here rather than per call site: two
/// lanes building their own decoder is how one of them silently gets dates
/// wrong.
public enum BackendCoding {

    /// PostgREST returns `timestamptz` as ISO 8601, and whether it carries
    /// fractional seconds depends on the stored value — `now()` usually does,
    /// a whole-second value does not. `.iso8601` alone rejects the fractional
    /// form, so both are tried.
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { source in
            let text = try String(from: source)
            if let date = try? fractional.parse(text) { return date }
            if let date = try? plain.parse(text) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: source.codingPath,
                      debugDescription: "not an ISO 8601 timestamp: \(text)")
            )
        }
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, target in
            var container = target.singleValueContainer()
            try container.encode(fractional.format(date))
        }
        return encoder
    }()

    /// Value types, not `ISO8601DateFormatter`: the formatter is a class with
    /// mutable options, so a shared instance is not `Sendable` and a per-call
    /// one allocates on every row.
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()
}

// MARK: - Rows

/// One signed-in player. Mirrors `public.profiles`.
///
/// Readable by any signed-in player by design — a friend code is looked up by
/// someone who is not yet your friend. Nothing private is on this row.
public struct Profile: Codable, Sendable, Equatable, Identifiable {

    /// The auth user id. This is what `PlayerID.rawValue` carries on the wire.
    public let id: UUID
    public var displayName: String

    /// Eight uppercase characters, handed to a friend over any messenger.
    /// Assigned once at sign-up and never changed, so a code already shared
    /// keeps working.
    public let friendCode: String
    public let createdAt: Date

    public var matchesPlayed: Int
    public var matchesWon: Int
    public var tilesPlaced: Int

    /// Nil until the player wins once.
    public var fastestWinSeconds: Int?

    public enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case friendCode = "friend_code"
        case createdAt = "created_at"
        case matchesPlayed = "matches_played"
        case matchesWon = "matches_won"
        case tilesPlaced = "tiles_placed"
        case fastestWinSeconds = "fastest_win_seconds"
    }

    public init(
        id: UUID,
        displayName: String,
        friendCode: String,
        createdAt: Date,
        matchesPlayed: Int = 0,
        matchesWon: Int = 0,
        tilesPlaced: Int = 0,
        fastestWinSeconds: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.friendCode = friendCode
        self.createdAt = createdAt
        self.matchesPlayed = matchesPlayed
        self.matchesWon = matchesWon
        self.tilesPlaced = tilesPlaced
        self.fastestWinSeconds = fastestWinSeconds
    }

    /// This player as the wire knows them.
    public var playerID: PlayerID { PlayerID(rawValue: id.uuidString) }
}

public enum FriendshipStatus: String, Codable, Sendable, Equatable {
    case pending
    case accepted
    case blocked
}

/// One friendship, in whichever direction it was asked. Mirrors
/// `public.friendships`.
///
/// At most one row exists per unordered pair, so a request from the other side
/// updates this row rather than adding a second one.
public struct Friendship: Codable, Sendable, Equatable {

    public let requesterID: UUID
    public let addresseeID: UUID
    public var status: FriendshipStatus
    public let createdAt: Date

    /// Nil exactly while `status == .pending`. The database enforces the
    /// biconditional, so the two can never disagree.
    public var respondedAt: Date?

    public enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
        case addresseeID = "addressee_id"
        case status
        case createdAt = "created_at"
        case respondedAt = "responded_at"
    }

    public init(
        requesterID: UUID,
        addresseeID: UUID,
        status: FriendshipStatus,
        createdAt: Date,
        respondedAt: Date? = nil
    ) {
        self.requesterID = requesterID
        self.addresseeID = addresseeID
        self.status = status
        self.createdAt = createdAt
        self.respondedAt = respondedAt
    }

    /// The other end of this friendship, seen from `viewer`.
    ///
    /// Nil when `viewer` is neither end — a caller filtering someone else's
    /// row, which the policies should already have prevented.
    public func other(than viewer: UUID) -> UUID? {
        switch viewer {
        case requesterID: return addresseeID
        case addresseeID: return requesterID
        default: return nil
        }
    }
}

public enum MatchRecordStatus: String, Codable, Sendable, Equatable {
    case lobby
    case playing
    case finished
    case abandoned
}

/// One match, lobby through result. Mirrors `public.matches`.
public struct MatchRecord: Codable, Sendable, Equatable, Identifiable {

    public let id: UUID
    public let hostID: UUID

    /// Six uppercase characters. What a friend types to join.
    public let inviteCode: String

    /// `WireFormat.current` when the match was created. A client that does not
    /// speak it refuses the match rather than decoding garbage.
    public let wireVersion: Int

    /// Drawn in `0...Int64.max`: Postgres `bigint` is signed. Nothing depends
    /// on the high bit.
    public let seed: Int64

    public let options: MatchOptions
    public var status: MatchRecordStatus
    public let createdAt: Date

    /// Non-nil exactly when `status` is `.playing` or `.finished`.
    public var startedAt: Date?
    /// Non-nil exactly when `status` is `.finished`.
    public var finishedAt: Date?
    /// Non-nil only when `status` is `.finished`.
    public var winnerID: UUID?

    public enum CodingKeys: String, CodingKey {
        case id
        case hostID = "host_id"
        case inviteCode = "invite_code"
        case wireVersion = "wire_version"
        case seed
        case options
        case status
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case winnerID = "winner_id"
    }

    public init(
        id: UUID,
        hostID: UUID,
        inviteCode: String,
        wireVersion: Int,
        seed: Int64,
        options: MatchOptions,
        status: MatchRecordStatus,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        winnerID: UUID? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.inviteCode = inviteCode
        self.wireVersion = wireVersion
        self.seed = seed
        self.options = options
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.winnerID = winnerID
    }

    /// The seed as the engine wants it. Always non-negative, so this is total.
    public var poolSeed: UInt64 { UInt64(seed) }
}

/// One player's membership of one match. Mirrors `public.match_players`.
public struct MatchPlayerRow: Codable, Sendable, Equatable {

    public let matchID: UUID
    public let playerID: UUID
    public let joinedAt: Date

    public enum CodingKeys: String, CodingKey {
        case matchID = "match_id"
        case playerID = "player_id"
        case joinedAt = "joined_at"
    }

    public init(matchID: UUID, playerID: UUID, joinedAt: Date) {
        self.matchID = matchID
        self.playerID = playerID
        self.joinedAt = joinedAt
    }
}

// MARK: - Errors

/// Everything the backend can refuse to do, in terms a screen can act on.
///
/// Deliberately closed and transport-free: no HTTP status, no Postgres code.
/// A screen showing "that friend code does not exist" should not have to know
/// what a 406 is.
public enum BackendError: Error, Sendable, Equatable {
    /// No signed-in user. The caller should route to Sign in with Apple.
    case notAuthenticated
    /// The row asked for is not there — a bad friend code, a dead invite.
    case notFound
    /// A friendship or a profile that already exists.
    case alreadyExists
    /// One end of this pair has blocked the other.
    case blocked
    /// The match already holds `MatchLimits.players.upperBound` players.
    case matchFull
    /// The row exists but this user may not touch it. An RLS refusal.
    case permissionDenied
    /// The request never reached the server.
    case offline
}

// MARK: - The seam

/// Everything the app asks of the backend.
///
/// One method per screen action, so a screen never composes two calls to do one
/// thing. The `online` lane implements this over Supabase; `FakeBackend`
/// implements it in memory so `account` and `friends` need neither a project
/// nor a network.
public protocol BackendClient: Sendable {

    /// The signed-in user, or nil. Async because a concrete client may still be
    /// restoring a persisted session.
    var currentUserID: UUID? { get async }

    /// Exchanges an Apple identity token for a session, creating the profile on
    /// first sign-in. `nonce` is the raw nonce whose SHA256 was handed to
    /// `ASAuthorizationAppleIDRequest`.
    func signInWithApple(idToken: String, nonce: String) async throws -> Profile

    func signOut() async throws

    func profile(id: UUID) async throws -> Profile

    /// Looks a stranger up by the code they gave you. Nil rather than throwing:
    /// a code that matches nobody is a normal outcome of typing, not an error.
    func profile(friendCode: String) async throws -> Profile?

    func updateDisplayName(_ name: String) async throws -> Profile

    /// Every friendship touching the current user, in any status.
    func friendships() async throws -> [Friendship]

    func requestFriend(addresseeID: UUID) async throws -> Friendship

    func respondToFriendRequest(requesterID: UUID, accept: Bool) async throws -> Friendship

    /// Blocks a player, whether or not a friendship already exists.
    func block(_ playerID: UUID) async throws -> Friendship

    /// Creates a lobby with this device as host, and joins it.
    func createMatch(options: MatchOptions, seed: Int64) async throws -> MatchRecord

    func joinMatch(inviteCode: String) async throws -> MatchRecord

    func players(inMatch matchID: UUID) async throws -> [MatchPlayerRow]

    /// The realtime channel for `match`, as a `MatchTransport`.
    ///
    /// This is the whole point of the seam: everything above it — `MatchSession`,
    /// `HostPool`, the bot — already speaks `MatchTransport` and does not learn
    /// that a network exists.
    func transport(for match: MatchRecord, as player: PlayerID) async throws -> any MatchTransport
}
