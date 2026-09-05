import Foundation
import WillagramsRules
@testable import Match

/// A `BackendClient` that counts what it was asked to do and forwards the rest
/// to a real `FakeBackend`.
///
/// It exists for the negative assertions: "refused before any call is made" is
/// only proven by driving `ProfileModel.save()` and finding the count still
/// zero. Reading the stored name back instead would pass just as well against a
/// model that called the backend and had the *backend* refuse — which is the
/// bug this item is meant to make impossible.
actor RecordingBackend: BackendClient {

    let inner: FakeBackend

    private(set) var updateDisplayNameCalls: [String] = []

    init(inner: FakeBackend) {
        self.inner = inner
    }

    var currentUserID: UUID? {
        get async { await inner.currentUserID }
    }

    func signInWithApple(idToken: String, nonce: String) async throws -> Profile {
        try await inner.signInWithApple(idToken: idToken, nonce: nonce)
    }

    func signOut() async throws { try await inner.signOut() }

    func profile(id: UUID) async throws -> Profile { try await inner.profile(id: id) }

    func profile(friendCode: String) async throws -> Profile? {
        try await inner.profile(friendCode: friendCode)
    }

    func updateDisplayName(_ name: String) async throws -> Profile {
        updateDisplayNameCalls.append(name)
        return try await inner.updateDisplayName(name)
    }

    func friendships() async throws -> [Friendship] { try await inner.friendships() }

    func requestFriend(addresseeID: UUID) async throws -> Friendship {
        try await inner.requestFriend(addresseeID: addresseeID)
    }

    func respondToFriendRequest(requesterID: UUID, accept: Bool) async throws -> Friendship {
        try await inner.respondToFriendRequest(requesterID: requesterID, accept: accept)
    }

    func block(_ playerID: UUID) async throws -> Friendship { try await inner.block(playerID) }

    func createMatch(options: MatchOptions, seed: Int64) async throws -> MatchRecord {
        try await inner.createMatch(options: options, seed: seed)
    }

    func joinMatch(inviteCode: String) async throws -> MatchRecord {
        try await inner.joinMatch(inviteCode: inviteCode)
    }

    func players(inMatch matchID: UUID) async throws -> [MatchPlayerRow] {
        try await inner.players(inMatch: matchID)
    }

    func transport(for match: MatchRecord, as player: PlayerID) async throws -> any MatchTransport {
        try await inner.transport(for: match, as: player)
    }
}
