import Foundation
import Testing
import WillagramsRules
@testable import Match

/// The three ways a match ends: somebody wins, somebody gives up, or the peer
/// goes away and does not come back.
///
/// Three of the four criteria here are negative — nothing is sent, nothing
/// moves, nobody wins — so each one drives the real entry points the shell
/// drives and reads what the transport actually received, rather than
/// re-deriving the property from anything inside the session.
///
/// Time is the injected clock in every test that needs any: a real thirty-second
/// window parked at process exit takes the test helper down with it, and this
/// suite runs unattended. Every cross-device wait races a deadline and throws,
/// so a message that never arrives fails in seconds instead of hanging the run.
@MainActor
@Suite("Match session terminal states")
struct MatchSessionTerminalTests {

    // MARK: - Fixtures

    static let alice = PlayerID(rawValue: "alice")
    static let bob = PlayerID(rawValue: "bob")

    struct EveryWordIsReal: WordList {
        func contains(_ word: String) -> Bool { true }
    }

    struct WaitExpired: Error, CustomStringConvertible {
        let label: String
        var description: String { "timed out waiting for \(label)" }
    }

    /// A transport whose connection-state stream the test drives by hand.
    ///
    /// `FakeTransport.leave()` is the real drop-out hook and is used for that in
    /// this file, but it finishes both streams on both endpoints, so nothing can
    /// arrive after it — no peer coming back, and no message that was already in
    /// the buffer when the peer went. This one keeps both streams open, which is
    /// what a real match does: `GKMatch` reports a peer as disconnected and
    /// stays alive.
    ///
    /// The gate is what makes the in-flight test deterministic: it parks a send
    /// *inside* the transport, so the test can freeze the session with one
    /// message genuinely handed over and the next one still sitting on the
    /// session's chain, with no sleep and no race to lose.
    actor PresenceTransport: MatchTransport {

        nonisolated let localPlayerID: PlayerID
        nonisolated let inboundMessages: AsyncStream<MatchMessage>
        nonisolated let peerConnectionStates: AsyncStream<PeerConnectionState>

        private nonisolated let inbound: AsyncStream<MatchMessage>.Continuation
        private nonisolated let states: AsyncStream<PeerConnectionState>.Continuation

        /// Everything this endpoint actually handed over, in landing order.
        private(set) var wire: [MatchMessage] = []

        private var parked: [CheckedContinuation<Void, Never>] = []
        private var gateClosed = false
        /// Messages this endpoint refuses to carry, throwing as a real transport
        /// does when the peer is not reachable at the moment of the send.
        private var failFilter: (@Sendable (MatchMessage) -> Bool)?

        init(localPlayerID: PlayerID, peer: PlayerID) {
            let messages = AsyncStream.makeStream(of: MatchMessage.self, bufferingPolicy: .unbounded)
            let connections = AsyncStream.makeStream(of: PeerConnectionState.self, bufferingPolicy: .unbounded)
            self.localPlayerID = localPlayerID
            self.inboundMessages = messages.stream
            self.peerConnectionStates = connections.stream
            self.inbound = messages.continuation
            self.states = connections.continuation
            connections.continuation.yield(.connected(peer))
        }

        func send(_ message: MatchMessage, delivery: MatchDelivery) async throws {
            if gateClosed {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    parked.append(continuation)
                }
            }
            if failFilter?(message) == true { throw MatchTransportError.peerDisconnected }
            wire.append(message)
        }

        /// Throws from `send` for every message `shouldFail` matches. `nil`
        /// carries everything again.
        func failSends(_ shouldFail: (@Sendable (MatchMessage) -> Bool)?) { failFilter = shouldFail }

        nonisolated func leave() {
            inbound.finish()
            states.finish()
        }

        // MARK: Hooks

        nonisolated func deliver(_ message: MatchMessage) { inbound.yield(message) }
        /// The peer drops out, both streams left open.
        nonisolated func drop(_ player: PlayerID) { states.yield(.disconnected(player)) }
        /// The peer comes back.
        nonisolated func restore(_ player: PlayerID) { states.yield(.connected(player)) }

        func closeGate() { gateClosed = true }
        /// Opens the gate and lets everything through. Every gated test ends
        /// here: a continuation left parked at process exit is a leak.
        func releaseAll() {
            gateClosed = false
            let waiting = parked
            parked = []
            for continuation in waiting { continuation.resume() }
        }

        // MARK: Readings

        var count: Int { wire.count }
        var drawRequests: Int {
            wire.filter { if case .drawRequest = $0 { return true } else { return false } }.count
        }
        var parkedCount: Int { parked.count }
    }

    /// The session's clock, cranked by the test.
    ///
    /// Waits are released by the duration they asked for, because a frozen
    /// session has two of them outstanding at once — the countdown's second and
    /// the reconnect window — and a test that wants to give the countdown all
    /// the time in the world must not expire the window to do it.
    ///
    /// It also records what it was asked for, so a test can check the session
    /// waited the window it advertises rather than some other number.
    @MainActor
    final class HandCrankedClock {
        private var parked: [(duration: Duration, continuation: CheckedContinuation<Void, Never>)] = []
        private(set) var requested: [Duration] = []

        var parkedCount: Int { parked.count }

        func tick(_ duration: Duration) async {
            requested.append(duration)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parked.append((duration, continuation))
            }
        }

        /// Resumes everything waiting on `duration` and leaves the rest parked.
        func release(_ duration: Duration) {
            let matching = parked.filter { $0.duration == duration }
            parked.removeAll { $0.duration == duration }
            for entry in matching { entry.continuation.resume() }
        }

        /// Resumes everything waiting. Safe with nothing parked, and safe on a
        /// task that has since been cancelled — the session re-checks.
        func releaseAll() {
            let waiting = parked
            parked = []
            for entry in waiting { entry.continuation.resume() }
        }
    }

    static func waitUntil(
        _ label: String,
        within deadline: Duration = .seconds(5),
        _ condition: () async -> Bool
    ) async throws {
        let limit = ContinuousClock.now + deadline
        while await !condition() {
            guard ContinuousClock.now < limit else { throw WaitExpired(label: label) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Hands out `duration` over and over until `condition` holds, so nothing
    /// waits on real time and no other outstanding wait is expired by accident.
    static func crank(
        _ clock: HandCrankedClock,
        releasing duration: Duration,
        until label: String,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let limit = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < limit else { throw WaitExpired(label: label) }
            clock.release(duration)
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Long enough for anything the session had already enqueued to have run.
    /// Used only before asserting that nothing happened.
    static func settle() async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(60))
    }

    /// Every observable field of a state, in a fixed order, as text. Ids as well
    /// as counts: a rack holding the right number of the wrong tiles has still
    /// moved. Deliberately not `JSONEncoder` — its key order is not
    /// deterministic, so a byte comparison over two encodings of one unchanged
    /// value flakes.
    static func snapshot(_ session: MatchSession) -> String {
        let hand = session.state.hand.map { "\($0.id) \($0.letter)" }.joined(separator: ",")
        let board = session.state.board.placementList
            .map { "\($0.coord.row):\($0.coord.col)=\($0.tile.id) \($0.tile.letter)" }
            .joined(separator: ",")
        let waiting = session.pendingDrawTiles.map { "\($0.id) \($0.letter)" }.joined(separator: ",")
        return """
            hand[\(hand)] board[\(board)] waiting[\(waiting)] \
            status[\(session.state.status)] exhausted[\(session.poolIsExhausted)] \
            winner[\(String(describing: session.winner))]
            """
    }

    /// A guest for `bob` whose peer `alice` holds the pool, already playing, on
    /// a transport the test drives.
    ///
    /// The clock is not optional: a `sleepFor` that returned promptly would
    /// expire the reconnect window the instant it opened, and every freeze test
    /// would race it.
    static func playingGuest(
        clock: HandCrankedClock,
        countdownSeconds: Int = 0
    ) async throws -> (guest: MatchSession, wire: PresenceTransport) {
        let wire = PresenceTransport(localPlayerID: bob, peer: alice)
        let guest = MatchSession(
            transport: wire,
            peerPlayerID: alice,
            dictionary: EveryWordIsReal(),
            sleepFor: { await clock.tick($0) }
        )
        wire.deliver(
            .start(
                version: WireFormat.current,
                seed: 1,
                startingHandSize: 0,
                countdownSeconds: countdownSeconds,
                options: .standard
            )
        )
        let expected: MatchStatus = countdownSeconds > 0
            ? .countdown(secondsRemaining: countdownSeconds)
            : .playing
        try await waitUntil("the guest to reach \(expected)") { guest.state.status == expected }
        return (guest, wire)
    }

    /// Two tiles in hand and one on the board, so a frozen session has something
    /// to be caught moving.
    @discardableResult
    static func stock(_ guest: MatchSession, _ wire: PresenceTransport) async throws -> [Tile] {
        let tiles = [Tile(letter: "W"), Tile(letter: "I"), Tile(letter: "N")]
        wire.deliver(.grant(player: bob, tiles: tiles))
        try await waitUntil("the tiles to be offered") { guest.pendingDrawTiles.count == 3 }
        #expect(guest.draw())
        try guest.place(tileID: tiles[0].id, at: Coord(row: 0, col: 0))
        return tiles
    }

    // MARK: - Criterion 1: a win ends the match and carries the board

    @Test("A win ends the match on both devices and its placements rebuild the winner's board")
    func aWinEndsTheMatchAndCarriesTheBoard() async throws {
        let (host, guest) = try await MatchSessionCriteriaTests.startedPair()

        for expected in 1...3 {
            guest.draw()
            try await Self.waitUntil("the guest to hold \(expected)") {
                guest.state.hand.count == expected
            }
        }
        let tiles = guest.state.hand
        for (offset, tile) in tiles.enumerated() {
            try guest.place(tileID: tile.id, at: Coord(row: 0, col: offset))
        }
        #expect(guest.canDraw)
        let winnersBoard = guest.state.board

        #expect(guest.claimWin())

        // The claimer applies its own win: a device never receives its own
        // sends, so one that waited to hear this back would wait forever.
        #expect(guest.state.status == .finished(winner: guest.localPlayerID))
        #expect(guest.winner == guest.localPlayerID)
        #expect(guest.isMatchOver)
        #expect(guest.winningPlacements == winnersBoard.placementList)

        // And the far side hears it.
        try await Self.waitUntil("the win to reach the host") { host.isMatchOver }
        #expect(host.state.status == .finished(winner: guest.localPlayerID))
        #expect(host.winner == guest.localPlayerID)
        #expect(host.winner != host.localPlayerID)

        // The criterion: what arrived rebuilds the board that was sent.
        let received = try #require(host.winningPlacements)
        #expect(received.count == winnersBoard.placements.count)
        let rebuilt = Board(
            placements: Dictionary(
                received.map { ($0.coord, $0.tile) },
                uniquingKeysWith: { first, _ in first }
            )
        )
        #expect(rebuilt == winnersBoard)
        #expect(rebuilt.placementList == winnersBoard.placementList)
        #expect(rebuilt.placements.count == 3)

        // Terminal on both sides: the board no longer moves.
        #expect(host.draw() == false)
        #expect(guest.draw() == false)
        #expect(throws: BoardActionError.drawPending) {
            try guest.recall(from: Coord(row: 0, col: 0))
        }
    }

    // MARK: - Criterion 2: a resignation names the other player

    @Test("A resignation ends the match with the other player as the winner on both devices")
    func aResignationNamesTheOtherPlayer() async throws {
        let (host, guest) = try await MatchSessionCriteriaTests.startedPair()

        #expect(guest.resign())

        // The resigning device loses, on its own copy, without hearing itself.
        #expect(guest.state.status == .finished(winner: host.localPlayerID))
        #expect(guest.winner == host.localPlayerID)
        #expect(guest.winner != guest.localPlayerID)
        #expect(guest.isMatchOver)
        #expect(guest.winningPlacements == nil)

        // And the peer that received it wins.
        try await Self.waitUntil("the resignation to reach the host") { host.isMatchOver }
        #expect(host.state.status == .finished(winner: host.localPlayerID))
        #expect(host.winner == host.localPlayerID)
        // No board travels with a resignation.
        #expect(host.winningPlacements == nil)

        // Terminal: a win arriving afterwards cannot reopen it or rename it.
        let (other, wire) = try await Self.playingGuest(clock: HandCrankedClock())
        wire.deliver(.resign(player: Self.alice))
        try await Self.waitUntil("the resignation to land") { other.isMatchOver }
        #expect(other.winner == Self.bob)
        wire.deliver(.win(player: Self.alice, placements: [Placement(tile: Tile(letter: "Z"), coord: Coord(row: 9, col: 9))]))
        try await Self.settle()
        #expect(other.state.status == .finished(winner: Self.bob))
        #expect(other.winningPlacements == nil)
    }

    // MARK: - Criterion 3: a lost peer freezes everything

    @Test("A peer that drops out freezes the session, and nothing reaches the transport")
    func aLostPeerFreezesTheSessionAndSendsNothing() async throws {
        let clock = HandCrankedClock()
        let (guest, wire) = try await Self.playingGuest(clock: clock)
        let tiles = try await Self.stock(guest, wire)
        let before = Self.snapshot(guest)
        let sentBefore = await wire.count

        wire.drop(Self.alice)
        try await Self.waitUntil("the session to freeze") { guest.peerPresence != .present }

        // The banner's countdown: a deadline the shell can still count down to.
        let deadline = try #require({ () -> Date? in
            guard case let .reconnecting(deadline) = guest.peerPresence else { return nil }
            return deadline
        }())
        #expect(deadline > Date())
        #expect(deadline <= Date().addingTimeInterval(TimeInterval(MatchSession.reconnectGraceSeconds)))
        // Frozen is not over: nobody has won, and nobody has lost.
        #expect(guest.isMatchOver == false)
        #expect(guest.winner == nil)

        // Every entry point the shell has, refused.
        #expect(throws: BoardActionError.drawPending) {
            try guest.place(tileID: tiles[1].id, at: Coord(row: 0, col: 1))
        }
        #expect(throws: BoardActionError.drawPending) {
            try guest.recall(from: Coord(row: 0, col: 0))
        }
        #expect(guest.draw() == false)
        #expect(guest.swap(tiles[1]) == false)
        #expect(guest.claimWin() == false)
        #expect(guest.resign() == false)

        // And what the peer said before it left cannot move the game either.
        wire.deliver(.grant(player: Self.bob, tiles: [Tile(letter: "X")]))
        wire.deliver(.poolExhausted)
        wire.deliver(.start(version: WireFormat.current, seed: 9, startingHandSize: 0, countdownSeconds: 5, options: .standard))
        try await Self.settle()

        // The whole observable state, not a count of any part of it.
        #expect(Self.snapshot(guest) == before)
        #expect(guest.state.hand.map(\.id) == [tiles[1].id, tiles[2].id])
        #expect(guest.state.board.tile(at: Coord(row: 0, col: 0))?.id == tiles[0].id)
        #expect(guest.state.board.placementList.count == 1)
        #expect(guest.pendingDrawTiles.isEmpty)
        #expect(guest.poolIsExhausted == false)
        #expect(guest.state.status == .playing)

        // The proof the guardrail actually asks for: the transport was handed
        // nothing. Not "the send threw" — nothing was ever offered to it.
        #expect(await wire.count == sentBefore)
        #expect(await wire.drawRequests == 0)

        clock.releaseAll()
        try await Self.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    @Test("FakeTransport's own disconnect hook freezes the surviving session")
    func theFakeTransportDisconnectHookFreezesTheSurvivor() async throws {
        let (host, guest) = try await MatchSessionCriteriaTests.startedPair()
        guest.draw()
        try await Self.waitUntil("the guest to hold a tile") { guest.state.hand.count == 1 }
        let tile = guest.state.hand[0]
        try guest.place(tileID: tile.id, at: Coord(row: 0, col: 0))
        let before = Self.snapshot(guest)

        // No device, no network: the host simply goes.
        host.leave()
        try await Self.waitUntil("the survivor to freeze") { guest.peerPresence != .present }

        guard case let .reconnecting(deadline) = guest.peerPresence else {
            Issue.record("expected a reconnecting deadline, got \(guest.peerPresence)")
            return
        }
        #expect(deadline > Date())
        #expect(guest.isMatchOver == false)
        #expect(guest.winner == nil)

        #expect(guest.draw() == false)
        #expect(throws: BoardActionError.drawPending) {
            try guest.recall(from: Coord(row: 0, col: 0))
        }
        try await Self.settle()
        #expect(Self.snapshot(guest) == before)

        guest.leave()
    }

    // MARK: - Criterion 3b: what was already on its way out

    @Test("A message enqueued before the peer left never reaches the transport, and its credit comes back")
    func workEnqueuedBeforeTheDropNeverReachesTheWire() async throws {
        let clock = HandCrankedClock()
        let (guest, wire) = try await Self.playingGuest(clock: clock)

        // The gate parks the first send *inside* the transport, so the second is
        // still on the session's chain when the peer goes. No sleep, no race.
        await wire.closeGate()
        #expect(guest.draw())
        #expect(guest.draw())
        try await Self.waitUntil("the first send to be handed over") { await wire.parkedCount == 1 }

        wire.drop(Self.alice)
        try await Self.waitUntil("the session to freeze") { guest.peerPresence != .present }
        await wire.releaseAll()
        try await Self.settle()

        // The first was already in the transport's hands and lands. The second
        // was not, and never does — the freeze is re-checked when the enqueued
        // work runs, not only when it was enqueued.
        #expect(await wire.drawRequests == 1)
        #expect(await wire.count == 1)

        // The peer comes back to a match exactly where it was.
        wire.restore(Self.alice)
        try await Self.waitUntil("the peer to return") { guest.peerPresence == .present }
        #expect(guest.state.hand.isEmpty)
        #expect(guest.pendingDrawTiles.isEmpty)
        #expect(guest.state.status == .playing)

        // One request really left, so the first grant answers it and goes
        // straight to the rack. The second was never asked for, so it is the
        // opponent's round and becomes an obligation. A credit left over from
        // the request that never left would take that one too, and the board
        // would never freeze again.
        wire.deliver(.grant(player: Self.bob, tiles: [Tile(letter: "A")]))
        try await Self.waitUntil("the answer to the request that left") { guest.state.hand.count == 1 }
        wire.deliver(.grant(player: Self.bob, tiles: [Tile(letter: "B")]))
        try await Self.waitUntil("the opponent's round") { guest.hasPendingDraw }

        #expect(guest.state.hand.count == 1)
        #expect(guest.pendingDrawTiles.count == 1)
        #expect(guest.state.hand[0].letter == "A")
        #expect(guest.pendingDrawTiles[0].letter == "B")

        clock.releaseAll()
        try await Self.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - Criterion 4: the deadline passes and nobody won

    @Test("The reconnect deadline passing ends the match with no winner named")
    func theDeadlinePassingEndsTheMatchWithNoWinner() async throws {
        let clock = HandCrankedClock()
        let (guest, wire) = try await Self.playingGuest(clock: clock)
        let tiles = try await Self.stock(guest, wire)
        let before = Self.snapshot(guest)

        wire.drop(Self.alice)
        try await Self.waitUntil("the session to freeze") { guest.peerPresence != .present }
        #expect(guest.isMatchOver == false)

        // The wait is timed by the injected seam, for the window the session
        // advertises — not by comparing a wall clock against the peer's.
        try await Self.waitUntil("the window to ask for its time") { clock.parkedCount == 1 }
        #expect(clock.requested == [.seconds(MatchSession.reconnectGraceSeconds)])

        clock.release(.seconds(MatchSession.reconnectGraceSeconds))
        try await Self.waitUntil("the deadline to pass") { guest.peerPresence == .gone }

        // Over, with nobody named. `state.status` cannot say this — it has no
        // terminal case without a winner — so the session says it.
        #expect(guest.isMatchOver)
        #expect(guest.winner == nil)
        #expect(guest.winningPlacements == nil)
        #expect(guest.state.status == .playing)

        // Still locked, and still exactly where it was.
        #expect(guest.draw() == false)
        #expect(guest.claimWin() == false)
        #expect(guest.resign() == false)
        #expect(throws: BoardActionError.drawPending) {
            try guest.place(tileID: tiles[1].id, at: Coord(row: 0, col: 1))
        }
        #expect(Self.snapshot(guest) == before)
        #expect(await wire.count == 0)

        // Over is over: nothing arriving afterwards names a winner, and a peer
        // that reappears cannot restart a match that has already ended.
        wire.deliver(.win(player: Self.alice, placements: []))
        wire.deliver(.resign(player: Self.alice))
        wire.restore(Self.alice)
        try await Self.settle()
        #expect(guest.peerPresence == .gone)
        #expect(guest.winner == nil)
        #expect(guest.isMatchOver)
        #expect(guest.state.status == .playing)
        #expect(await wire.count == 0)

        clock.releaseAll()
        try await Self.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - The peer that does come back

    @Test("A peer returning inside the deadline resumes the countdown where it stopped")
    func aReturningPeerResumesTheCountdown() async throws {
        let clock = HandCrankedClock()
        let (guest, wire) = try await Self.playingGuest(clock: clock, countdownSeconds: 3)
        try await Self.waitUntil("the first tick to be asked for") { clock.parkedCount == 1 }
        #expect(guest.state.status == .countdown(secondsRemaining: 3))

        wire.drop(Self.alice)
        try await Self.waitUntil("the session to freeze") { guest.peerPresence != .present }

        // The countdown is game state. Frozen, it does not move however many
        // seconds the clock hands out — and handing out seconds does not expire
        // the reconnect window, which is still parked on its own duration.
        clock.release(.seconds(1))
        try await Self.settle()
        clock.release(.seconds(1))
        try await Self.settle()
        #expect(guest.state.status == .countdown(secondsRemaining: 3))
        #expect(guest.peerPresence != .gone)

        wire.restore(Self.alice)
        try await Self.waitUntil("the peer to return") { guest.peerPresence == .present }
        #expect(guest.state.status == .countdown(secondsRemaining: 3))

        // And from the second it stopped on, not from the top.
        for remaining in [2, 1] {
            try await Self.crank(clock, releasing: .seconds(1), until: "the countdown to reach \(remaining)") {
                guest.state.status == .countdown(secondsRemaining: remaining)
            }
        }
        try await Self.crank(clock, releasing: .seconds(1), until: "play to begin") {
            guest.state.status == .playing
        }
        #expect(guest.isMatchOver == false)
        #expect(guest.winner == nil)

        clock.releaseAll()
        try await Self.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }
}
