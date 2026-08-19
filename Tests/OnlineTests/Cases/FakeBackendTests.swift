import Foundation
import Testing
import WillagramsRules
@testable import Online

/// `FakeBackend` is what `account` and `friends` build against, so its rules
/// are part of the contract those lanes see. Every rule asserted here is one
/// the schema also enforces — one row per unordered pair, a response that moves
/// `status` and `responded_at` together, a lobby that stops at
/// `MatchLimits.players.upperBound`. A fake that is laxer than the database
/// lets a lane ship a screen the real backend rejects.
@Suite("Fake backend")
struct FakeBackendTests {

    private static let options = MatchOptions(
        minimumWordLength: 3, swapEnabled: true, dictionaryID: "standard", dictionaryHash: "abc"
    )

    /// One token is one person. The lanes lean on this to sign a second device
    /// in as the same player.
    private static func signIn(_ backend: FakeBackend, _ token: String) async throws -> Profile {
        try await backend.signInWithApple(idToken: token, nonce: "nonce-\(token)")
    }

    @Test("Signing in twice with one token is one profile, not two")
    func signInIsStable() async throws {
        let backend = FakeBackend()
        let first = try await Self.signIn(backend, "apple-a")
        let again = try await Self.signIn(backend, "apple-a")
        #expect(first == again)
        #expect(await backend.currentUserID == first.id)

        let other = try await Self.signIn(backend, "apple-b")
        #expect(other.id != first.id)
        #expect(other.friendCode != first.friendCode)
    }

    @Test("An empty token is not a session")
    func emptyTokenFails() async {
        let backend = FakeBackend()
        await #expect(throws: BackendError.notAuthenticated) {
            try await backend.signInWithApple(idToken: "", nonce: "n")
        }
    }

    @Test("Signing out ends the session and every call needs one")
    func signOutClearsTheSession() async throws {
        let backend = FakeBackend()
        _ = try await Self.signIn(backend, "apple-a")
        try await backend.signOut()
        #expect(await backend.currentUserID == nil)
        await #expect(throws: BackendError.notAuthenticated) {
            try await backend.friendships()
        }
    }

    @Test("A friend code finds a stranger, and a bad one is nil rather than an error")
    func lookupByFriendCode() async throws {
        let backend = FakeBackend()
        let them = try await Self.signIn(backend, "apple-b")
        _ = try await Self.signIn(backend, "apple-a")
        #expect(try await backend.profile(friendCode: them.friendCode) == them)
        #expect(try await backend.profile(friendCode: "NOPE0000") == nil)
    }

    @Test("A rename comes back on the profile and sticks")
    func renameSticks() async throws {
        let backend = FakeBackend()
        let me = try await Self.signIn(backend, "apple-a")
        let renamed = try await backend.updateDisplayName("Nate")
        #expect(renamed.displayName == "Nate")
        #expect(try await backend.profile(id: me.id).displayName == "Nate")
    }

    /// The whole request → accept path, from both sides. `friendships()` is
    /// what the friends list renders, so it has to show the row to each end.
    @Test("A friend request accepted is one row, visible to both, stamped once")
    func requestAndAccept() async throws {
        let backend = FakeBackend()
        let them = try await Self.signIn(backend, "apple-b")
        let me = try await Self.signIn(backend, "apple-a")

        let pending = try await backend.requestFriend(addresseeID: them.id)
        #expect(pending.status == .pending)
        #expect(pending.respondedAt == nil)
        #expect(try await backend.friendships().count == 1)

        _ = try await Self.signIn(backend, "apple-b")
        let accepted = try await backend.respondToFriendRequest(requesterID: me.id, accept: true)
        #expect(accepted.status == .accepted)
        #expect(accepted.respondedAt != nil, "status and responded_at move together")

        let mine = try await backend.friendships()
        #expect(mine.count == 1, "one row per unordered pair, not one per direction")
        #expect(mine[0].other(than: them.id) == me.id)
    }

    @Test("A second request to the same person is refused, from either direction")
    func onlyOneRowPerPair() async throws {
        let backend = FakeBackend()
        let them = try await Self.signIn(backend, "apple-b")
        let me = try await Self.signIn(backend, "apple-a")
        _ = try await backend.requestFriend(addresseeID: them.id)

        await #expect(throws: BackendError.alreadyExists) {
            try await backend.requestFriend(addresseeID: them.id)
        }
        // The other end asking is the same pair, so it is the same row.
        _ = try await Self.signIn(backend, "apple-b")
        await #expect(throws: BackendError.alreadyExists) {
            try await backend.requestFriend(addresseeID: me.id)
        }
        #expect(try await backend.friendships().count == 1)
    }

    @Test("You cannot friend or block yourself, or friend a stranger who does not exist")
    func requestGuards() async throws {
        let backend = FakeBackend()
        let me = try await Self.signIn(backend, "apple-a")
        await #expect(throws: BackendError.permissionDenied) {
            try await backend.requestFriend(addresseeID: me.id)
        }
        await #expect(throws: BackendError.permissionDenied) {
            try await backend.block(me.id)
        }
        await #expect(throws: BackendError.notFound) {
            try await backend.requestFriend(addresseeID: UUID())
        }
    }

    @Test("A block stops the pair, whether or not a friendship existed")
    func blocking() async throws {
        let backend = FakeBackend()
        let them = try await Self.signIn(backend, "apple-b")
        _ = try await Self.signIn(backend, "apple-a")

        let blocked = try await backend.block(them.id)
        #expect(blocked.status == .blocked)
        #expect(blocked.respondedAt != nil)
        #expect(try await backend.friendships().count == 1, "a block reuses the pair's one row")

        // The blocked end asking to be friends is told about the block, not
        // that the row simply exists.
        _ = try await Self.signIn(backend, "apple-b")
        await #expect(throws: BackendError.blocked) {
            try await backend.requestFriend(addresseeID: blocked.requesterID)
        }
    }

    @Test("Declining a request blocks rather than deleting, so it cannot be re-sent")
    func decliningBlocks() async throws {
        let backend = FakeBackend()
        let them = try await Self.signIn(backend, "apple-b")
        let me = try await Self.signIn(backend, "apple-a")
        _ = try await backend.requestFriend(addresseeID: them.id)

        _ = try await Self.signIn(backend, "apple-b")
        let declined = try await backend.respondToFriendRequest(requesterID: me.id, accept: false)
        #expect(declined.status == .blocked)

        // Answering twice is not a second answer.
        await #expect(throws: BackendError.alreadyExists) {
            try await backend.respondToFriendRequest(requesterID: me.id, accept: false)
        }
    }

    @Test("Answering a request nobody sent is not found")
    func respondingToNothing() async throws {
        let backend = FakeBackend()
        _ = try await Self.signIn(backend, "apple-a")
        await #expect(throws: BackendError.notFound) {
            try await backend.respondToFriendRequest(requesterID: UUID(), accept: true)
        }
    }

    @Test("A created match holds its host, and its invite code lets others in")
    func createAndJoin() async throws {
        let backend = FakeBackend()
        let host = try await Self.signIn(backend, "apple-a")
        let match = try await backend.createMatch(options: Self.options, seed: 42)

        #expect(match.hostID == host.id)
        #expect(match.status == .lobby)
        #expect(match.wireVersion == WireFormat.current)
        #expect(match.poolSeed == 42)
        #expect(try await backend.players(inMatch: match.id).map(\.playerID) == [host.id])

        let guest = try await Self.signIn(backend, "apple-b")
        let joined = try await backend.joinMatch(inviteCode: match.inviteCode)
        #expect(joined.id == match.id)

        let rows = try await backend.players(inMatch: match.id)
        #expect(rows.map(\.playerID) == [host.id, guest.id], "membership is in join order")

        // Joining again is idempotent, not a second seat: a guest who
        // backgrounds the app and comes back must not fill the lobby.
        _ = try await backend.joinMatch(inviteCode: match.inviteCode)
        #expect(try await backend.players(inMatch: match.id).count == 2)
    }

    @Test("A dead invite code is not found")
    func badInviteCode() async throws {
        let backend = FakeBackend()
        _ = try await Self.signIn(backend, "apple-a")
        await #expect(throws: BackendError.notFound) {
            try await backend.joinMatch(inviteCode: "ZZZZZZ")
        }
    }

    /// The lobby stops at the same ceiling the engine deals for. One past it is
    /// the case the join screen has to show a message for.
    @Test("The lobby fills to MatchLimits.players.upperBound and refuses the next")
    func lobbyFills() async throws {
        let backend = FakeBackend()
        _ = try await Self.signIn(backend, "apple-0")
        let match = try await backend.createMatch(options: Self.options, seed: 1)

        for index in 1..<MatchLimits.players.upperBound {
            _ = try await Self.signIn(backend, "apple-\(index)")
            _ = try await backend.joinMatch(inviteCode: match.inviteCode)
        }
        #expect(try await backend.players(inMatch: match.id).count
            == MatchLimits.players.upperBound)

        _ = try await Self.signIn(backend, "apple-late")
        await #expect(throws: BackendError.matchFull) {
            try await backend.joinMatch(inviteCode: match.inviteCode)
        }
        #expect(try await backend.players(inMatch: match.id).count
            == MatchLimits.players.upperBound)
    }

    /// The point of the seam: what comes back is a `MatchTransport`, so
    /// `MatchSession` never learns a network exists.
    @Test("A match hands back a transport that speaks the wire")
    func transportIsAMatchTransport() async throws {
        let backend = FakeBackend()
        _ = try await Self.signIn(backend, "apple-a")
        let match = try await backend.createMatch(options: Self.options, seed: 1)
        let player = PlayerID(rawValue: "p0")
        let transport = try await backend.transport(for: match, as: player)
        #expect(transport.localPlayerID == player)
    }

    @Test("Every call before sign-in reports notAuthenticated")
    func callsNeedASession() async {
        let backend = FakeBackend()
        await #expect(throws: BackendError.notAuthenticated) {
            try await backend.createMatch(options: Self.options, seed: 1)
        }
        await #expect(throws: BackendError.notAuthenticated) {
            try await backend.requestFriend(addresseeID: UUID())
        }
        await #expect(throws: BackendError.notAuthenticated) {
            try await backend.updateDisplayName("Nate")
        }
    }
}
