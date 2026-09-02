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
        swapEnabled: false,
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

    static func fixture(creatorToken: String, guestToken: String) async throws -> Fixture {
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
            sleepFor: { _ in }
        )

        _ = try await backend.signInWithApple(idToken: guestToken, nonce: "n")
        let guest = try await OnlineMatch.join(
            code: creator.inviteCode,
            backend: backend,
            dictionary: EnableWordList(words: []),
            outcomeStore: guestStore,
            sleepFor: { _ in }
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

    @Test("The creator that is not roster[0] defers rather than opening the match")
    func theCreatorNeverAssumesItHostsThePool() async throws {
        // "C" sorts above "B": the creator is the *second* element of the
        // roster, so the frozen rule hands the pool — and the start — to the
        // guest.
        let f = try await Self.fixture(creatorToken: "C", guestToken: "B")
        #expect(f.guestPlayer.rawValue < f.creatorPlayer.rawValue)
        #expect(f.creator.record.hostID.uuidString == f.creatorPlayer.rawValue)

        f.creatorWire.announce(.connected(f.guestPlayer))
        await Self.until("the creator sees the guest") { f.creator.lobby.count == 2 }

        await #expect(throws: OnlineMatchError.notPoolHost) {
            _ = try await f.creator.start()
        }

        #expect(f.creatorWire.sent.isEmpty, "the creator opened a match it does not host")
        #expect(f.creatorStore.calls.isEmpty)
        let row = await f.backend.matchRecord(f.creator.record.id)
        #expect(row?.status == .lobby, "a refused start moved the matches row off lobby")
    }

    // MARK: - Opening the match

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

    @Test("Both devices reach playing with the same roster and the same options")
    func bothDevicesReachPlaying() async throws {
        let f = try await Self.fixture(creatorToken: "A", guestToken: "B")
        f.creatorWire.announce(.connected(f.guestPlayer))
        f.guestWire.announce(.connected(f.creatorPlayer))
        await Self.until("two in the creator's lobby") { f.creator.lobby.count == 2 }
        await Self.until("two in the guest's lobby") { f.guest.lobby.count == 2 }

        let guestSession = try await f.guest.awaitStart()
        let creatorSession = try await f.creator.start()

        await Self.until("the creator is playing") { creatorSession.state.status == .playing }
        await Self.until("the guest is playing") { guestSession.state.status == .playing }

        let expected = [f.creatorPlayer, f.guestPlayer].sorted { $0.rawValue < $1.rawValue }
        #expect(creatorSession.roster == expected)
        #expect(guestSession.roster == expected)
        #expect(creatorSession.roster == guestSession.roster)
        #expect(creatorSession.options == Self.options)
        #expect(guestSession.options == Self.options)
        #expect(creatorSession.startingHandSize == 21)
        #expect(guestSession.startingHandSize == 21)
        // The seed both sides played is the one that travelled, which is the
        // row's. Nothing else on either device could have supplied it.
        #expect(f.guestWire.received.contains { message in
            guard case let .start(_, seed, _, _, _, _) = message else { return false }
            return seed == f.creator.record.poolSeed
        })

        // Same seed, same deal: two devices that disagreed about the seed would
        // hold different opening hands off the same host pool.
        await Self.until("the creator is dealt in") { !creatorSession.state.hand.isEmpty }
        await Self.until("the guest is dealt in") { !guestSession.state.hand.isEmpty }
        #expect(creatorSession.state.hand.count == 21)
        #expect(guestSession.state.hand.count == 21)
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

    @Test("The roster sort is one function, ascending by rawValue")
    func rosterSortsAscending() {
        let unsorted = [
            PlayerID(rawValue: "FF"), PlayerID(rawValue: "0A"), PlayerID(rawValue: "B0"),
        ]
        #expect(OnlineMatch.roster(from: unsorted).map(\.rawValue) == ["0A", "B0", "FF"])
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
        case updateProfile(UUID)
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

    func updateProfile(_ id: UUID, _ stats: ProfileStats) async throws {
        lock.withLock { storedCalls.append(.updateProfile(id)) }
    }
}
