import Foundation
import Testing
@testable import Match

/// One `FakeBackend` carrying every friendship state at once, built only
/// through the seam.
///
/// Nothing here reaches into the fake's storage: each row is put into the state
/// the name says by the same calls the app makes, because a row placed by a back
/// door is a row the real database would never have accepted.
///
/// `FakeBackend.signInWithApple` derives the user from the token, so switching
/// tokens is how one store holds five people.
struct FriendsFixture {

    let backend: FakeBackend
    /// The signed-in player, and who the model is built for.
    let me: Profile
    /// Already friends, both ways agreed.
    let friend: Profile
    /// Has asked to be friends and is waiting on `me`.
    let asker: Profile
    /// `me` has asked them and is waiting.
    let asked: Profile
    /// Declined by `me`, so the row is `blocked` with them as requester.
    let blockedThem: Profile
    /// Blocked by `me` outright, so the row is `blocked` with `me` as requester.
    let blockedByMe: Profile

    static func make() async throws -> FriendsFixture {
        let backend = FakeBackend()

        let me = try await backend.signIn("me")

        // Renamed to sort *after* everyone created later, so a section holding
        // two people is one the insertion order and the name order disagree
        // about. Without that, `FriendsModel`'s sort is untestable: the fake
        // hands rows back in the order they were made, which is already the
        // order the names happen to fall in.
        var friend = try await backend.signIn("friend")
        friend.displayName = "Zoe"
        await backend.seedProfile(friend)

        let asker = try await backend.signIn("asker")
        let asked = try await backend.signIn("asked")
        let blockedThem = try await backend.signIn("blocked-them")
        let blockedByMe = try await backend.signIn("blocked-by-me")

        // accepted: they asked, `me` said yes.
        _ = try await backend.signIn("friend")
        _ = try await backend.requestFriend(addresseeID: me.id)
        _ = try await backend.signIn("me")
        _ = try await backend.respondToFriendRequest(requesterID: friend.id, accept: true)

        // incoming: they asked and nobody has answered.
        _ = try await backend.signIn("asker")
        _ = try await backend.requestFriend(addresseeID: me.id)

        // outgoing: `me` asked and nobody has answered.
        _ = try await backend.signIn("me")
        _ = try await backend.requestFriend(addresseeID: asked.id)

        // blocked, both directions of the pair.
        _ = try await backend.signIn("blocked-them")
        _ = try await backend.requestFriend(addresseeID: me.id)
        _ = try await backend.signIn("me")
        _ = try await backend.respondToFriendRequest(requesterID: blockedThem.id, accept: false)
        _ = try await backend.block(blockedByMe.id)

        return FriendsFixture(
            backend: backend,
            me: me,
            friend: friend,
            asker: asker,
            asked: asked,
            blockedThem: blockedThem,
            blockedByMe: blockedByMe
        )
    }
}

extension FakeBackend {

    /// Signs a token's owner in, creating their profile the first time.
    func signIn(_ token: String) async throws -> Profile {
        try await signInWithApple(idToken: token, nonce: "nonce")
    }
}
