import Foundation
import Testing
import WillagramsRules
@testable import Online

/// Everything the façade decides on its own: the roster it builds, who it
/// defers to, what it refuses, and what it puts on the wire.
///
/// None of this needs a project. The half that does — two real devices on a
/// real channel — is `OnlineMatchLiveTests`, and it is deliberately the smaller
/// half: a rule that can be decided with no network should never be waiting on
/// one to be checked.
@MainActor
@Suite("Online match façade, offline")
struct OnlineMatchOfflineTests {

    /// Deliberately not `.standard`: options that only ever carry the default
    /// prove nothing about whether they travelled. The hash stays standard so
    /// the session's word-list check still passes — that rule is the match
    /// lane's, and this suite is not the place to fight it.
    static let options = MatchOptions(
        minimumWordLength: 5,
        swapEnabled: true,
        dictionaryID: "standard",
        dictionaryHash: MatchOptions.standardDictionaryHash
    )

    // MARK: - Fixture

    /// Two façades over one fake backend and one paired spy channel.
    ///
    /// `creatorToken` and `guestToken` pick the two player ids: `FakeBackend`
    /// derives a stable UUID from the token's bytes, so `"A"` sorts below `"B"`
    /// and `"C"` sorts above it. That is the whole reason the tokens are
    /// spelled out at every call site — which of the two is `roster[0]` is the
    /// thing under test, not an incidental.
    struct Fixture {
        let backend: FakeBackend
        let creatorPlayer: PlayerID
        let guestPlayer: PlayerID
        let creatorWire: SpyTransport
        let guestWire: SpyTransport
        let creatorStore: SpyOutcomeStore
        let guestStore: SpyOutcomeStore
        let creator: OnlineMatch
        let guest: OnlineMatch
    }

    /// - Parameter sleepFor: the clock both façades hand their sessions.
    ///   Defaults to a no-op, which is what every case in this suite wants: no
    ///   test here is waiting on time. A case that needs a reconnect window to
    ///   still be *open* when it looks passes one that does not return.
    static func fixture(
        creatorToken: String,
        guestToken: String,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = { _ in }
    ) async throws -> Fixture {
        let backend = FakeBackend()
        let creatorPlayer = try await backend.signInWithApple(idToken: creatorToken, nonce: "n").playerID
        let guestPlayer = try await backend.signInWithApple(idToken: guestToken, nonce: "n").playerID
        #expect(creatorPlayer != guestPlayer)

        let (creatorWire, guestWire) = SpyTransport.pair(creatorPlayer, guestPlayer)
        await backend.setTransportFactory { _, player in
            player == creatorPlayer ? creatorWire : guestWire
        }

        let creatorStore = SpyOutcomeStore()
        let guestStore = SpyOutcomeStore()

        _ = try await backend.signInWithApple(idToken: creatorToken, nonce: "n")
        let creator = try await OnlineMatch.host(
            options: options,
            backend: backend,
            dictionary: EnableWordList(words: []),
            outcomeStore: creatorStore,
            sleepFor: sleepFor
        )

        _ = try await backend.signInWithApple(idToken: guestToken, nonce: "n")
        let guest = try await OnlineMatch.join(
            code: creator.inviteCode,
            backend: backend,
            dictionary: EnableWordList(words: []),
            outcomeStore: guestStore,
            sleepFor: sleepFor
        )

        return Fixture(
            backend: backend,
            creatorPlayer: creatorPlayer,
            guestPlayer: guestPlayer,
            creatorWire: creatorWire,
            guestWire: guestWire,
            creatorStore: creatorStore,
            guestStore: guestStore,
            creator: creator,
            guest: guest
        )
    }

    /// Yields until `condition` holds, or records a failure.
    ///
    /// The bound is a count of scheduler turns, not a wall-clock window: every
    /// clock in this suite is injected as a no-op, so nothing here is waiting
    /// on time and a deadline expressed in seconds would be a number with no
    /// meaning. A test that needs more than this many turns is not slow, it is
    /// wrong.
    static func until(_ label: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 5_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("timed out waiting for: \(label)")
    }

    // MARK: - The lobby

    @Test("The local player is in the lobby before anyone else connects")
    func lobbyAlwaysHoldsTheLocalPlayer() async throws {
        let f = try await Self.fixture(creatorToken: "A", guestToken: "B")
        #expect(f.creator.lobby == [f.creatorPlayer])
        #expect(f.guest.lobby == [f.guestPlayer])
    }

    @Test("The lobby follows the transport's presence, and never drops the local player")
    func lobbyTracksPeerConnectionStates() async throws {
        let f = try await Self.fixture(creatorToken: "A", guestToken: "B")

        f.creatorWire.announce(.connected(f.guestPlayer))
        await Self.until("the creator sees the guest") { f.creator.lobby.count == 2 }
        #expect(Set(f.creator.lobby) == [f.creatorPlayer, f.guestPlayer])
        #expect(f.creator.lobby.first == f.creatorPlayer)

        // A repeat of the same state must not list the same player twice.
        f.creatorWire.announce(.connected(f.guestPlayer))
        f.guestWire.announce(.connected(f.creatorPlayer))
        await Self.until("the guest sees the creator") { f.guest.lobby.count == 2 }
        #expect(f.creator.lobby.count == 2)

        f.creatorWire.announce(.disconnected(f.guestPlayer))
        await Self.until("the creator sees the guest go") { f.creator.lobby.count == 1 }
        #expect(f.creator.lobby == [f.creatorPlayer])

        // The local player is not removable from their own lobby.
        f.creatorWire.announce(.disconnected(f.creatorPlayer))
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(f.creator.lobby == [f.creatorPlayer])
    }

    // MARK: - Refusing to start

    @Test("start() with nobody else in the lobby throws, writes nothing and sends nothing")
    func startRefusesAnEmptyLobby() async throws {
        let f = try await Self.fixture(creatorToken: "A", guestToken: "B")

        await #expect(throws: OnlineMatchError.lobbyNotReady(1)) {
            _ = try await f.creator.start()
        }

        #expect(f.creatorWire.sent.isEmpty, "a refused start put a message on the channel")
        #expect(f.creatorStore.calls.isEmpty, "a refused start wrote to the database")
        #expect(f.creator.recorder == nil)
        let row = await f.backend.matchRecord(f.creator.record.id)
        #expect(row?.status == .lobby, "a refused start moved the matches row off lobby")
    }

    @Test("start() with a third player in the lobby throws, writes nothing and sends nothing")
    func startRefusesAnOversizedLobby() async throws {
        let f = try await Self.fixture(creatorToken: "A", guestToken: "B")
        // A third id *above* both of the others, so a roster that got through
        // would be legal for `MatchSession` and this device would still be
        // `roster[0]` — the count refusal has to be the thing that stops it,
        // not the host rule standing in for it.
        f.creatorWire.announce(.connected(f.guestPlayer))
        f.creatorWire.announce(.connected(PlayerID(rawValue: "FF000000-0000-0000-0000-000000000001")))
        await Self.until("three in the lobby") { f.creator.lobby.count == 3 }

        await #expect(throws: OnlineMatchError.lobbyNotReady(3)) {
            _ = try await f.creator.start()
        }

        #expect(f.creatorWire.sent.isEmpty, "a refused start put a message on the channel")
        #expect(f.creatorStore.calls.isEmpty, "a refused start wrote to the database")
        let row = await f.backend.matchRecord(f.creator.record.id)
        #expect(row?.status == .lobby, "a refused start moved the matches row off lobby")
    }

    // MARK: - Opening the match, from whichever side the roster elects

    /// Drives one whole pairing to `.playing` and reports what each endpoint put
    /// on the wire.
    ///
    /// Both direction cases run through this, so "exactly one `.start` crosses
    /// the channel" is asserted the same way for each — two openers racing is
    /// precisely the failure the roster rule exists to prevent.
    static func playThrough(
        creatorToken: String,
        guestToken: String
    ) async throws -> (f: Fixture, creatorSession: MatchSession, guestSession: MatchSession) {
        let f = try await fixture(creatorToken: creatorToken, guestToken: guestToken)
        f.creatorWire.announce(.connected(f.guestPlayer))
        f.guestWire.announce(.connected(f.creatorPlayer))
        await until("two in the creator's lobby") { f.creator.lobby.count == 2 }
        await until("two in the guest's lobby") { f.guest.lobby.count == 2 }

        let guestSession = try await f.guest.awaitStart()
        let creatorSession = try await f.creator.start()

        await until("the creator is playing") { creatorSession.state.status == .playing }
        await until("the guest is playing") { guestSession.state.status == .playing }
        return (f, creatorSession, guestSession)
    }

    /// Everything both devices must agree about, whoever opened the match.
    static func expectAgreement(
        _ f: Fixture,
        _ creatorSession: MatchSession,
        _ guestSession: MatchSession
    ) async {
        let expected = [f.creatorPlayer, f.guestPlayer].sorted { $0.rawValue < $1.rawValue }
        #expect(creatorSession.roster == expected)
        #expect(guestSession.roster == expected)
        #expect(creatorSession.options == Self.options)
        #expect(guestSession.options == Self.options)
        #expect(creatorSession.startingHandSize == 21)
        #expect(guestSession.startingHandSize == 21)

        // Exactly one `.start`, and it carries the row's seed. Counted on both
        // endpoints: a second opener would show up as a start from the other
        // side, not as a missing one.
        let sent = starts(f.creatorWire.sent) + starts(f.guestWire.sent)
        #expect(sent.count == 1, "the roster elected \(sent.count) openers")
        guard case let .start(version, seed, handSize, countdown, options, roster) = sent[0] else {
            Issue.record("no start crossed the channel")
            return
        }
        #expect(version == WireFormat.current)
        #expect(seed == f.creator.record.poolSeed)
        #expect(handSize == 21)
        #expect(countdown == 3)
        #expect(options == Self.options)
        #expect(roster == expected)

        await until("the creator is dealt in") { creatorSession.state.hand.count == 21 }
        await until("the guest is dealt in") { guestSession.state.hand.count == 21 }
    }

    static func starts(_ messages: [MatchMessage]) -> [MatchMessage] {
        messages.filter { if case .start = $0 { true } else { false } }
    }

    @Test("The creator that sorts first opens the match, and only it sends a start")
    func theCreatorOpensWhenItIsRosterZero() async throws {
        // "A" sorts below "B": the creator is `roster[0]`.
        let (f, creatorSession, guestSession) = try await Self.playThrough(
            creatorToken: "A", guestToken: "B")
        #expect(f.creatorPlayer.rawValue < f.guestPlayer.rawValue)
        await Self.expectAgreement(f, creatorSession, guestSession)
        #expect(Self.starts(f.creatorWire.sent).count == 1)
        #expect(Self.starts(f.guestWire.sent).isEmpty)
        // The receiving side never attempted an open.
        #expect(guestSession.lastNote == nil)
    }

    @Test("The creator opens even when the guest sorts first, and the guest never opens itself")
    func onlyTheCreatorOpensWhenTheGuestIsRosterZero() async throws {
        // "C" sorts above "B": the *guest* is `roster[0]` and holds the pool,
        // but only the creator's Start opens the match.
        let f = try await Self.fixture(creatorToken: "C", guestToken: "B")
        #expect(f.guestPlayer.rawValue < f.creatorPlayer.rawValue)
        f.creatorWire.announce(.connected(f.guestPlayer))
        f.guestWire.announce(.connected(f.creatorPlayer))
        await Self.until("two in the creator's lobby") { f.creator.lobby.count == 2 }

        let guestSession = try await f.guest.awaitStart()
        // Still waiting: an auto-open would have applied a 21-tile start here.
        #expect(guestSession.startingHandSize == 0, "awaitStart() opened the match itself")
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(Self.starts(f.guestWire.sent).isEmpty, "the guest sent a start")
        #expect(guestSession.state.status != .playing)

        let creatorSession = try await f.creator.start()
        await Self.until("the creator is playing") { creatorSession.state.status == .playing }
        await Self.until("the guest is playing") { guestSession.state.status == .playing }
        await Self.expectAgreement(f, creatorSession, guestSession)
        #expect(Self.starts(f.creatorWire.sent).count == 1)
        #expect(Self.starts(f.guestWire.sent).isEmpty)
        // The pool authority is still `roster[0]` — the guest here.
        #expect(guestSession.poolRemaining != nil, "roster[0] does not hold the pool")
        #expect(creatorSession.poolRemaining == nil)
    }

    @Test("The start message carries the row's seed and this file's two constants")
    func theStartMessageCarriesTheRowsSeed() async throws {
        let f = try await Self.fixture(creatorToken: "A", guestToken: "B")
        f.creatorWire.announce(.connected(f.guestPlayer))
        await Self.until("two in the lobby") { f.creator.lobby.count == 2 }

        _ = try await f.creator.start()

        // `MatchSession` sends off a serial tail task, so the message reaches
        // the wire a turn or two after `start()` returns.
        await Self.until("the start reaches the wire") { !f.creatorWire.sent.isEmpty }

        let roster = [f.creatorPlayer, f.guestPlayer].sorted { $0.rawValue < $1.rawValue }
        let starts = f.creatorWire.sent.filter { if case .start = $0 { true } else { false } }
        #expect(starts.count == 1)
        #expect(starts.first == .start(
            version: WireFormat.current,
            seed: f.creator.record.poolSeed,
            startingHandSize: 21,
            countdownSeconds: 3,
            options: Self.options,
            roster: roster
        ))
        // The row's seed, not a second draw: `poolSeed` is the widening of the
        // `bigint` the backend stored, and nothing else in this process holds it.
        #expect(f.creator.record.poolSeed == UInt64(f.creator.record.seed))
        #expect(f.creator.record.seed >= 0)
    }

    // MARK: - The guest's roster

    @Test("awaitStart() sorts the membership rows rather than trusting join order")
    func awaitStartSortsTheMembershipRows() async throws {
        // Join order is creator then guest; sorted order is the reverse.
        let f = try await Self.fixture(creatorToken: "C", guestToken: "B")
        let rows = try await f.backend.players(inMatch: f.creator.record.id)
        #expect(rows.map(\.playerID.uuidString) == [f.creatorPlayer.rawValue, f.guestPlayer.rawValue])

        let session = try await f.guest.awaitStart()
        #expect(session.roster == [f.guestPlayer, f.creatorPlayer])
        #expect(session.roster == session.roster.sorted { $0.rawValue < $1.rawValue })
    }

    /// The host's gear writes a hand size and a swap setting the `matches` row
    /// knows nothing about — the row was written before the sheet existed. The
    /// only thing that can carry them is `.start`, so this asserts the guest's
    /// session against what the host chose and not against the row.
    ///
    /// Every number here is spelled out. Reading `handSize` back off the model
    /// that was just told it would pass with the wire carrying anything at all.
    @Test("The host's chosen hand size and options are what the guest plays under")
    func theHostsChosenSettingsTravel() async throws {
        let f = try await Self.fixture(creatorToken: "A", guestToken: "B")
        // The row was written with `Self.options` — minimum length 5, swap on.
        // The host chooses 4 and swap off below, so a guest reading the row
        // rather than the start comes out at 5 with swap on, and this fails.
        #expect(f.guest.record.options.minimumWordLength == 5)
        #expect(f.guest.record.options.swapEnabled)
        f.creatorWire.announce(.connected(f.guestPlayer))
        f.guestWire.announce(.connected(f.creatorPlayer))
        await Self.until("two in the creator's lobby") { f.creator.lobby.count == 2 }

        let guestSession = try await f.guest.awaitStart()

        let chosen = MatchOptions(
            minimumWordLength: 4,
            swapEnabled: false,
            dictionaryID: "standard",
            dictionaryHash: MatchOptions.standardDictionaryHash
        )
        let creatorSession = try await f.creator.start(handSize: 10, options: chosen)

        await Self.until("the guest is playing") { guestSession.state.status == .playing }
        await Self.until("the creator is playing") { creatorSession.state.status == .playing }

        #expect(guestSession.startingHandSize == 10)
        #expect(creatorSession.startingHandSize == 10)
        #expect(guestSession.options.swapEnabled == false)
        #expect(guestSession.options.minimumWordLength == 4)

        await Self.until("both racks hold ten") {
            guestSession.state.hand.count == 10 && creatorSession.state.hand.count == 10
        }
        #expect(guestSession.state.hand.count == 10)
        #expect(creatorSession.state.hand.count == 10)
    }

    @Test("The roster sort is one function, ascending by rawValue")
    func rosterSortsAscending() {
        let unsorted = [
            PlayerID(rawValue: "FF"), PlayerID(rawValue: "0A"), PlayerID(rawValue: "B0"),
        ]
        #expect(OnlineMatch.roster(from: unsorted).map(\.rawValue) == ["0A", "B0", "FF"])
    }

    // MARK: - Abandoning the lobby

    /// A lobby the host walks out of has to close its `matches` row, and the
    /// write that closes it is fire-and-forget — nobody is left to notice it
    /// fail. One dropped packet used to leave the row reading `lobby` for good,
    /// silently, because the call was made with `try?` and nothing else.
    @Test("A failed abandon is retried, not discarded")
    func abandonRetriesUntilItLands() async throws {
        let f = try await Self.fixture(creatorToken: "A", guestToken: "B")
        let id = f.creator.record.id
        _ = try await f.backend.signInWithApple(idToken: "A", nonce: "n")
        await f.backend.failNextAbandons(OnlineMatch.abandonAttempts - 1)

        f.creator.leave()
        await f.creator.awaitAbandon()

        #expect(f.creator.abandonSucceeded == true)
        #expect(await f.backend.abandonAttemptCount == OnlineMatch.abandonAttempts)
        #expect(await f.backend.matchRecord(id)?.status == .abandoned)
    }

    /// The positive twin of the retry: when every attempt fails the façade must
    /// say so rather than report a clean exit. `abandonSucceeded == false` is
    /// what separates "the row is stale" from "there was never a row".
    @Test("An abandon that never lands is reported, not reported as success")
    func abandonGivesUpAndSaysSo() async throws {
        let f = try await Self.fixture(creatorToken: "A", guestToken: "B")
        let id = f.creator.record.id
        _ = try await f.backend.signInWithApple(idToken: "A", nonce: "n")
        await f.backend.failNextAbandons(OnlineMatch.abandonAttempts + 5)

        f.creator.leave()
        await f.creator.awaitAbandon()

        #expect(f.creator.abandonSucceeded == false)
        #expect(await f.backend.abandonAttemptCount == OnlineMatch.abandonAttempts)
        #expect(await f.backend.matchRecord(id)?.status == .lobby)
    }

    /// The retry outlives the façade. `ShellModel.returnToMenu()` drops the
    /// match model the frame after `leave()`, so a `deinit` that cancelled the
    /// abandon would kill it in the common case, not the rare one.
    @Test("The façade does not cancel its own abandon when it is torn down")
    func abandonSurvivesTeardown() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Willagrams/Online/OnlineMatch.swift"),
            encoding: .utf8
        )
        guard let deinitStart = source.range(of: "    deinit {"),
              let deinitEnd = source.range(
                  of: "\n    }", range: deinitStart.upperBound ..< source.endIndex)
        else {
            Issue.record("OnlineMatch no longer has a deinit to scope this scan to")
            return
        }
        let body = String(source[deinitStart.upperBound ..< deinitEnd.lowerBound])
        // Falsifiable: the scope is real only if the cancels that *should* be
        // there are found in it.
        #expect(body.contains("presencePump?.cancel()"))
        #expect(body.contains("recorderTask?.cancel()"))
        let live = body.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(!live.contains { $0.contains("abandonTask?.cancel()") },
            "deinit cancels the abandon, so tearing the screen down drops the write")
    }

    // MARK: - The two constants

    @Test("The hand size and countdown are one constant each, never a literal at a call site")
    func handSizeAndCountdownComeFromOnePlace() throws {
        #expect(OnlineMatch.startingHandSize == 21)
        #expect(OnlineMatch.countdownSeconds == 3)

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // Cases
                .deletingLastPathComponent()   // OnlineTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // repo root
                .appendingPathComponent("Willagrams/Online/OnlineMatch.swift"),
            encoding: .utf8
        )
        // One definition each, and no second literal anywhere near a call site.
        #expect(source.components(separatedBy: "startingHandSize = 21").count == 2)
        #expect(source.components(separatedBy: "countdownSeconds = 3").count == 2)
        #expect(!source.contains("startingHandSize: 21"))
        #expect(!source.contains("countdownSeconds: 3"))
        // And SDK-free, the lane rule this file also has to hold.
        for sdk in ["import Auth", "import PostgREST", "import Realtime", "import Supabase"] {
            #expect(!source.contains(sdk), "OnlineMatch.swift imports the SDK: \(sdk)")
        }
    }
}

// MARK: - Doubles

/// A `MatchTransport` that records what was sent and lets the test say when a
/// peer appeared.
///
/// `FakeBackend.transport(for:as:)` builds a `FakeTransport.pair` and throws the
/// far end away, so nothing sent through it can be counted and no presence can
/// be staged — which is exactly what the two rules under test need. Hence this,
/// injected through `FakeBackend.setTransportFactory`.
final class SpyTransport: MatchTransport, @unchecked Sendable {

    let localPlayerID: PlayerID
    let inboundMessages: AsyncStream<MatchMessage>
    let peerConnectionStates: AsyncStream<PeerConnectionState>

    private let inbound: AsyncStream<MatchMessage>.Continuation
    private let states: AsyncStream<PeerConnectionState>.Continuation
    private let lock = NSLock()
    private var storedSent: [MatchMessage] = []
    private var storedReceived: [MatchMessage] = []
    private var peer: SpyTransport?

    /// Everything this endpoint put on the wire, in order.
    var sent: [MatchMessage] { lock.withLock { storedSent } }
    /// Everything the peer handed this endpoint.
    var received: [MatchMessage] { lock.withLock { storedReceived } }

    private init(_ player: PlayerID) {
        localPlayerID = player
        let messages = AsyncStream.makeStream(of: MatchMessage.self, bufferingPolicy: .unbounded)
        let presence = AsyncStream.makeStream(of: PeerConnectionState.self, bufferingPolicy: .unbounded)
        inboundMessages = messages.stream
        inbound = messages.continuation
        peerConnectionStates = presence.stream
        states = presence.continuation
    }

    /// Two endpoints wired to each other, neither of them connected yet —
    /// presence is staged by the test with ``announce(_:)``.
    static func pair(_ first: PlayerID, _ second: PlayerID) -> (SpyTransport, SpyTransport) {
        let a = SpyTransport(first)
        let b = SpyTransport(second)
        a.peer = b
        b.peer = a
        return (a, b)
    }

    /// Puts one connection-state change on this endpoint's presence stream.
    func announce(_ state: PeerConnectionState) { states.yield(state) }

    func send(_ message: MatchMessage, delivery: MatchDelivery) async throws {
        lock.withLock { storedSent.append(message) }
        guard let peer else { throw MatchTransportError.peerDisconnected }
        peer.lock.withLock { peer.storedReceived.append(message) }
        peer.inbound.yield(message)
    }

    func leave() {
        inbound.finish()
        states.finish()
    }
}

/// A `MatchOutcomeStore` that writes nothing and remembers every call.
///
/// "A refused start writes nothing" is only decidable against a double that can
/// say it was never asked.
final class SpyOutcomeStore: MatchOutcomeStore, @unchecked Sendable {

    enum Call: Equatable {
        case updateMatch(UUID, MatchOutcomeUpdate)
        case readProfile(UUID)
        case recordOutcome(UUID)
    }

    private let lock = NSLock()
    private var storedCalls: [Call] = []
    var calls: [Call] { lock.withLock { storedCalls } }

    func updateMatch(_ id: UUID, _ update: MatchOutcomeUpdate) async throws {
        lock.withLock { storedCalls.append(.updateMatch(id, update)) }
    }

    func profile(_ id: UUID) async throws -> Profile {
        lock.withLock { storedCalls.append(.readProfile(id)) }
        return Profile(
            id: id, displayName: "spy", friendCode: "AAAAAAAA",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    @discardableResult
    func recordOutcome(
        _ id: UUID, won: Bool, tilesPlaced: Int, elapsedSeconds: Int?
    ) async throws -> Profile {
        lock.withLock { storedCalls.append(.recordOutcome(id)) }
        return Profile(
            id: id, displayName: "spy", friendCode: "AAAAAAAA",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
