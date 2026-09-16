import Foundation
import Testing
import WillagramsRules
@testable import Friends
@testable import Match
@testable import Shell

/// Inviting a friend to play, end to end and offline.
///
/// Two real `ShellModel`s over one `FakeBackend` and one `FakeInviteBus`: the
/// invite that reaches B is one A's host lobby actually produced, carrying the
/// code that lobby actually minted, and B's Join runs the real join. Nothing
/// here sets a banner by hand except the cases that are *about* what the shell
/// refuses — and each of those is paired with a positive twin, because
/// `FakeInviteBus` withholds rather than buffers and a refusal asserted over a
/// bus that delivered nothing is vacuously green.
@MainActor
@Suite("Invite a friend")
struct InviteTests {

    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal
    typealias LobbyWire = HostLobbyTests.LobbyWire

    /// The one sign-in `FakeBackend` cannot supply twice: its `ShellSignIn`
    /// conformance always signs in as the same token, and this suite needs two
    /// shells signed in as two different players on one backend.
    struct TokenSignIn: ShellSignIn {
        let backend: FakeBackend
        let token: String
        func signIn() async throws -> Profile {
            try await backend.signInWithApple(idToken: token, nonce: "invite")
        }
    }

    /// `FakeBackend` derives a player's id from the first sixteen bytes of the
    /// token, so these two names fix the sort order the host election depends on:
    /// `OnlineMatch` elects `roster[0]` and A must be the host of the lobby it
    /// opens. "invite-a…" sorts before "invite-z…" byte for byte, and every
    /// other character after the seventh is irrelevant to that.
    static let hostToken = "invite-a-host"
    static let guestToken = "invite-z-guest"

    /// Two shells, two friends, one bus.
    struct Two {
        let backend: FakeBackend
        let bus: FakeInviteBus
        let a: Profile
        let b: Profile
        let shellA: ShellModel
        let shellB: ShellModel
    }

    /// Builds both shells over one backend.
    ///
    /// `FakeBackend` holds one session, so the order below is load-bearing — the
    /// friendship is seeded from each end in turn, and B's shell signs in before
    /// A's so the session this fixture hands back is A's, which is who hosts.
    static func make(
        accepted: Bool = true,
        hostChannel: (@Sendable (UUID) -> any MatchInviteChannel)? = nil
    ) async throws -> Two {
        let backend = FakeBackend()
        let bus = FakeInviteBus()

        let b = try await backend.signInWithApple(idToken: guestToken, nonce: "invite")
        let a = try await backend.signInWithApple(idToken: hostToken, nonce: "invite")
        #expect(a.playerID.rawValue < b.playerID.rawValue, "the host would not be elected")

        let aWire = LobbyWire(localPlayerID: a.playerID)
        let bWire = LobbyWire(localPlayerID: b.playerID)
        aWire.peer = bWire
        bWire.peer = aWire
        let hostID = a.playerID
        await backend.setTransportFactory { _, player in
            player == hostID ? aWire : bWire
        }

        // Signed in as A, because the candidate search left it there.
        _ = try await backend.requestFriend(addresseeID: b.id)
        _ = try await backend.signInWithApple(idToken: guestToken, nonce: "invite")
        if accepted {
            _ = try await backend.respondToFriendRequest(requesterID: a.id, accept: true)
        }

        let shellB = ShellModel(
            dictionary: { EveryWordIsReal() },
            sleepFor: { _ in },
            services: ShellServices(
                backend: backend,
                signIn: TokenSignIn(backend: backend, token: guestToken),
                inviteChannel: bus.factory
            )
        )
        await shellB.signInTask?.value
        #expect(shellB.currentProfile?.id == b.id)
        // Subscribing is asynchronous and broadcast keeps nothing for a channel
        // that is not there yet, so the fixture waits for B to be listening
        // rather than racing A's send against it.
        await JoinTests.until("B is listening") { bus.isListening(b.id) }

        let shellA = ShellModel(
            dictionary: { EveryWordIsReal() },
            sleepFor: { _ in },
            services: ShellServices(
                backend: backend,
                signIn: TokenSignIn(backend: backend, token: hostToken),
                inviteChannel: hostChannel ?? bus.factory
            )
        )
        await shellA.signInTask?.value
        #expect(shellA.currentProfile?.id == a.id)

        return Two(backend: backend, bus: bus, a: a, b: b, shellA: shellA, shellB: shellB)
    }

    /// The friends screen A invites from, loaded, with B's row found.
    static func rowForB(_ f: Two, accepted: Bool = true) async throws -> FriendEntry {
        #expect(f.shellA.showFriends())
        let screen = try #require(f.shellA.friends)
        await screen.load()
        let rows = accepted ? screen.accepted : screen.outgoing
        return try #require(
            rows.first { $0.profile.id == f.b.id },
            "B was not on A's list at all — the fixture never seeded the friendship")
    }

    /// A lone signed-in shell on its own bus, for the cases that are about what
    /// arrives rather than who sent it.
    static func lone(
        now: @escaping @MainActor () -> Date = { Date() }
    ) async throws -> (shell: ShellModel, bus: FakeInviteBus, me: Profile, sender: Profile) {
        let backend = FakeBackend()
        let bus = FakeInviteBus()
        let sender = try await Self.acceptedFriend(on: backend)
        let shell = ShellModel(
            dictionary: { EveryWordIsReal() },
            sleepFor: { _ in },
            now: now,
            services: ShellServices(backend: backend, signIn: backend, inviteChannel: bus.factory)
        )
        await shell.signInTask?.value
        let me = try #require(shell.currentProfile, "the shell never signed in")
        await JoinTests.until("the shell is listening") { bus.isListening(me.id) }
        return (shell, bus, me, sender)
    }

    /// One accepted friend of whoever `FakeBackend: ShellSignIn` signs in as.
    ///
    /// Every `lone` case needs one: an invite from a player this one has not
    /// accepted is dropped on arrival now, so a fixture without a friendship
    /// would make every banner assertion below unfalsifiable.
    static func acceptedFriend(on backend: FakeBackend) async throws -> Profile {
        let me = try await backend.signIn()
        let sender = try await backend.signInWithApple(idToken: "invite-sender", nonce: "invite")
        _ = try await backend.requestFriend(addresseeID: me.id)
        _ = try await backend.signIn()
        _ = try await backend.respondToFriendRequest(requesterID: sender.id, accept: true)
        return sender
    }

    static func invite(
        from hostID: UUID,
        code: String = "ABC123",
        name: String = "Sender",
        sentAt: Date = Date()
    ) -> MatchInvite {
        MatchInvite(
            matchID: UUID(), inviteCode: code, hostID: hostID,
            hostName: name, sentAt: sentAt)
    }

    // MARK: - done when 1: one banner, one join, and no second banner

    @Test("Inviting from A banners B once, B's Join reaches the waiting state on A's code")
    func invitingReachesBAndBJoins() async throws {
        let f = try await Self.make()
        let entry = try await Self.rowForB(f)

        #expect(f.shellA.invitePlay(entry))
        await JoinTests.until("the invite left A") { f.bus.delivered == 1 }
        await JoinTests.until("B was bannered") { f.shellB.inviteBanner != nil }

        let banner = try #require(f.shellB.inviteBanner)
        #expect(banner.hostName == f.a.displayName)
        #expect(ShellModel.inviteLine(banner).contains(f.a.displayName))
        #expect(f.shellB.inviteMessage == nil)

        let lobby = try #require(f.shellA.hostLobby, "the invite was sent without a lobby")
        #expect(banner.inviteCode == lobby.inviteCode)
        #expect(banner.matchID == lobby.match?.record.id)

        // A second tap: A is on its lobby now, so there is nothing to send, and
        // B is not bannered twice.
        #expect(f.shellA.invitePlay(entry) == false)
        for _ in 0..<200 { await Task.yield() }
        #expect(f.bus.delivered == 1, "a second tap sent a second invite")
        #expect(f.shellB.inviteBanner == banner)

        // B joins, on the session B is: `FakeBackend` holds one.
        _ = try await f.backend.signInWithApple(idToken: Self.guestToken, nonce: "invite")
        #expect(f.shellB.joinInvite())
        #expect(f.shellB.inviteBanner == nil)
        let join = try #require(f.shellB.join)
        #expect(join.code == lobby.inviteCode)
        await JoinTests.until("B is waiting") { join.phase == .waiting }
        #expect(f.shellB.route == .join)
        #expect(f.shellB.inviteMessage == nil)

        // At most one banner per match: the same invite arriving again is
        // delivered by the bus and shown by nobody.
        try await f.bus.channel(for: f.a.id).send(banner, to: f.b.id)
        await JoinTests.until("the resend landed") { f.bus.delivered == 2 }
        for _ in 0..<200 { await Task.yield() }
        #expect(f.shellB.inviteBanner == nil, "the same match bannered twice")

        f.shellB.returnToMenu()
        f.shellA.returnToMenu()
    }

    // MARK: - done when 2: dropped during a match, dropped when stale

    @Test("An invite arriving during a match is dropped, and the same shell banners on the menu")
    func droppedDuringAMatch() async throws {
        let (shell, bus, me, sender) = try await Self.lone()

        #expect(shell.startSoloPractice())
        shell.countdownFinished()
        guard case .match = shell.route else {
            Issue.record("the shell never reached the match route")
            return
        }

        try await bus.channel(for: sender.id).send(Self.invite(from: sender.id, name: "Mid-match"), to: me.id)
        await JoinTests.until("the bus delivered it") { bus.delivered == 1 }
        for _ in 0..<200 { await Task.yield() }
        #expect(shell.inviteBanner == nil, "a banner landed over a live match")
        #expect(shell.inviteMessage == nil)

        // The positive twin: same shell, same bus, same send — on the menu.
        shell.returnToMenu()
        try await bus.channel(for: sender.id).send(Self.invite(from: sender.id, name: "On the menu"), to: me.id)
        await JoinTests.until("the menu banner") { shell.inviteBanner != nil }
        #expect(shell.inviteBanner?.hostName == "On the menu")

        shell.returnToMenu()
    }

    @Test("An invite older than two minutes publishes nothing, a fresh one banners")
    func staleInvitesAreDropped() async throws {
        let (shell, bus, me, sender) = try await Self.lone()
        let stale = Self.invite(
            from: sender.id,
            name: "Stale",
            sentAt: Date().addingTimeInterval(-(ShellModel.inviteLifetime + 1)))

        try await bus.channel(for: sender.id).send(stale, to: me.id)
        await JoinTests.until("the stale invite landed") { bus.delivered == 1 }
        for _ in 0..<200 { await Task.yield() }
        #expect(shell.inviteBanner == nil, "a two-minute-old invite was shown")
        #expect(shell.inviteMessage == nil, "a stale invite that was never shown said so")

        try await bus.channel(for: sender.id).send(Self.invite(from: sender.id, name: "Fresh"), to: me.id)
        await JoinTests.until("the fresh invite") { shell.inviteBanner != nil }
        #expect(shell.inviteBanner?.hostName == "Fresh")

        shell.returnToMenu()
    }

    // MARK: - done when 3: a dead lobby clears with one line

    @Test("Joining a cancelled lobby clears the banner with the over line and B stays on the menu")
    func joiningACancelledLobbyClears() async throws {
        let f = try await Self.make()
        let entry = try await Self.rowForB(f)

        #expect(f.shellA.invitePlay(entry))
        await JoinTests.until("B was bannered") { f.shellB.inviteBanner != nil }
        let matchID = try #require(f.shellA.hostLobby?.match?.record.id)

        // A backs out, which abandons the row the code points at.
        f.shellA.returnToMenu()
        await JoinTests.until("the row left the lobby") {
            await f.backend.matchRecord(matchID)?.status != .lobby
        }

        _ = try await f.backend.signInWithApple(idToken: Self.guestToken, nonce: "invite")
        #expect(f.shellB.joinInvite())
        await JoinTests.until("the over line") {
            f.shellB.inviteMessage == ShellModel.inviteOverMessage
        }
        #expect(f.shellB.route == .menu)
        #expect(f.shellB.inviteBanner == nil)
        #expect(f.shellB.join == nil)
    }

    /// The other half of the clause: an expiry that passes while the banner sits
    /// there clears it with the same line, and does not before.
    @Test("A banner that ages past two minutes clears itself with the over line")
    func anAgedBannerClearsItself() async throws {
        final class Clock: @unchecked Sendable {
            var value = Date()
        }
        let clock = Clock()
        let (shell, bus, me, sender) = try await Self.lone(now: { clock.value })

        try await bus.channel(for: UUID()).send(Self.invite(from: sender.id, sentAt: clock.value), to: me.id)
        await JoinTests.until("the banner") { shell.inviteBanner != nil }

        // Not yet: one second short of the lifetime.
        clock.value = clock.value.addingTimeInterval(ShellModel.inviteLifetime - 1)
        shell.expireInviteBanner()
        #expect(shell.inviteBanner != nil, "a live banner expired early")
        #expect(shell.inviteMessage == nil)

        clock.value = clock.value.addingTimeInterval(2)
        shell.expireInviteBanner()
        #expect(shell.inviteBanner == nil)
        #expect(shell.inviteMessage == ShellModel.inviteOverMessage)

        // And the way in is gone with it.
        #expect(shell.joinInvite() == false)
        #expect(shell.route == .menu)

        shell.returnToMenu()
    }

    // MARK: - guardrails

    @Test("The bus withholds: an invite to a shell that is not listening is dropped, not buffered")
    func theBusWithholds() async throws {
        let bus = FakeInviteBus()
        let absent = UUID()
        #expect(bus.isListening(absent) == false)

        try await bus.channel(for: UUID()).send(Self.invite(from: UUID()), to: absent)
        #expect(bus.dropped == 1)
        #expect(bus.delivered == 0, "an invite nobody was listening for was buffered")

        // The positive twin, on the same bus: a listener gets it.
        let listener = bus.channel(for: absent)
        try await listener.subscribe()
        #expect(bus.isListening(absent))
        try await bus.channel(for: UUID()).send(Self.invite(from: UUID()), to: absent)
        #expect(bus.delivered == 1)
        listener.leave()
        #expect(bus.isListening(absent) == false)
    }

    @Test("The channel is torn down with the model and does not outlive it")
    func teardownEndsTheChannel() async throws {
        let (shell, bus, me, sender) = try await Self.lone()
        #expect(bus.isListening(me.id), "sign-in never subscribed")


        shell.endInviteChannel()
        await JoinTests.until("the channel left") { bus.isListening(me.id) == false }
        #expect(shell.inviteBanner == nil)

        // Nothing arrives after it: the send is dropped, not queued.
        try await bus.channel(for: UUID()).send(Self.invite(from: sender.id), to: me.id)
        #expect(bus.dropped == 1)
        for _ in 0..<200 { await Task.yield() }
        #expect(shell.inviteBanner == nil)
    }

    @Test("A pending friend cannot be invited, and the accepted one can")
    func onlyAcceptedFriendsCanBeInvited() async throws {
        let pending = try await Self.make(accepted: false)
        let outgoing = try await Self.rowForB(pending, accepted: false)
        #expect(outgoing.friendship.status == .pending)

        #expect(pending.shellA.invitePlay(outgoing) == false)
        for _ in 0..<200 { await Task.yield() }
        #expect(pending.bus.delivered == 0, "a pending row sent an invite")
        #expect(pending.shellA.route == .friends)
        #expect(pending.shellA.hostLobby == nil)
        pending.shellA.returnToMenu()

        // The twin: the same call, the same bus, on an accepted row.
        let f = try await Self.make()
        let entry = try await Self.rowForB(f)
        #expect(entry.friendship.status == .accepted)
        #expect(f.shellA.invitePlay(entry))
        await JoinTests.until("the accepted row sent one") { f.bus.delivered == 1 }
        f.shellA.returnToMenu()
    }

    @Test("Only the four screens that can carry a banner do")
    func onlyFourRoutesShowInvites() {
        #expect(ShellModel.showsInvites(.menu))
        #expect(ShellModel.showsInvites(.friends))
        #expect(ShellModel.showsInvites(.profile))
        #expect(ShellModel.showsInvites(.join))
        #expect(ShellModel.showsInvites(.hostLobby) == false)
        #expect(ShellModel.showsInvites(.soloSetup) == false)
        #expect(ShellModel.showsInvites(.howToPlay) == false)
        // The three the rule exists for: a banner over a live match, or over
        // the count into one, is the failure this allow-list prevents.
        #expect(ShellModel.showsInvites(.countdown(MatchBoardTests.setup)) == false)
        #expect(ShellModel.showsInvites(.match(MatchBoardTests.setup)) == false)
        #expect(ShellModel.showsInvites(.results(winner: nil)) == false)
    }

    // MARK: - The sender is checked here, not only on the sender's device

    @Test("An invite from someone who is not an accepted friend publishes nothing")
    func strangersAndSelfAreDropped() async throws {
        let (shell, bus, me, sender) = try await Self.lone()

        // A friend code resolves to a uuid, so a stranger can address this
        // topic. What they cannot do is be on the friends list.
        try await bus.channel(for: UUID()).send(
            Self.invite(from: UUID(), name: "Stranger"), to: me.id)
        await JoinTests.until("the stranger's invite landed") { bus.delivered == 1 }
        for _ in 0..<200 { await Task.yield() }
        #expect(shell.inviteBanner == nil, "a stranger bannered this player")

        // Nor can they claim to be the player themself.
        try await bus.channel(for: UUID()).send(
            Self.invite(from: me.id, name: "Me"), to: me.id)
        await JoinTests.until("the spoofed self-invite landed") { bus.delivered == 2 }
        for _ in 0..<200 { await Task.yield() }
        #expect(shell.inviteBanner == nil, "an invite claiming to be from this player bannered")

        // The positive twin, same shell and same bus: the accepted friend gets
        // through.
        try await bus.channel(for: sender.id).send(
            Self.invite(from: sender.id, name: "Friend"), to: me.id)
        await JoinTests.until("the friend's invite") { shell.inviteBanner != nil }
        #expect(shell.inviteBanner?.hostName == "Friend")

        shell.returnToMenu()
    }

    /// The `.accepted` half of the sender check, which the stranger case above
    /// structurally cannot reach: a stranger has no friendship row at all, so
    /// relaxing `status == .accepted` to "any row" still drops them and the
    /// case stays green. A pending sender is the only shape that isolates the
    /// status predicate — and it matters more than a pending row suggests,
    /// because declining a request leaves the counterpart `.blocked` rather
    /// than deleting the row.
    @Test("A sender who is only pending, or blocked, publishes nothing")
    func aPendingSenderIsDropped() async throws {
        let (shell, bus, me, accepted) = try await Self.lone()
        let backend = try #require(shell.services.backend as? FakeBackend)

        // A second player who has asked and not been answered.
        let pending = try await backend.signInWithApple(
            idToken: "invite-pending", nonce: "invite")
        _ = try await backend.requestFriend(addresseeID: me.id)
        // Back to the session the shell reads its friendships on.
        _ = try await backend.signIn()

        try await bus.channel(for: pending.id).send(
            Self.invite(from: pending.id, name: "Pending"), to: me.id)
        await JoinTests.until("the pending sender's invite landed") { bus.delivered == 1 }
        for _ in 0..<200 { await Task.yield() }
        #expect(shell.inviteBanner == nil, "a sender who was never accepted bannered this player")

        // The positive twin, same shell and same bus: the accepted one lands.
        try await bus.channel(for: accepted.id).send(
            Self.invite(from: accepted.id, name: "Accepted"), to: me.id)
        await JoinTests.until("the accepted sender's invite") { shell.inviteBanner != nil }
        #expect(shell.inviteBanner?.hostName == "Accepted")

        shell.returnToMenu()
    }

    // MARK: - One banner at a time

    @Test("A second invite does not replace the banner being answered")
    func aSecondInviteReplacesNothing() async throws {
        let (shell, bus, me, sender) = try await Self.lone()
        let channel = bus.channel(for: sender.id)

        let first = Self.invite(from: sender.id, code: "FIRST1", name: "First")
        try await channel.send(first, to: me.id)
        await JoinTests.until("the first banner") { shell.inviteBanner != nil }

        let second = Self.invite(from: sender.id, code: "SECND2", name: "Second")
        try await channel.send(second, to: me.id)
        await JoinTests.until("the second invite landed") { bus.delivered == 2 }
        for _ in 0..<200 { await Task.yield() }
        #expect(shell.inviteBanner == first, "the banner swapped under the player's finger")

        // The positive twin: once the first is answered, the next one lands.
        shell.joinInvite()
        shell.returnToMenu()
        let third = Self.invite(from: sender.id, code: "THIRD3", name: "Third")
        try await channel.send(third, to: me.id)
        await JoinTests.until("the third banner") { shell.inviteBanner != nil }
        #expect(shell.inviteBanner == third)

        shell.returnToMenu()
    }

    // MARK: - A refused subscribe is retried, not fatal

    /// A channel that refuses its first `failures` subscribes, and records what
    /// was tried. Deliberately delivers nothing on its own: an invite only
    /// arrives when the test yields one, so "the pump is running" is never
    /// something this double asserts for free.
    final class FlakyInviteChannel: MatchInviteChannel, @unchecked Sendable {
        let invites: AsyncStream<MatchInvite>
        private let continuation: AsyncStream<MatchInvite>.Continuation
        private let lock = NSLock()
        private var remaining: Int
        private var tries = 0
        private var leaves = 0

        init(failures: Int) {
            remaining = failures
            (invites, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        }

        var attempts: Int { lock.withLock { tries } }
        var hasLeft: Bool { lock.withLock { leaves > 0 } }

        func subscribe() async throws {
            let refuse = lock.withLock { () -> Bool in
                tries += 1
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
            if refuse { throw BackendError.offline }
        }

        func send(_ invite: MatchInvite, to recipientID: UUID) async throws {}
        func deliver(_ invite: MatchInvite) { continuation.yield(invite) }
        func leave() {
            lock.withLock { leaves += 1 }
            continuation.finish()
        }
    }

    static func shell(over channel: FlakyInviteChannel) async throws -> (ShellModel, Profile, Profile) {
        let backend = FakeBackend()
        let sender = try await Self.acceptedFriend(on: backend)
        let shell = ShellModel(
            dictionary: { EveryWordIsReal() },
            sleepFor: { _ in },
            services: ShellServices(
                backend: backend, signIn: backend, inviteChannel: { _ in channel })
        )
        await shell.signInTask?.value
        let me = try #require(shell.currentProfile)
        return (shell, me, sender)
    }

    @Test("A socket that refuses twice is retried, and invites still arrive")
    func aRefusedSubscribeIsRetried() async throws {
        // Literal, not derived from the constant: a budget of one would make
        // "no failures to recover from" pass this case by accident.
        #expect(ShellModel.inviteSubscribeAttempts >= 3)
        let channel = FlakyInviteChannel(failures: 2)
        let (shell, _, sender) = try await Self.shell(over: channel)

        await JoinTests.until("the retries") { channel.attempts == 3 }
        #expect(channel.hasLeft == false, "a channel that did subscribe was thrown away")

        channel.deliver(Self.invite(from: sender.id, name: "After the retry"))
        await JoinTests.until("the banner") { shell.inviteBanner != nil }
        #expect(shell.inviteBanner?.hostName == "After the retry")

        shell.returnToMenu()
    }

    @Test("A socket that never comes up is given up on and closed, not held open")
    func aDeadSubscribeIsClosed() async throws {
        let channel = FlakyInviteChannel(failures: 99)
        let (shell, _, sender) = try await Self.shell(over: channel)

        await JoinTests.until("the channel to be closed") { channel.hasLeft }
        #expect(channel.attempts == 3, "the retry budget was not spent")

        // And nothing it yields afterwards reaches a banner.
        channel.deliver(Self.invite(from: sender.id))
        for _ in 0..<200 { await Task.yield() }
        #expect(shell.inviteBanner == nil)

        shell.returnToMenu()
    }

    // MARK: - What the host and the guest are told

    @Test("A send that fails tells the host, and one that works says nothing")
    func aFailedSendIsSaid() async throws {
        let f = try await Self.make()
        let entry = try await Self.rowForB(f)

        #expect(f.shellA.invitePlay(entry))
        await JoinTests.until("the invite left A") { f.bus.delivered == 1 }
        for _ in 0..<200 { await Task.yield() }
        #expect(f.shellA.inviteMessage == nil, "a send that worked said something")
        f.shellA.returnToMenu()

        // No channel to send on is the same story to the player as a send that
        // threw, and it is the reachable half offline.
        let noChannel = try await Self.make()
        noChannel.shellB.endInviteChannel()
        let entryA = try await Self.rowForB(noChannel)
        noChannel.shellA.endInviteChannel()
        #expect(noChannel.shellA.invitePlay(entryA) == false)
        #expect(noChannel.shellA.inviteMessage == ShellModel.inviteSendFailedMessage)
        noChannel.shellA.returnToMenu()
    }

    @Test("The over line does not follow the player around")
    func theOverLineIsNotPinned() async throws {
        let f = try await Self.make()
        let entry = try await Self.rowForB(f)

        #expect(f.shellA.invitePlay(entry))
        await JoinTests.until("B was bannered") { f.shellB.inviteBanner != nil }
        let matchID = try #require(f.shellA.hostLobby?.match?.record.id)
        f.shellA.returnToMenu()
        await JoinTests.until("the row left the lobby") {
            await f.backend.matchRecord(matchID)?.status != .lobby
        }

        _ = try await f.backend.signInWithApple(idToken: Self.guestToken, nonce: "invite")
        #expect(f.shellB.joinInvite())
        await JoinTests.until("the over line") {
            f.shellB.inviteMessage == ShellModel.inviteOverMessage
        }

        // The next thing the player does clears it.
        f.shellB.showSoloSetup()
        f.shellB.returnToMenu()
        #expect(f.shellB.inviteMessage == nil, "the over line was still pinned to the menu")
    }

    @Test("A host name is clamped to one short line before anything draws it")
    func hostNamesAreClamped() {
        let long = String(repeating: "W", count: 500)
        let invite = MatchInvite(
            matchID: UUID(), inviteCode: "ABC123", hostID: UUID(),
            hostName: long + "\nsecond line", sentAt: Date())
        #expect(invite.hostName.count == MatchInvite.hostNameLimit)
        let hasNewline = invite.hostName.contains { $0.isNewline }
        #expect(hasNewline == false)
        #expect(ShellModel.inviteLine(invite).count < 80)

        // The twin: an ordinary name is untouched.
        let ordinary = MatchInvite(
            matchID: UUID(), inviteCode: "ABC123", hostID: UUID(),
            hostName: "Ada Lovelace", sentAt: Date())
        #expect(ordinary.hostName == "Ada Lovelace")
    }

    // MARK: - What an unwanted frame costs the recipient

    /// A lone signed-in shell with the backend behind it in hand, so a case can
    /// count what an arriving frame costs in round trips.
    static func counted() async throws
        -> (shell: ShellModel, backend: FakeBackend, bus: FakeInviteBus, me: Profile, sender: Profile) {
        let backend = FakeBackend()
        let bus = FakeInviteBus()
        let sender = try await Self.acceptedFriend(on: backend)
        let shell = ShellModel(
            dictionary: { EveryWordIsReal() },
            sleepFor: { _ in },
            services: ShellServices(backend: backend, signIn: backend, inviteChannel: bus.factory)
        )
        await shell.signInTask?.value
        let me = try #require(shell.currentProfile, "the shell never signed in")
        await JoinTests.until("the shell is listening") { bus.isListening(me.id) }
        return (shell, backend, bus, me, sender)
    }

    @Test("A flood of frames from a stranger costs one friend-list read, not one each")
    func aFloodCostsOneRoundTrip() async throws {
        let (shell, backend, bus, me, sender) = try await Self.counted()
        // A sender's endpoint: `send` only needs the bus, so this need not be
        // subscribed itself.
        let channel = bus.channel(for: UUID())

        // The recorder counts: the first unwanted frame does read the list.
        let before = await backend.friendshipsFetches
        let stranger = UUID()
        for _ in 0 ..< 12 {
            try await channel.send(Self.invite(from: stranger), to: me.id)
        }
        await JoinTests.until("the frames were taken") { bus.delivered == 12 }
        for _ in 0..<400 { await Task.yield() }
        let after = await backend.friendshipsFetches
        #expect(after == before + 1, "a stranger's flood cost \(after - before) friend-list reads")
        #expect(shell.inviteBanner == nil, "a stranger was bannered")

        // The positive twin on the same recorder: the cache does not swallow a
        // real friend, and it is served without another read.
        try await channel.send(Self.invite(from: sender.id, name: "Real friend"), to: me.id)
        await JoinTests.until("the friend's banner") { shell.inviteBanner != nil }
        #expect(shell.inviteBanner?.hostName == "Real friend")
        let atEnd = await backend.friendshipsFetches
        #expect(atEnd == before + 1, "the accepted friend cost a second read")

        shell.returnToMenu()
        shell.endInviteChannel()
    }

    // MARK: - A send that fails after the player has moved on

    /// A channel whose `send` parks until the test lets it fail, so the failure
    /// can be made to land after the lobby it belonged to is gone.
    final class ParkedFailingChannel: MatchInviteChannel, @unchecked Sendable {
        let invites: AsyncStream<MatchInvite>
        private let continuation: AsyncStream<MatchInvite>.Continuation
        private let lock = NSLock()
        private var parked = false
        private var freed = false

        init() { (invites, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded) }

        var isSending: Bool { lock.withLock { parked } }
        func release() { lock.withLock { freed = true } }

        func subscribe() async throws {}
        func send(_ invite: MatchInvite, to recipientID: UUID) async throws {
            lock.withLock { parked = true }
            while !lock.withLock({ freed }) { await Task.yield() }
            throw BackendError.offline
        }
        func leave() { continuation.finish() }
    }

    @Test("A send that fails after the lobby is gone says nothing; one that fails in it does")
    func aStaleSendFailureIsSilent() async throws {
        let parked = ParkedFailingChannel()
        let f = try await Self.make(hostChannel: { _ in parked })
        let entry = try await Self.rowForB(f)

        #expect(f.shellA.invitePlay(entry))
        await JoinTests.until("the send to park") { parked.isSending }
        // The player gives up on the lobby while the send is still in flight.
        f.shellA.returnToMenu()
        parked.release()
        for _ in 0..<400 { await Task.yield() }
        #expect(f.shellA.inviteMessage == nil, "a dead lobby's failure was pinned over the menu")

        // The twin on the same double: the identical failure inside the lobby
        // it belongs to is said, so the silence above is a guard and not a
        // branch that never runs.
        let parked2 = ParkedFailingChannel()
        let g = try await Self.make(hostChannel: { _ in parked2 })
        let entry2 = try await Self.rowForB(g)
        #expect(g.shellA.invitePlay(entry2))
        await JoinTests.until("the second send to park") { parked2.isSending }
        parked2.release()
        await JoinTests.until("the host to be told") {
            g.shellA.inviteMessage == ShellModel.inviteSendFailedMessage
        }
        g.shellA.returnToMenu()
    }

    // MARK: - The open seat

    /// Three more counterparts around A, one of every relationship that is not
    /// an accepted friendship: C has asked A, A has asked D, and A has blocked
    /// E. Without all three present the accepted-only rule below is
    /// unfalsifiable — a picker that lists nobody would pass it.
    ///
    /// Leaves the session on A, which is who every caller loads as.
    static func seedMixedRelationships(
        _ f: Two
    ) async throws -> (incoming: Profile, outgoing: Profile, blocked: Profile) {
        let c = try await f.backend.signInWithApple(idToken: "invite-c-asks-me", nonce: "invite")
        _ = try await f.backend.requestFriend(addresseeID: f.a.id)
        let d = try await f.backend.signInWithApple(idToken: "invite-d-i-asked", nonce: "invite")
        let e = try await f.backend.signInWithApple(idToken: "invite-e-blocked", nonce: "invite")
        _ = try await f.backend.signInWithApple(idToken: Self.hostToken, nonce: "invite")
        _ = try await f.backend.requestFriend(addresseeID: d.id)
        _ = try await f.backend.block(e.id)
        return (c, d, e)
    }

    @Test("The open seat's picker lists accepted friends and nobody else")
    func openSeatPickerListsAcceptedOnly() async throws {
        let f = try await Self.make()
        let other = try await Self.seedMixedRelationships(f)

        #expect(f.shellA.playAFriend())
        let screen = try #require(f.shellA.lobbyFriends, "the lobby opened with no friend list")
        await screen.load()

        // The rule. B is accepted; the other three are not, in all three ways
        // a relationship can fail to be one.
        #expect(Set(f.shellA.invitableFriends.map(\.profile.id)) == [f.b.id])

        // And the fixture really does hold one of each, so the line above is a
        // filter and not an empty list: a pending row is in another section,
        // and a blocked row is in none.
        #expect(screen.incoming.contains { $0.profile.id == other.incoming.id })
        #expect(screen.outgoing.contains { $0.profile.id == other.outgoing.id })
        let sectioned = screen.accepted + screen.incoming + screen.outgoing
        #expect(!sectioned.contains { $0.profile.id == other.blocked.id })
        let rows = try await f.backend.friendships()
        #expect(
            rows.contains { $0.status == .blocked && $0.other(than: f.a.id) == other.blocked.id },
            "the blocked row was never seeded, so its absence proves nothing")
        #expect(rows.filter { $0.status == .pending }.count == 2)

        f.shellA.returnToMenu()
        #expect(f.shellA.lobbyFriends == nil, "the next lobby would open on this list")
        #expect(f.shellA.invitableFriends.isEmpty)
    }

    @Test("The host invites from the open seat without leaving the lobby, and B gets the same banner")
    func invitingFromTheOpenSeat() async throws {
        let f = try await Self.make()
        // The row the friends list hands out — the same `FriendEntry` type the
        // picker holds, so both entry points are given identical input.
        let entry = try await Self.rowForB(f)
        f.shellA.returnToMenu()

        #expect(f.shellA.playAFriend())
        let lobby = try #require(f.shellA.hostLobby)
        // The reachability condition the source pin can only read as text,
        // asserted as a value: `hostActions` draws `openSeatRow` exactly when
        // `!lobby.canStart`, and a host waiting alone is that case. If this ever
        // came up true, the picker would be pinned in source and unreachable in
        // fact.
        #expect(lobby.canStart == false, "the seat the picker sits in was not open")
        // The picker's own predicate, by value: the `else` arm that draws the
        // `ForEach` is the one a waiting host reaches, not "No friends yet".
        // `.task` is what runs this load in the view.
        await f.shellA.lobbyFriends?.load()
        #expect(f.shellA.invitableFriends.isEmpty == false, "the picker would draw its empty arm")
        #expect(f.shellA.invitableFriends.contains { $0.profile.id == f.b.id })
        // `ShellRootView.body`'s predicate, by value: the launch screen is down
        // by the time any of this is on screen, so `routed` is what renders.
        f.shellA.finishLaunch()
        #expect(f.shellA.showsLaunchScreen == false)
        #expect(f.shellA.route == .hostLobby)
        #expect(f.shellA.invitePlayFromLobby(entry))

        await JoinTests.until("the invite left A") { f.bus.delivered == 1 }
        await JoinTests.until("B was bannered") { f.shellB.inviteBanner != nil }
        let banner = try #require(f.shellB.inviteBanner)
        #expect(banner.hostName == f.a.displayName)
        #expect(ShellModel.inviteLine(banner).contains(f.a.displayName))
        #expect(banner.inviteCode == lobby.inviteCode)
        #expect(banner.matchID == lobby.match?.record.id)
        #expect(f.shellB.inviteMessage == nil)

        // The whole point of the second entry point: the seat is still open
        // under the host, on the same lobby, and nothing routed away.
        #expect(f.shellA.route == .hostLobby)
        #expect(f.shellA.hostLobby === lobby)
        #expect(f.shellA.inviteMessage == nil)
        f.shellA.returnToMenu()
    }

    @Test("A pending row cannot be invited from the open seat, and the accepted one can")
    func openSeatRefusesAPendingRow() async throws {
        let pending = try await Self.make(accepted: false)
        let outgoing = try await Self.rowForB(pending, accepted: false)
        #expect(outgoing.friendship.status == .pending)
        pending.shellA.returnToMenu()

        #expect(pending.shellA.playAFriend())
        #expect(pending.shellA.invitePlayFromLobby(outgoing) == false)
        for _ in 0..<200 { await Task.yield() }
        #expect(pending.bus.delivered == 0, "a pending row sent an invite from the lobby")
        #expect(pending.shellA.route == .hostLobby, "a refusal must not close the lobby")
        pending.shellA.returnToMenu()

        // The twin, because `FakeInviteBus` withholds rather than buffers: the
        // same call on an accepted row over the same fixture does send.
        let f = try await Self.make()
        let entry = try await Self.rowForB(f)
        f.shellA.returnToMenu()
        #expect(f.shellA.playAFriend())
        #expect(f.shellA.invitePlayFromLobby(entry))
        await JoinTests.until("the accepted row sent one") { f.bus.delivered == 1 }
        f.shellA.returnToMenu()
    }

    @Test("The friends list keeps its own route guard, and the lobby entry point has its own")
    func eachEntryPointKeepsItsOwnRouteGuard() async throws {
        let f = try await Self.make()
        let entry = try await Self.rowForB(f)

        // On `.friends`: the friends-list call works and the lobby call does
        // not — the shared send carries neither guard.
        #expect(f.shellA.route == .friends)
        #expect(f.shellA.invitePlayFromLobby(entry) == false)
        #expect(f.shellA.hostLobby == nil)
        #expect(f.shellA.invitePlay(entry))
        await JoinTests.until("the friends-list path sent") { f.bus.delivered == 1 }

        // And on `.hostLobby` the pair swaps over.
        #expect(f.shellA.route == .hostLobby)
        #expect(f.shellA.invitePlay(entry) == false)
        #expect(f.shellA.invitePlayFromLobby(entry))
        await JoinTests.until("the lobby path sent") { f.bus.delivered == 2 }
        f.shellA.returnToMenu()
    }

    @Test("A send still in flight does not keep a cancelled lobby alive")
    func aParkedSendReleasesTheLobby() async throws {
        let parked = ParkedFailingChannel()
        let f = try await Self.make(hostChannel: { _ in parked })
        let entry = try await Self.rowForB(f)
        #expect(f.shellA.invitePlay(entry))
        await JoinTests.until("the send to park") { parked.isSending }

        weak var released = f.shellA.hostLobby
        #expect(released != nil, "there was no lobby to leak")
        // The player gives up while the send is parked, and a parked send
        // cannot be interrupted — so a strong `let lobby` inside that task is
        // what would keep the torn-down lobby alive past `teardown()`.
        f.shellA.returnToMenu()
        // Asserted WHILE the send is still parked, which is the only moment
        // that can tell the two captures apart: letting the task finish first
        // would drop even a strong capture and pass either way.
        for _ in 0..<400 { await Task.yield() }
        #expect(parked.isSending, "the send finished, so this proves nothing")
        #expect(released == nil, "the parked send outlived the lobby it belonged to")
        parked.release()
        for _ in 0..<200 { await Task.yield() }
    }

    /// The reach half of criterion 1, pinned to ONE invariant:
    ///
    ///   every declaration AND every predicate on the path from
    ///   `ShellRootView`'s route arm to `shell.invitePlayFromLobby` is either
    ///   inside one contiguous literal or asserted by value.
    ///
    /// `swift test` compiles neither `ShellRootView.swift` nor
    /// `TwoPlayerView.swift` — the `Shell` target excludes every SwiftUI file —
    /// so the declarations are pinned by reading source off disk, the
    /// `OrientationTests.rootViewWiring()` technique, normalized identically:
    /// trim each line, drop `//` lines, join with `\n`. One literal per whole
    /// declaration, never several independent `contains`: independent checks
    /// prove the strings exist in the file, not that a host reaches them.
    ///
    /// The predicates each link branches on are covered the other way, by
    /// value, in the behavioural tests above and below:
    ///   `shell.showsLaunchScreen == false` — `theWholeReachPathIsCovered`
    ///   `shell.route == .hostLobby`        — `invitingFromTheOpenSeat`
    ///   `shell.hostLobby != nil`           — `invitingFromTheOpenSeat`
    ///   `!lobby.canStart`                  — `invitingFromTheOpenSeat`
    ///   `!friends.isEmpty`                 — `invitingFromTheOpenSeat`
    ///   the Button's action                — `invitingFromTheOpenSeat`, `openSeatRefusesAPendingRow`
    /// `isHost` and `if case .host = mode` are `private` and take no runtime
    /// value a test can reach, so the literal is the only cover they can have —
    /// which is exactly why `isHost` needs one.
    ///
    /// Known ceiling, deliberate and not traded away: pinning whole
    /// declarations the length of the chain means any legitimate future edit
    /// anywhere on that path false-reds this test, and whoever makes it
    /// re-extends the literal. That is the price of pinning reachability
    /// instead of presence.
    @Test("Every link from the route arm to the picker is pinned")
    func openSeatRendersThePicker() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Cases
            .deletingLastPathComponent()  // ShellTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        func normalized(_ file: String) throws -> String {
            try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") }
                .joined(separator: "\n")
        }
        let root = try normalized("Willagrams/Shell/ShellRootView.swift")
        let two = try normalized("Willagrams/Shell/TwoPlayerView.swift")

        // Link: ShellRootView.body, whole.
        #expect(root.contains(#"""
var body: some View {
if shell.showsLaunchScreen {
LaunchView(shell: shell)
} else {
routed
}
}
"""#))

        // Link: ShellRootView.routed, whole.
        #expect(root.contains(#"""
private var routed: some View {
Group {
switch shell.route {
case .menu: MenuView(shell: shell)
case .soloSetup: SoloSetupView(shell: shell)
case .howToPlay: HowToPlayView(shell: shell)
case .hostLobby: hostLobby
case .join: joinScreen
case .profile: profileScreen
case .friends: friendsScreen
case .countdown: countdown
case .match: match
case .results: results
}
}
.frame(maxWidth: .infinity, maxHeight: .infinity)
.background(DesignTokens.Palette.canvasTop)
.overlay(alignment: .top) { inviteBanner }
.onChange(of: shell.route.isGameplay, initial: true) { _, isGameplay in
OrientationLock.mask = OrientationLock.mask(isGameplay: isGameplay)
let scene = UIApplication.shared.connectedScenes
.compactMap { $0 as? UIWindowScene }
.first { $0.activationState == .foregroundActive } ??
UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
scene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
scene?.requestGeometryUpdate(
.iOS(interfaceOrientations: OrientationLock.mask),
errorHandler: OrientationPolicy.report(rejection:)
)
}
}
"""#))

        // Link: ShellRootView.hostLobby, whole.
        #expect(root.contains(#"""
@ViewBuilder private var hostLobby: some View {
if let lobby = shell.hostLobby {
TwoPlayerView(shell: shell, mode: .host(lobby))
}
}
"""#))

        // Link: TwoPlayerView.isHost, whole.
        #expect(two.contains(#"""
private var isHost: Bool {
if case .host = mode { return true }
return false
}
"""#))

        // Link: TwoPlayerView.body, whole.
        #expect(two.contains(#"""
var body: some View {
VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
topBar

VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
Text(isHost ? HostLobbyModel.title : JoinModel.title)
.font(DesignTokens.Typography.title)
.foregroundStyle(DesignTokens.Palette.textPrimary)
Text(isHost ? Self.hostSubtitle : Self.joinSubtitle)
.font(DesignTokens.Typography.body)
.foregroundStyle(DesignTokens.Palette.textSecondary)
.fixedSize(horizontal: false, vertical: true)
}

chips

ScrollViewReader { proxy in
ScrollView {
VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
codeSection

if case .join(let join) = mode {
joinField(join).id(Self.codeFieldID)
joinStatus(join)
}

if isHost {
hostActions
}

if let message {
Text(message)
.font(DesignTokens.Typography.caption)
.foregroundStyle(DesignTokens.Palette.danger)
.fixedSize(horizontal: false, vertical: true)
}
}
.frame(maxWidth: .infinity, alignment: .leading)
}
.scrollDismissesKeyboard(.interactively)
.onChange(of: codeFieldFocused) { _, isFocused in
guard isFocused else { return }
withAnimation {
proxy.scrollTo(Self.codeFieldID, anchor: .center)
}
}
}

primaryButton
}
.frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
.frame(maxWidth: .infinity, maxHeight: .infinity)
.screenPadding()
.background { canvas }
}
"""#))

        // Link: TwoPlayerView.hostActions, whole.
        #expect(two.contains(#"""
@ViewBuilder private var hostActions: some View {
if case .host(let lobby) = mode {
VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
if let code = lobby.inviteCode {
HStack(spacing: DesignTokens.Space.m) {
Button(didCopyCode ? Self.copiedLabel : Self.copyLabel) {
ShellModel.pasteboard(code)
didCopyCode = true
}
.buttonStyle(.brandQuiet)
.frame(maxWidth: .infinity)

ShareLink(item: code) {
Label(Self.shareLabel, systemImage: "square.and.arrow.up")
}
.buttonStyle(.brandQuiet)
.frame(maxWidth: .infinity)
}
}

ForEach(Array(lobby.roster.enumerated()), id: \.offset) { _, name in
seatedRow(name)
}
if !lobby.canStart {
openSeatRow
}
}
}
}
"""#))

        // Link: TwoPlayerView.openSeatRow, whole.
        #expect(two.contains(#"""
private var openSeatRow: some View {
HStack(spacing: DesignTokens.Space.m) {
RoundedRectangle(cornerRadius: DesignTokens.Radius.tile, style: .continuous)
.strokeBorder(DesignTokens.Palette.hairline, style: StrokeStyle(lineWidth: DesignTokens.Stroke.hairline, dash: [4]))
.frame(width: Self.avatarSide, height: Self.avatarSide)

VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
Text(Self.openSeatLabel)
.font(DesignTokens.Typography.body)
.foregroundStyle(DesignTokens.Palette.textSecondary)
Text(Self.waitingLabel)
.font(DesignTokens.Typography.caption)
.foregroundStyle(DesignTokens.Palette.textSecondary)
}
Spacer(minLength: 0)
invitePicker
}
.padding(DesignTokens.Space.m)
.overlay {
RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
.strokeBorder(DesignTokens.Palette.hairline, style: StrokeStyle(lineWidth: DesignTokens.Stroke.hairline, dash: [4]))
}
}
"""#))

        // Link: TwoPlayerView.invitePicker, whole.
        #expect(two.contains(#"""
private var invitePicker: some View {
let friends = shell.invitableFriends
return Menu {
if friends.isEmpty {
Text(Self.noInvitableFriendsLabel)
} else {
ForEach(friends) { entry in
Button(entry.profile.displayName) {
shell.invitePlayFromLobby(entry)
}
}
}
} label: {
Text(Self.inviteLabel)
}
.buttonStyle(.brandQuiet)
.task { await shell.lobbyFriends?.load() }
}
"""#))
    }

}
