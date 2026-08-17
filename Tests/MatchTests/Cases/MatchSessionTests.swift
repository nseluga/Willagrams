import Foundation
import Testing
import WillagramsRules
@testable import Match

/// Smoke coverage for the client-side state machine: the countdown, the Draw
/// obligation, and the host taking its own tile from the pool it holds.
///
/// Every cross-device wait is a bounded poll, never an open `await` on a stream:
/// this suite runs unattended, so a message that never arrives has to fail in
/// two seconds rather than hang the run.
@MainActor
@Suite("Match session")
struct MatchSessionTests {

    /// Accepts every word, so a board of two adjacent tiles is complete
    /// whatever letters the pool happened to hand out.
    struct AnyWordList: WordList {
        func contains(_ word: String) -> Bool { true }
    }

    /// A countdown clock that costs no time and records what the session was
    /// showing at each tick.
    @MainActor
    final class CountdownProbe {
        var session: MatchSession?
        var seen: [MatchStatus] = []

        func tick() {
            if let status = session?.state.status { seen.append(status) }
        }
    }

    /// A transport whose `send` genuinely suspends, and which reports the most
    /// sends it ever had in flight at once.
    ///
    /// `FakeTransport.send` is one actor hop and does not really suspend, so it
    /// cannot show a serialisation bug. Two `HostPool.handle` calls running at
    /// once would overlap here and push the count to two.
    actor OverlapProbeTransport: MatchTransport {
        nonisolated let localPlayerID: PlayerID
        nonisolated let inboundMessages: AsyncStream<MatchMessage>
        nonisolated let peerConnectionStates = AsyncStream<PeerConnectionState> { $0.finish() }

        private nonisolated let inbound: AsyncStream<MatchMessage>.Continuation
        private var inFlight = 0
        private(set) var mostInFlight = 0
        private(set) var sent: [MatchMessage] = []

        init(localPlayerID: PlayerID) {
            let stream = AsyncStream.makeStream(of: MatchMessage.self, bufferingPolicy: .unbounded)
            self.localPlayerID = localPlayerID
            self.inboundMessages = stream.stream
            self.inbound = stream.continuation
        }

        nonisolated func deliver(_ message: MatchMessage) { inbound.yield(message) }

        func send(_ message: MatchMessage, delivery: MatchDelivery) async throws {
            inFlight += 1
            mostInFlight = max(mostInFlight, inFlight)
            try? await Task.sleep(for: .milliseconds(5))
            sent.append(message)
            inFlight -= 1
        }

        nonisolated func leave() { inbound.finish() }
    }

    static let deadline = Duration.seconds(2)

    /// Polls `condition` until it holds, failing fast if it never does.
    static func waitUntil(_ label: String, _ condition: @MainActor () -> Bool) async throws {
        let limit = ContinuousClock.now + deadline
        while !condition() {
            guard ContinuousClock.now < limit else {
                Issue.record("timed out waiting for \(label)")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Two sessions wired to each other, started and past their countdown.
    /// `host` is the one that owns the pool.
    static func startedPair(
        seed: UInt64 = 7
    ) async throws -> (host: MatchSession, guest: MatchSession) {
        let alice = PlayerID(rawValue: "alice")
        let bob = PlayerID(rawValue: "bob")
        let (first, second) = FakeTransport.pair(alice, bob)

        let one = MatchSession(transport: first, peerPlayerID: bob, dictionary: AnyWordList())
        let two = MatchSession(transport: second, peerPlayerID: alice, dictionary: AnyWordList())

        one.startMatch(seed: seed, startingHandSize: 21, countdownSeconds: 0, options: .standard)
        try await waitUntil("both sessions playing") {
            one.state.status == .playing && two.state.status == .playing
        }

        // Election is by id, not by who opened the match.
        let hostID = HostPool.host(of: alice, bob)
        return hostID == alice ? (one, two) : (two, one)
    }

    /// Draws a round and waits for both devices to be settled.
    ///
    /// A device under obligation takes the tile it owes first: while one is
    /// waiting, pressing Draw accepts it instead of asking for a round.
    static func drawRound(by drawer: MatchSession, other: MatchSession) async throws {
        if drawer.hasPendingDraw { drawer.draw() }
        let handBefore = drawer.state.hand.count
        let owedBefore = other.pendingDrawTiles.count + other.state.hand.count
        drawer.draw()
        try await waitUntil("both devices took a tile") {
            drawer.state.hand.count > handBefore
                && other.pendingDrawTiles.count + other.state.hand.count > owedBefore
        }
    }

    @Test("Start enters the countdown, ticks down locally, then plays")
    func countdownRunsFromReceipt() async throws {
        let probe = CountdownProbe()
        let (first, _) = FakeTransport.pair(PlayerID(rawValue: "alice"), PlayerID(rawValue: "bob"))
        let session = MatchSession(
            transport: first,
            peerPlayerID: PlayerID(rawValue: "bob"),
            dictionary: AnyWordList(),
            sleepFor: { _ in probe.tick() }
        )
        probe.session = session

        session.startMatch(seed: 1, startingHandSize: 21, countdownSeconds: 3, options: .standard)
        #expect(session.state.status == .countdown(secondsRemaining: 3))

        try await Self.waitUntil("the countdown to finish") { session.state.status == .playing }
        #expect(probe.seen == [
            .countdown(secondsRemaining: 3),
            .countdown(secondsRemaining: 2),
            .countdown(secondsRemaining: 1),
        ])
    }

    @Test("The host takes its own tile from the pool it holds, not from the wire")
    func hostAppliesItsOwnGrant() async throws {
        let (host, guest) = try await Self.startedPair()

        host.draw()
        try await Self.waitUntil("the host to hold a tile") { host.state.hand.count == 1 }
        try await Self.waitUntil("the guest to owe a tile") { guest.hasPendingDraw }

        #expect(host.pendingDrawTiles.isEmpty)
        #expect(guest.state.hand.isEmpty)
    }

    @Test("A tile waiting from the opponent's draw freezes the board until it is taken")
    func obligationFreezesTheBoard() async throws {
        let (host, guest) = try await Self.startedPair()

        // The guest asks for its own round first, so it has a tile to move.
        try await Self.drawRound(by: guest, other: host)
        let mine = try #require(guest.state.hand.first)
        #expect(guest.hasPendingDraw == false)

        // Now the host draws, which is what puts the guest under obligation.
        try await Self.drawRound(by: host, other: guest)
        #expect(guest.hasPendingDraw)

        #expect(throws: BoardActionError.drawPending) {
            try guest.place(tileID: mine.id, at: Coord(row: 0, col: 0))
        }
        #expect(guest.state.board.placementList.isEmpty)
        #expect(guest.state.hand.map(\.id) == [mine.id])

        #expect(throws: BoardActionError.drawPending) {
            try guest.recall(from: Coord(row: 0, col: 0))
        }

        // Pressing Draw takes the waiting tile and unfreezes the board.
        guest.draw()
        #expect(guest.hasPendingDraw == false)
        #expect(guest.state.hand.count == 2)
        try guest.place(tileID: mine.id, at: Coord(row: 0, col: 0))
        #expect(guest.state.board.tile(at: Coord(row: 0, col: 0))?.id == mine.id)
    }

    @Test("canDraw is the frozen predicate over this session's own state")
    func canDrawDelegatesToTheRules() async throws {
        let (host, guest) = try await Self.startedPair()

        try await Self.drawRound(by: guest, other: host)
        try await Self.drawRound(by: guest, other: host)
        #expect(guest.state.hand.count == 2)

        // A tile still in hand: never allowed, whatever the board looks like.
        #expect(guest.canDraw == false)
        #expect(guest.canDraw == guest.state.canDraw(against: AnyWordList()))

        let tiles = guest.state.hand
        try guest.place(tileID: tiles[0].id, at: Coord(row: 0, col: 0))
        #expect(guest.canDraw == false)

        try guest.place(tileID: tiles[1].id, at: Coord(row: 0, col: 1))
        #expect(guest.state.hand.isEmpty)
        #expect(guest.canDraw)
        #expect(guest.canDraw == guest.state.canDraw(against: AnyWordList()))
    }

    @Test("Requests arriving together reach the pool one at a time")
    func poolWorkIsSerialised() async throws {
        let alice = PlayerID(rawValue: "alice")
        let bob = PlayerID(rawValue: "bob")
        let probe = OverlapProbeTransport(localPlayerID: alice)
        let host = MatchSession(transport: probe, peerPlayerID: bob, dictionary: AnyWordList())

        host.startMatch(seed: 3, startingHandSize: 21, countdownSeconds: 0, options: .standard)
        #expect(host.state.status == .playing)

        let rounds = 8
        for _ in 0..<rounds {
            probe.deliver(.drawRequest(player: bob))
        }

        try await Self.waitUntil("every round to be answered") {
            host.pendingDrawTiles.count == rounds
        }
        let sent = await probe.sent
        let mostInFlight = await probe.mostInFlight

        #expect(mostInFlight == 1)
        // The start, then one grant per round to the peer. The grant addressed
        // to the host never travels.
        #expect(sent.count == rounds + 1)
    }

    @Test("A start on an unknown wire version is ignored rather than trusted")
    func badStartIsIgnored() async throws {
        let (first, second) = FakeTransport.pair(PlayerID(rawValue: "alice"), PlayerID(rawValue: "bob"))
        let guest = MatchSession(
            transport: second,
            peerPlayerID: PlayerID(rawValue: "alice"),
            dictionary: AnyWordList()
        )

        try await first.send(
            .start(version: WireFormat.current + 1, seed: 1, startingHandSize: 21, countdownSeconds: 0, options: .standard),
            delivery: .reliable
        )
        try await Self.waitUntil("the session to note the bad version") { guest.lastNote != nil }
        #expect(guest.state.status == .countdown(secondsRemaining: 0))

        // A good start afterwards is still accepted.
        try await first.send(
            .start(version: WireFormat.current, seed: 1, startingHandSize: 21, countdownSeconds: 0, options: .standard),
            delivery: .reliable
        )
        try await Self.waitUntil("the good start to land") { guest.state.status == .playing }
    }

    @Test("An exhausted pool latches without ending the match, and a late grant still lands")
    func exhaustionIsALatchNotAnEnd() async throws {
        let (first, second) = FakeTransport.pair(PlayerID(rawValue: "alice"), PlayerID(rawValue: "bob"))
        let guest = MatchSession(
            transport: second,
            peerPlayerID: PlayerID(rawValue: "alice"),
            dictionary: AnyWordList()
        )
        try await first.send(
            .start(version: WireFormat.current, seed: 1, startingHandSize: 21, countdownSeconds: 0, options: .standard),
            delivery: .reliable
        )
        try await Self.waitUntil("the guest to start playing") { guest.state.status == .playing }

        try await first.send(.poolExhausted, delivery: .reliable)
        try await Self.waitUntil("the exhaustion latch") { guest.poolIsExhausted }
        #expect(guest.state.status == .playing)

        // Reordered behind the latch. It is still this device's tile.
        let late = Tile(letter: "Q")
        try await first.send(
            .grant(player: PlayerID(rawValue: "bob"), tiles: [late]),
            delivery: .reliable
        )
        try await Self.waitUntil("the late grant") { guest.hasPendingDraw }
        #expect(guest.pendingDrawTiles.map(\.id) == [late.id])
    }
}
