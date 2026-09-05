import Foundation
import WillagramsRules
@testable import Match

/// A gate a test opens by hand.
///
/// The point is withholding. A double that answers immediately makes every
/// "while it is loading" assertion vacuous — the load is already over by the
/// time the assertion runs — so this one parks the call until the test says
/// otherwise, and lets the test park two calls at once and finish them in the
/// order it chooses.
actor Gate {

    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var watchers: [(need: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var arrivals = 0
    private var isOpen = false

    /// Called from inside the gated backend method: returns only when released.
    func pass() async {
        arrivals += 1
        wakeWatchers()
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// How many calls have reached the gate so far.
    ///
    /// Polled rather than awaited by the one case that asks a question the
    /// answer to which may be "never" — waiting on an arrival that a serial
    /// implementation will never make would hang the suite instead of failing
    /// it, and `.timeLimit` cannot cancel a parked continuation.
    var arrivalCount: Int { arrivals }

    /// Test side: returns once `count` calls have reached the gate.
    func waitForArrivals(_ count: Int) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    /// Lets one parked call through — `index` counts in arrival order.
    func release(_ index: Int = 0) {
        guard waiting.indices.contains(index) else { return }
        waiting.remove(at: index).resume()
    }

    /// Lets everything through, now and from now on.
    func open() {
        isOpen = true
        let parked = waiting
        waiting = []
        for continuation in parked { continuation.resume() }
    }

    private func wakeWatchers() {
        let ready = watchers.filter { $0.need <= arrivals }
        watchers.removeAll { $0.need <= arrivals }
        for watcher in ready { watcher.continuation.resume() }
    }
}

/// A `BackendClient` that forwards to a real `FakeBackend` but can hold the two
/// reads and the one write `FriendsModel` makes, and can refuse one profile.
///
/// `friendships()` reads *before* the gate, so a load parked here is carrying
/// the rows as they were when it started — which is what makes "an overtaken
/// load must not publish" a real assertion rather than a coincidence.
actor GatedBackend: BackendClient {

    let inner: FakeBackend
    let friendshipsGate: Gate?
    let profileGate: Gate?
    let writeGate: Gate?

    private let failingProfiles: Set<UUID>
    private(set) var profileCalls: [UUID] = []

    /// Whether a `friendships()` call *released from the gate* throws.
    ///
    /// Checked after the gate, not before, so a test that has two loads parked
    /// can decide which of them fails by flipping this between two releases —
    /// which is the only way to make the *older* of two overlapping loads be the
    /// one that fails.
    private var friendshipsFail = false

    init(
        inner: FakeBackend,
        friendshipsGate: Gate? = nil,
        profileGate: Gate? = nil,
        writeGate: Gate? = nil,
        failingProfiles: Set<UUID> = []
    ) {
        self.inner = inner
        self.friendshipsGate = friendshipsGate
        self.profileGate = profileGate
        self.writeGate = writeGate
        self.failingProfiles = failingProfiles
    }

    struct ProfileRefused: Error {}
    struct FriendshipsRefused: Error {}

    func setFriendshipsFailing(_ failing: Bool) { friendshipsFail = failing }

    var currentUserID: UUID? {
        get async { await inner.currentUserID }
    }

    func signInWithApple(idToken: String, nonce: String) async throws -> Profile {
        try await inner.signInWithApple(idToken: idToken, nonce: nonce)
    }

    func signOut() async throws { try await inner.signOut() }

    func profile(id: UUID) async throws -> Profile {
        profileCalls.append(id)
        await profileGate?.pass()
        if failingProfiles.contains(id) { throw ProfileRefused() }
        return try await inner.profile(id: id)
    }

    func profile(friendCode: String) async throws -> Profile? {
        try await inner.profile(friendCode: friendCode)
    }

    func updateDisplayName(_ name: String) async throws -> Profile {
        try await inner.updateDisplayName(name)
    }

    func friendships() async throws -> [Friendship] {
        let rows = try await inner.friendships()
        await friendshipsGate?.pass()
        if friendshipsFail { throw FriendshipsRefused() }
        return rows
    }

    func requestFriend(addresseeID: UUID) async throws -> Friendship {
        try await inner.requestFriend(addresseeID: addresseeID)
    }

    func respondToFriendRequest(requesterID: UUID, accept: Bool) async throws -> Friendship {
        await writeGate?.pass()
        return try await inner.respondToFriendRequest(requesterID: requesterID, accept: accept)
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
