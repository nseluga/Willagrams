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
    static func make(accepted: Bool = true) async throws -> Two {
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
                inviteChannel: bus.factory
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
}
