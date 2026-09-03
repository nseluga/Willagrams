//
//  FakeBackend.swift
//  Willagrams
//
//  An in-memory `BackendClient`. Not `protected:` — the `online` lane may
//  deepen it as the real client teaches it what else to model.
//
//  `#if DEBUG` for the same reason `FakeTransport` is: it must never be
//  reachable in a shipped build, where a silent in-memory backend would look
//  like a working one that has simply lost every friend you ever added.
//

#if DEBUG

import Foundation
import WillagramsRules

/// A `BackendClient` that keeps everything in dictionaries.
///
/// An actor, so the `account` and `friends` lanes exercise the same
/// serialization the real client has, and a test that races two calls behaves
/// the same way against both.
public actor FakeBackend: BackendClient {

    private var signedInUser: UUID?
    private var profiles: [UUID: Profile] = [:]
    private var friendships: [Friendship] = []
    private var matches: [UUID: MatchRecord] = [:]
    private var memberships: [UUID: [MatchPlayerRow]] = [:]

    /// Every date this fake stamps. Fixed rather than `Date()`, so a test can
    /// assert on a timestamp without tolerating clock drift.
    private let now: Date

    /// Deterministic codes, so a test can predict the next one.
    private var codeCounter = 0

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.now = now
    }

    // MARK: Session

    public var currentUserID: UUID? { signedInUser }

    /// Signs a user in, deriving a stable id from the token so the same token
    /// is the same person across calls. Creates the profile on first sight.
    public func signInWithApple(idToken: String, nonce: String) async throws -> Profile {
        guard !idToken.isEmpty, !nonce.isEmpty else { throw BackendError.notAuthenticated }

        let id = Self.stableID(for: idToken)
        signedInUser = id

        if let existing = profiles[id] { return existing }

        let profile = Profile(
            id: id,
            displayName: "Player \(profiles.count + 1)",
            friendCode: nextCode(length: 8),
            createdAt: now
        )
        profiles[id] = profile
        return profile
    }

    public func signOut() async throws {
        signedInUser = nil
    }

    // MARK: Profiles

    public func profile(id: UUID) async throws -> Profile {
        guard let profile = profiles[id] else { throw BackendError.notFound }
        return profile
    }

    public func profile(friendCode: String) async throws -> Profile? {
        profiles.values.first { $0.friendCode == friendCode }
    }

    public func updateDisplayName(_ name: String) async throws -> Profile {
        let me = try requireUser()
        guard (1...24).contains(name.count) else { throw BackendError.permissionDenied }
        guard var profile = profiles[me] else { throw BackendError.notFound }
        profile.displayName = name
        profiles[me] = profile
        return profile
    }

    /// Seeds a profile that did not sign in — the other end of a friendship a
    /// test needs to exist.
    public func seedProfile(_ profile: Profile) {
        profiles[profile.id] = profile
    }

    // MARK: Friendships

    public func friendships() async throws -> [Friendship] {
        let me = try requireUser()
        return friendships.filter { $0.requesterID == me || $0.addresseeID == me }
    }

    public func requestFriend(addresseeID: UUID) async throws -> Friendship {
        let me = try requireUser()
        guard addresseeID != me else { throw BackendError.permissionDenied }
        guard profiles[addresseeID] != nil else { throw BackendError.notFound }

        // One row per unordered pair, matching `friendships_pair_idx`.
        if let existing = existingFriendship(me, addresseeID) {
            if existing.status == .blocked { throw BackendError.blocked }
            throw BackendError.alreadyExists
        }

        let friendship = Friendship(
            requesterID: me,
            addresseeID: addresseeID,
            status: .pending,
            createdAt: now
        )
        friendships.append(friendship)
        return friendship
    }

    public func respondToFriendRequest(requesterID: UUID, accept: Bool) async throws -> Friendship {
        let me = try requireUser()
        guard let index = friendships.firstIndex(where: {
            $0.requesterID == requesterID && $0.addresseeID == me
        }) else { throw BackendError.notFound }

        guard friendships[index].status == .pending else { throw BackendError.alreadyExists }

        // status and respondedAt move together, matching
        // `friendships_responded_iff_answered`.
        friendships[index].status = accept ? .accepted : .blocked
        friendships[index].respondedAt = now
        return friendships[index]
    }

    public func block(_ playerID: UUID) async throws -> Friendship {
        let me = try requireUser()
        guard playerID != me else { throw BackendError.permissionDenied }

        if let index = friendships.firstIndex(where: {
            ($0.requesterID == me && $0.addresseeID == playerID)
                || ($0.requesterID == playerID && $0.addresseeID == me)
        }) {
            friendships[index].status = .blocked
            friendships[index].respondedAt = now
            return friendships[index]
        }

        let friendship = Friendship(
            requesterID: me,
            addresseeID: playerID,
            status: .blocked,
            createdAt: now,
            respondedAt: now
        )
        friendships.append(friendship)
        return friendship
    }

    // MARK: Matches

    public func createMatch(options: MatchOptions, seed: Int64) async throws -> MatchRecord {
        let me = try requireUser()
        guard seed >= 0 else { throw BackendError.permissionDenied }

        let match = MatchRecord(
            id: UUID(),
            hostID: me,
            inviteCode: nextCode(length: 6),
            wireVersion: WireFormat.current,
            seed: seed,
            options: options.validated,
            status: .lobby,
            createdAt: now
        )
        matches[match.id] = match
        memberships[match.id] = [MatchPlayerRow(matchID: match.id, playerID: me, joinedAt: now)]
        return match
    }

    public func joinMatch(inviteCode: String) async throws -> MatchRecord {
        let me = try requireUser()
        guard let match = matches.values.first(where: { $0.inviteCode == inviteCode }) else {
            throw BackendError.notFound
        }
        guard match.status == .lobby else { throw BackendError.permissionDenied }

        var rows = memberships[match.id] ?? []
        if rows.contains(where: { $0.playerID == me }) { return match }
        guard rows.count < MatchLimits.players.upperBound else { throw BackendError.matchFull }

        rows.append(MatchPlayerRow(matchID: match.id, playerID: me, joinedAt: now))
        memberships[match.id] = rows
        return match
    }

    /// The row as this fake holds it, with no membership or status gate.
    ///
    /// A read a test needs and the protocol has no method for: "the `matches`
    /// row still reads `lobby`" cannot be asserted through `joinMatch`, which
    /// refuses on exactly that status and so cannot tell the two apart.
    public func matchRecord(_ id: UUID) -> MatchRecord? { matches[id] }

    public func players(inMatch matchID: UUID) async throws -> [MatchPlayerRow] {
        guard let rows = memberships[matchID] else { throw BackendError.notFound }
        return rows
    }

    /// What ``transport(for:as:)`` hands back, when a caller wants to choose.
    ///
    /// The stock endpoint below throws its peer away, so nothing a test does to
    /// the far end is observable and no send can be counted. A caller that needs
    /// either — the `online` façade's lobby and its "a refused start sends
    /// nothing" rule — supplies its own endpoint here.
    private var transportFactory: (@Sendable (MatchRecord, PlayerID) -> any MatchTransport)?

    public func setTransportFactory(
        _ factory: @escaping @Sendable (MatchRecord, PlayerID) -> any MatchTransport
    ) {
        transportFactory = factory
    }

    public func transport(
        for match: MatchRecord,
        as player: PlayerID
    ) async throws -> any MatchTransport {
        guard matches[match.id] != nil else { throw BackendError.notFound }
        if let transportFactory { return transportFactory(match, player) }
        // A live endpoint with a synthetic peer on the other side. Enough for
        // `account` and `friends`, which never send a MatchMessage; `online`
        // replaces this with a real channel, and the match lane's own tests
        // drive `FakeTransport.pair` directly.
        return FakeTransport.pair(player, PlayerID(rawValue: "fake-peer")).first
    }

    // MARK: Helpers

    private func requireUser() throws -> UUID {
        guard let user = signedInUser else { throw BackendError.notAuthenticated }
        return user
    }

    private func existingFriendship(_ a: UUID, _ b: UUID) -> Friendship? {
        friendships.first {
            ($0.requesterID == a && $0.addresseeID == b)
                || ($0.requesterID == b && $0.addresseeID == a)
        }
    }

    private func nextCode(length: Int) -> String {
        codeCounter += 1
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var value = codeCounter
        var characters: [Character] = []
        for _ in 0..<length {
            characters.append(alphabet[value % alphabet.count])
            value /= alphabet.count
        }
        return String(characters.reversed())
    }

    /// A UUID derived from the token, so one token is always one person.
    private static func stableID(for token: String) -> UUID {
        var bytes = Array(token.utf8)
        bytes = Array((bytes + Array(repeating: 0, count: 16)).prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

#endif
