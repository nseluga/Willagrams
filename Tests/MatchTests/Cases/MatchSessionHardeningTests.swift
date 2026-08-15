import Foundation
import Testing
import WillagramsRules
@testable import Match

/// Regression cover for the trust-boundary and counter fixes.
///
/// Each test drives one failure mode a reviewer found and the engineer closed,
/// through the real production entry points — `startMatch`, `draw`, `swap`,
/// `place`, `recall` — and the real inbound pump. Nothing here reads a private
/// counter or re-derives a property from an internal helper: every assertion is
/// on what a caller can observe, because that is the only thing a later change
/// can quietly break.
///
/// Most of these are negative assertions, and a negative assertion that never
/// reaches the code it is guarding proves nothing. Every one of them therefore
/// waits on a *marker* whose effect can only follow the messages under test —
/// an answer landing on the wire, a later grant arriving — before it asserts the
/// silence. The inbound stream is FIFO and `receive` is synchronous, so a marker
/// that landed is proof the messages ahead of it were consumed.
///
/// Every wait races a deadline and throws when it expires: this suite runs
/// unattended, so a message that never arrives fails in seconds rather than
/// hanging the run. Nothing here iterates a transport stream — the session under
/// test is its single consumer.
@MainActor
@Suite("Match session hardening")
struct MatchSessionHardeningTests {

    // MARK: - Fixtures

    struct EveryWordIsReal: WordList {
        func contains(_ word: String) -> Bool { true }
    }

    struct WaitExpired: Error, CustomStringConvertible {
        let label: String
        var description: String { "timed out waiting for \(label)" }
    }

    static let alice = PlayerID(rawValue: "alice")
    static let bob = PlayerID(rawValue: "bob")

    /// A transport a test can stop, restart and break.
    ///
    /// Three hooks beyond recording the wire:
    ///
    /// - **the gate** parks a send inside `HostPool.handle`, so a test can hold
    ///   the pool's answer half-applied and press Draw in the gap. That race —
    ///   a peer's round in flight while this device has its own Draw
    ///   outstanding — is the one the freeze used to lose, and it cannot be
    ///   reached with a transport that returns promptly.
    /// - **refusal** throws from `send` without touching either stream, which is
    ///   a request that never left the wire. `FakeTransport`'s drop filter
    ///   returns *normally* by design, and its disconnect finishes the inbound
    ///   stream, which would end the pump this test still needs.
    /// - **deliver** puts a message on this endpoint's inbound stream, as a peer
    ///   would — including messages an honest peer would never send.
    actor ScriptedTransport: MatchTransport {

        nonisolated let localPlayerID: PlayerID
        nonisolated let inboundMessages: AsyncStream<MatchMessage>
        nonisolated let peerConnectionStates = AsyncStream<PeerConnectionState> { $0.finish() }

        private nonisolated let inbound: AsyncStream<MatchMessage>.Continuation

        /// What actually reached the wire, in landing order.
        private(set) var wire: [MatchMessage] = []
        /// Sends that threw instead of landing.
        private(set) var refusals = 0

        private var parked: [CheckedContinuation<Void, Never>] = []
        private var gateClosed = false
        private var refusing = false

        init(localPlayerID: PlayerID) {
            let stream = AsyncStream.makeStream(of: MatchMessage.self, bufferingPolicy: .unbounded)
            self.localPlayerID = localPlayerID
            self.inboundMessages = stream.stream
            self.inbound = stream.continuation
        }

        nonisolated func deliver(_ message: MatchMessage) { inbound.yield(message) }

        func send(_ message: MatchMessage, delivery: MatchDelivery) async throws {
            if gateClosed {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    parked.append(continuation)
                }
            }
            if refusing {
                refusals += 1
                throw MatchTransportError.peerDisconnected
            }
            wire.append(message)
        }

        nonisolated func leave() { inbound.finish() }

        // MARK: Hooks

        func closeGate() { gateClosed = true }
        func openGate() { gateClosed = false }
        var parkedCount: Int { parked.count }
        func releaseOne() {
            guard !parked.isEmpty else { return }
            parked.removeFirst().resume()
        }
        /// Opens the gate and lets everything through. Every gated test ends
        /// here: a continuation left parked at process exit is a leak.
        func releaseAll() {
            gateClosed = false
            let waiting = parked
            parked = []
            for continuation in waiting { continuation.resume() }
        }
        func refuseSends(_ on: Bool) { refusing = on }

        // MARK: Readings

        var count: Int { wire.count }
        var grants: Int { wire.filter { if case .grant = $0 { return true } else { return false } }.count }
        var swapGrants: Int { wire.filter { if case .swapGrant = $0 { return true } else { return false } }.count }
        var exhaustions: Int { wire.filter { $0 == .poolExhausted }.count }
        var drawRequests: Int {
            wire.filter { if case .drawRequest = $0 { return true } else { return false } }.count
        }
    }

    /// The countdown's clock, cranked by the test. A countdown left parked on a
    /// real `Task.sleep` at process exit takes the test helper down with it.
    @MainActor
    final class HandCrankedClock {
        private var parked: [CheckedContinuation<Void, Never>] = []
        private(set) var ticksRequested = 0

        var parkedCount: Int { parked.count }

        func tick(_ duration: Duration) async {
            ticksRequested += 1
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parked.append(continuation)
            }
        }

        func release() {
            guard !parked.isEmpty else { return }
            parked.removeFirst().resume()
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

    /// A session for `bob`, whose peer `alice` holds the pool, already playing.
    static func playingGuest() async throws -> (guest: MatchSession, wire: ScriptedTransport) {
        let wire = ScriptedTransport(localPlayerID: bob)
        let guest = MatchSession(transport: wire, peerPlayerID: alice, dictionary: EveryWordIsReal())
        wire.deliver(.start(version: WireFormat.current, seed: 1, startingHandSize: 21, countdownSeconds: 0))
        try await waitUntil("the guest to be playing") { guest.state.status == .playing }
        return (guest, wire)
    }

    /// A session for `alice`, who holds the pool, already playing.
    static func playingHost() -> (host: MatchSession, wire: ScriptedTransport) {
        let wire = ScriptedTransport(localPlayerID: alice)
        let host = MatchSession(transport: wire, peerPlayerID: bob, dictionary: EveryWordIsReal())
        host.startMatch(seed: 1, startingHandSize: 21, countdownSeconds: 0)
        return (host, wire)
    }

    // MARK: - Critical: the host is the only authority for the pool

    @Test("The host refuses pool authority off the wire, and the guest still takes all of it")
    func hostRefusesPoolAuthorityOffTheWire() async throws {
        // --- The host half. It mints these itself; one arriving is a forgery.
        let (host, wire) = Self.playingHost()
        #expect(host.state.status == .playing)
        #expect(HostPool.host(of: Self.alice, Self.bob) == Self.alice)

        host.draw()
        try await Self.waitUntil("the host's own tile") { host.state.hand.count == 1 }
        let own = try #require(host.state.hand.first)

        let minted = Tile(letter: "Z")
        let forged = [Tile(letter: "A"), Tile(letter: "B"), Tile(letter: "C")]
        wire.deliver(.grant(player: Self.alice, tiles: [minted]))
        wire.deliver(.swapGrant(player: Self.alice, tiles: forged, returned: own))
        wire.deliver(.poolExhausted)
        // The marker: only the real pool can answer this, and the answer lands
        // on the wire behind all three forgeries.
        wire.deliver(.drawRequest(player: Self.bob))
        try await Self.waitUntil("the host to answer the request behind the forgeries") {
            await wire.grants == 2
        }

        // The rack the host actually holds is the one the pool gave it.
        #expect(host.state.hand.map(\.id) == [own.id])
        #expect(host.pendingDrawTiles.count == 1)
        let forgedIDs = Set(forged.map(\.id) + [minted.id])
        #expect(Set(host.pendingDrawTiles.map(\.id)).isDisjoint(with: forgedIDs))
        #expect(Set(host.state.hand.map(\.id)).isDisjoint(with: forgedIDs))
        #expect(host.poolIsExhausted == false)

        // --- The guest half. It has no pool, so all three are the only way it
        // learns anything, and every one of them must still apply.
        let (guest, guestWire) = try await Self.playingGuest()
        let given = Tile(letter: "R")
        guestWire.deliver(.grant(player: Self.bob, tiles: [given]))
        try await Self.waitUntil("the guest's granted tile") { guest.hasPendingDraw }
        #expect(guest.draw())
        #expect(guest.state.hand.map(\.id) == [given.id])

        let three = [Tile(letter: "D"), Tile(letter: "E"), Tile(letter: "F")]
        guestWire.deliver(.swapGrant(player: Self.bob, tiles: three, returned: given))
        try await Self.waitUntil("the guest's swap answer") { guest.state.hand.count == 3 }
        #expect(guest.state.hand.map(\.id) == three.map(\.id))

        guestWire.deliver(.poolExhausted)
        try await Self.waitUntil("the guest to latch exhaustion") { guest.poolIsExhausted }
    }

    // MARK: - Important 1: the freeze holds under a racing own draw

    @Test("A peer's round freezes the host's board even with the host's own draw outstanding")
    func hostBoardFreezesOnAPeerRoundDuringItsOwnDraw() async throws {
        let (host, wire) = Self.playingHost()
        try await Self.waitUntil("the start to land") { await wire.count == 1 }

        // Hold the peer's answer half-way: the pool has moved, but the half that
        // belongs to this device has not been applied yet.
        await wire.closeGate()
        wire.deliver(.drawRequest(player: Self.bob))
        try await Self.waitUntil("the peer's answer to park mid-send") { await wire.parkedCount == 1 }

        // The press that used to lose the freeze: this device now has its own
        // draw outstanding while the peer's answer is still in flight.
        #expect(host.draw())

        await wire.releaseOne()
        // The peer's answer is applied by the time this device's own round has
        // reached its send — the chain runs one submission at a time.
        try await Self.waitUntil("this device's own round to park mid-send") { await wire.parkedCount == 1 }

        // The obligation is the peer's, not this device's own answer.
        #expect(host.hasPendingDraw)
        #expect(host.pendingDrawTiles.count == 1)
        #expect(host.state.hand.isEmpty)
        let waiting = try #require(host.pendingDrawTiles.first)
        #expect(throws: BoardActionError.drawPending) {
            try host.place(tileID: waiting.id, at: Coord(row: 0, col: 0))
        }
        #expect(throws: BoardActionError.drawPending) {
            try host.recall(from: Coord(row: 0, col: 0))
        }

        // And this device's own tile still arrives, on top of the obligation.
        await wire.releaseAll()
        try await Self.waitUntil("this device's own tile") { host.state.hand.count == 1 }
        #expect(host.hasPendingDraw)
        #expect(host.pendingDrawTiles.map(\.id) == [waiting.id])
    }

    // MARK: - Important 2: a request that never left the wire is owed nothing

    @Test("A draw request the wire refused gives its credit back, so the next opponent round still freezes")
    func aRequestThatNeverLeftTheWireReturnsItsCredit() async throws {
        let (guest, wire) = try await Self.playingGuest()

        await wire.refuseSends(true)
        #expect(guest.draw())
        try await Self.waitUntil("the wire to refuse the request") { await wire.refusals == 1 }
        await wire.refuseSends(false)
        #expect(await wire.drawRequests == 0)

        // The opponent draws. This device asked for nothing that is still owed,
        // so this is an obligation and the board freezes.
        let opponents = Tile(letter: "T")
        wire.deliver(.grant(player: Self.bob, tiles: [opponents]))
        try await Self.waitUntil("the opponent's round to land") {
            guest.hasPendingDraw || !guest.state.hand.isEmpty
        }

        #expect(guest.hasPendingDraw)
        #expect(guest.state.hand.isEmpty)
        #expect(guest.pendingDrawTiles.map(\.id) == [opponents.id])
        #expect(throws: BoardActionError.drawPending) {
            try guest.recall(from: Coord(row: 0, col: 0))
        }
    }

    // MARK: - Important 3: a refusal closes only the request it answered

    @Test("A refusal closes the draw it answered and leaves a draw open when it answered a return")
    func refusalsCloseOnlyTheRequestTheyAnswer() async throws {
        // --- A refused return must not spend the draw credit.
        let (guest, wire) = try await Self.playingGuest()
        let held = Tile(letter: "Q")
        wire.deliver(.grant(player: Self.bob, tiles: [held]))
        try await Self.waitUntil("a tile to hold") { guest.hasPendingDraw }
        #expect(guest.draw())
        #expect(guest.state.hand.map(\.id) == [held.id])

        #expect(guest.draw())                       // the credit under test
        #expect(guest.swap(held))
        try await Self.waitUntil("both requests to land") { await wire.count == 2 }
        wire.deliver(.rejected(reason: .notEnoughTilesToSwap))

        // The draw is still owed an answer, so this grant is this device's own.
        let mine = Tile(letter: "N")
        wire.deliver(.grant(player: Self.bob, tiles: [mine]))
        try await Self.waitUntil("this device's own answer") {
            guest.state.hand.count == 2 || guest.hasPendingDraw
        }
        #expect(guest.state.hand.map(\.id) == [held.id, mine.id])
        #expect(guest.hasPendingDraw == false)

        // --- A refusal that answered the draw must spend it.
        let (other, otherWire) = try await Self.playingGuest()
        #expect(other.draw())
        try await Self.waitUntil("the request to land") { await otherWire.count == 1 }
        otherWire.deliver(.rejected(reason: .poolEmpty))

        // Nothing is owed now, so the next grant is the opponent's round.
        let opponents = Tile(letter: "S")
        otherWire.deliver(.grant(player: Self.bob, tiles: [opponents]))
        try await Self.waitUntil("the opponent's round") {
            other.hasPendingDraw || !other.state.hand.isEmpty
        }
        #expect(other.hasPendingDraw)
        #expect(other.state.hand.isEmpty)
        #expect(other.pendingDrawTiles.map(\.id) == [opponents.id])
    }

    // MARK: - Important 4: an empty pool stops requests, never acceptance

    @Test("An exhausted pool stops fresh requests and still lets a waiting tile be taken")
    func exhaustionStopsFreshRequestsButNotAcceptance() async throws {
        // --- The guest, told by the broadcast.
        let (guest, wire) = try await Self.playingGuest()
        wire.deliver(.poolExhausted)
        try await Self.waitUntil("the guest to latch exhaustion") { guest.poolIsExhausted }

        let before = await wire.count
        #expect(guest.draw() == false)

        // A grant reordered behind the broadcast still arrives, and taking it is
        // never suppressed by the latch — this is the acceptance criterion under
        // the guard that stops the request.
        let late = Tile(letter: "W")
        wire.deliver(.grant(player: Self.bob, tiles: [late]))
        try await Self.waitUntil("the late grant") { guest.hasPendingDraw }
        #expect(guest.draw())
        #expect(guest.pendingDrawTiles.isEmpty)
        #expect(guest.state.hand.map(\.id) == [late.id])
        #expect(guest.poolIsExhausted)

        // The board reopened, and both entry points really move it.
        try guest.place(tileID: late.id, at: Coord(row: 0, col: 0))
        #expect(guest.state.board.tile(at: Coord(row: 0, col: 0))?.id == late.id)
        try guest.recall(from: Coord(row: 0, col: 0))
        #expect(guest.state.board.tile(at: Coord(row: 0, col: 0)) == nil)
        // Neither press put anything on the wire.
        #expect(await wire.count == before)
        #expect(await wire.drawRequests == 0)
    }

    @Test("A host whose own pool has run out stops asking and still hands over what is waiting")
    func theHostLatchesItsOwnEmptyPoolAndStopsAsking() async throws {
        // Told by its own pool rather than by the broadcast. Two tiles leave per
        // round, so the round after the last pair is the one that finds nothing.
        let (host, hostWire) = Self.playingHost()
        let rounds = LetterDistribution.totalTiles / 2
        for _ in 0...rounds { hostWire.deliver(.drawRequest(player: Self.bob)) }
        try await Self.waitUntil("the host's pool to run out", within: .seconds(20)) {
            host.poolIsExhausted
        }
        try await Self.waitUntil("every round to be answered", within: .seconds(20)) {
            host.pendingDrawTiles.count == rounds
        }
        #expect(await hostWire.exhaustions == 1)

        // Taking the pile is still allowed; asking for more is not, and no
        // second broadcast goes out.
        #expect(host.draw())
        #expect(host.state.hand.count == rounds)
        #expect(host.pendingDrawTiles.isEmpty)
        #expect(host.draw() == false)
        try await Self.waitUntil("the chain to drain", within: .seconds(10)) {
            await hostWire.parkedCount == 0
        }
        #expect(await hostWire.exhaustions == 1)
    }

    // MARK: - Important 5: one message cannot wedge the state machine

    @Test("A start carrying an absurd countdown is clamped instead of parking the session")
    func aHugeCountdownCannotWedgeTheSession() async throws {
        let wire = ScriptedTransport(localPlayerID: Self.bob)
        let clock = HandCrankedClock()
        let guest = MatchSession(
            transport: wire,
            peerPlayerID: Self.alice,
            dictionary: EveryWordIsReal(),
            sleepFor: { await clock.tick($0) }
        )

        wire.deliver(
            .start(version: WireFormat.current, seed: 2, startingHandSize: .max, countdownSeconds: 9_999_999)
        )
        try await Self.waitUntil("the countdown to open at the ceiling") {
            guest.state.status == .countdown(secondsRemaining: 10)
        }
        // The other value off the same message, clamped to the whole pool.
        #expect(guest.startingHandSize == LetterDistribution.totalTiles)

        // Ten ticks and no more: the session reaches play on its own.
        for remaining in stride(from: 9, through: 1, by: -1) {
            try await Self.waitUntil("tick \(10 - remaining)") { clock.parkedCount == 1 }
            clock.release()
            try await Self.waitUntil("the countdown to reach \(remaining)") {
                guest.state.status == .countdown(secondsRemaining: remaining)
            }
        }
        try await Self.waitUntil("the last tick") { clock.parkedCount == 1 }
        clock.release()
        try await Self.waitUntil("play to begin") { guest.state.status == .playing }

        #expect(clock.ticksRequested == 10)
        #expect(clock.parkedCount == 0)
    }

    // MARK: - Important 6: nothing moves the pool before play

    @Test("Peer requests arriving before play do not move the pool")
    func requestsArrivingBeforePlayDoNotMoveThePool() async throws {
        let wire = ScriptedTransport(localPlayerID: Self.alice)
        let clock = HandCrankedClock()
        let host = MatchSession(
            transport: wire,
            peerPlayerID: Self.bob,
            dictionary: EveryWordIsReal(),
            sleepFor: { await clock.tick($0) }
        )
        host.startMatch(seed: 3, startingHandSize: 21, countdownSeconds: 2)
        #expect(host.state.status == .countdown(secondsRemaining: 2))

        wire.deliver(.drawRequest(player: Self.bob))
        wire.deliver(.swapRequest(player: Self.bob, returning: Tile(letter: "L")))

        for remaining in [1] {  // one tick short of play

            try await Self.waitUntil("a tick") { clock.parkedCount == 1 }
            clock.release()
            try await Self.waitUntil("the countdown to reach \(remaining)") {
                host.state.status == .countdown(secondsRemaining: remaining)
            }
        }
        try await Self.waitUntil("the last tick") { clock.parkedCount == 1 }
        clock.release()
        try await Self.waitUntil("play to begin") { host.state.status == .playing }

        // The marker: a return made in play, carrying a tile no other request
        // carries, so the answer on the wire names the request that produced it.
        let marker = Tile(letter: "V")
        wire.deliver(.swapRequest(player: Self.bob, returning: marker))
        try await Self.waitUntil("the request made in play to be answered") { await wire.swapGrants == 1 }

        // The only answer is the marker's. Nothing the countdown heard moved the
        // pool: no draw was ever answered, and the early return was not either.
        let answered = await wire.wire.compactMap { message -> UUID? in
            guard case let .swapGrant(_, _, returned) = message else { return nil }
            return returned.id
        }
        #expect(answered == [marker.id])
        #expect(await wire.grants == 0)
        #expect(host.pendingDrawTiles.isEmpty)
        #expect(host.state.hand.isEmpty)
    }

    // MARK: - Important 7: only the peer can end the match from the wire

    @Test("An end-of-match message naming anyone but the peer is refused")
    func endOfMatchMessagesMustNameThePeer() async throws {
        let (guest, wire) = try await Self.playingGuest()

        // Both name this device, which the peer has no standing to do.
        wire.deliver(.resign(player: Self.bob))
        wire.deliver(.win(player: Self.bob, placements: []))
        // The marker: a live session still applies a grant. A finished one
        // ignores everything, so this arriving is proof the match is alive.
        let marker = Tile(letter: "M")
        wire.deliver(.grant(player: Self.bob, tiles: [marker]))
        try await Self.waitUntil("the marker grant, or an end this device did not earn") {
            guest.hasPendingDraw || guest.state.status != .playing
        }
        #expect(guest.state.status == .playing)
        #expect(guest.pendingDrawTiles.map(\.id) == [marker.id])

        // The peer resigning is the one form that ends it, and this device wins.
        wire.deliver(.resign(player: Self.alice))
        try await Self.waitUntil("the match to end") {
            guest.state.status == .finished(winner: Self.bob)
        }

        // And the peer's own win is honoured, on its own session.
        let (other, otherWire) = try await Self.playingGuest()
        otherWire.deliver(.win(player: Self.alice, placements: []))
        try await Self.waitUntil("the peer's win") {
            other.state.status == .finished(winner: Self.alice)
        }
    }

    // MARK: - The refusal the host still takes from the wire

    /// Inbound `.rejected` is the one pool-answer case not gated on
    /// `hostPool == nil`: a peer can still close a credit the host opened. This
    /// is the differential that says whether that matters — the same round, run
    /// with and without a peer's refusal landing inside it, compared on
    /// everything a caller can see.
    ///
    /// Letters rather than ids: the pool's shuffle is seeded, so both runs deal
    /// the same letters, while tile ids are fresh on every run by design.
    @Test("A refusal from the peer changes nothing the host can observe beyond its note")
    func peerRefusalsChangeNothingTheHostCanObserve() async throws {
        struct Reading: Equatable {
            var hand: [Character]
            var waiting: [Character]
            var status: MatchStatus
            var exhausted: Bool
            var canDraw: Bool
        }

        /// One round: the host's own draw, held mid-answer, optionally with a
        /// refusal from the peer landing in the gap.
        func round(refusedByPeer: Bool) async throws -> (Reading, String?) {
            let (host, wire) = Self.playingHost()
            try await Self.waitUntil("the start to land") { await wire.count == 1 }

            await wire.closeGate()
            #expect(host.draw())
            try await Self.waitUntil("the answer to park mid-send") { await wire.parkedCount == 1 }
            if refusedByPeer {
                wire.deliver(.rejected(reason: .poolEmpty))
                try await Self.waitUntil("the refusal to be noted") { host.lastNote != nil }
            }
            await wire.releaseAll()
            try await Self.waitUntil("this device's own tile") {
                host.state.hand.count + host.pendingDrawTiles.count == 1
            }
            return (
                Reading(
                    hand: host.state.hand.map(\.letter),
                    waiting: host.pendingDrawTiles.map(\.letter),
                    status: host.state.status,
                    exhausted: host.poolIsExhausted,
                    canDraw: host.canDraw
                ),
                host.lastNote
            )
        }

        let (control, controlNote) = try await round(refusedByPeer: false)
        let (refused, refusedNote) = try await round(refusedByPeer: true)

        // The host's own tile is its own however many refusals arrive: a credit
        // the peer closed must not turn this device's answer into an obligation.
        #expect(refused == control)
        #expect(refused.hand.count == 1)
        #expect(refused.waiting.isEmpty)

        // The note is the whole of the difference.
        #expect(controlNote == nil)
        #expect(refusedNote == "refused: poolEmpty")
    }

    // MARK: - Minor: a repeated grant is not a second tile

    @Test("A grant delivered twice does not double a tile into the rack")
    func aDuplicatedGrantDoesNotDoubleTheRack() async throws {
        let (guest, wire) = try await Self.playingGuest()

        let tile = Tile(letter: "P")
        wire.deliver(.grant(player: Self.bob, tiles: [tile]))
        wire.deliver(.grant(player: Self.bob, tiles: [tile]))
        // The marker: a second, genuinely new tile behind the duplicate.
        let second = Tile(letter: "K")
        wire.deliver(.grant(player: Self.bob, tiles: [second]))
        try await Self.waitUntil("the second tile") {
            guest.pendingDrawTiles.contains { $0.id == second.id }
        }
        #expect(guest.pendingDrawTiles.map(\.id) == [tile.id, second.id])

        // The same tile, redelivered once it is in the rack.
        #expect(guest.draw())
        #expect(guest.state.hand.count == 2)
        wire.deliver(.grant(player: Self.bob, tiles: [tile]))
        let third = Tile(letter: "H")
        wire.deliver(.grant(player: Self.bob, tiles: [third]))
        try await Self.waitUntil("the third tile") { guest.hasPendingDraw }
        #expect(guest.pendingDrawTiles.map(\.id) == [third.id])
        #expect(guest.state.hand.map(\.id) == [tile.id, second.id])

        // And once it is on the board.
        #expect(guest.draw())
        try guest.place(tileID: tile.id, at: Coord(row: 0, col: 0))
        wire.deliver(.grant(player: Self.bob, tiles: [tile]))
        let fourth = Tile(letter: "G")
        wire.deliver(.grant(player: Self.bob, tiles: [fourth]))
        try await Self.waitUntil("the fourth tile") { guest.hasPendingDraw }
        #expect(guest.pendingDrawTiles.map(\.id) == [fourth.id])
        #expect(guest.state.hand.map(\.id) == [second.id, third.id])
        #expect(guest.state.board.placementList.count == 1)
    }

    // MARK: - Minor: who may open a match, and when the board stops moving

    @Test("Only the elected device opens the match, and a finished board stays still")
    func onlyTheElectedDeviceOpensTheMatchAndAFinishedBoardStaysStill() async throws {
        // --- The election. `bob` is not the host, so this is not bob's to send.
        let wire = ScriptedTransport(localPlayerID: Self.bob)
        let guest = MatchSession(transport: wire, peerPlayerID: Self.alice, dictionary: EveryWordIsReal())
        guest.startMatch(seed: 4, startingHandSize: 21, countdownSeconds: 0)

        #expect(guest.state.status == .countdown(secondsRemaining: 0))
        #expect(guest.lastNote == "only the host opens the match")
        #expect(await wire.count == 0)

        // The elected device's own call is the control: the same call works.
        let (host, hostWire) = Self.playingHost()
        #expect(host.state.status == .playing)
        try await Self.waitUntil("the elected device's start to land") { await hostWire.count == 1 }

        // --- A finished match freezes the board at both entry points.
        let (other, otherWire) = try await Self.playingGuest()
        let pair = [Tile(letter: "X"), Tile(letter: "Y")]
        otherWire.deliver(.grant(player: Self.bob, tiles: pair))
        try await Self.waitUntil("two tiles") { other.pendingDrawTiles.count == 2 }
        #expect(other.draw())
        try other.place(tileID: pair[0].id, at: Coord(row: 0, col: 0))

        otherWire.deliver(.resign(player: Self.alice))
        try await Self.waitUntil("the match to end") {
            other.state.status == .finished(winner: Self.bob)
        }

        #expect(throws: BoardActionError.drawPending) {
            try other.place(tileID: pair[1].id, at: Coord(row: 0, col: 1))
        }
        #expect(throws: BoardActionError.drawPending) {
            try other.recall(from: Coord(row: 0, col: 0))
        }
        #expect(other.state.board.placementList.count == 1)
        #expect(other.state.board.tile(at: Coord(row: 0, col: 0))?.id == pair[0].id)
        #expect(other.state.hand.map(\.id) == [pair[1].id])
        #expect(other.draw() == false)

        // Re-read at the end of the test, by which point a start enqueued by the
        // device that had no standing to send one would long since have landed.
        #expect(await wire.count == 0)
    }
}
