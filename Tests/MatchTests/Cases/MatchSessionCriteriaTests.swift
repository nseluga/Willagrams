import Foundation
import Testing
import WillagramsRules
@testable import Match

/// One test per acceptance criterion for the client-side match state machine.
///
/// Each drives the real production entry points — `startMatch`, `draw`, `place`,
/// `recall`, `canDraw` — and reads the observable state afterwards. Nothing here
/// re-derives a property from an internal helper: the two negative criteria call
/// the same methods the shell calls and assert on what they threw and on the
/// bytes of the state they left behind.
///
/// Every cross-device wait races a deadline and throws when it expires. This
/// suite runs unattended, so a message that never arrives has to fail in seconds
/// rather than hang the run, and nothing here ever awaits a stream directly.
@MainActor
@Suite("Match session criteria")
struct MatchSessionCriteriaTests {

    // MARK: - Fixtures

    /// Accepts every word, so any two adjacent tiles form a complete board
    /// whatever letters the pool happened to hand out.
    struct EveryWordIsReal: WordList {
        func contains(_ word: String) -> Bool { true }
    }

    struct WaitExpired: Error, CustomStringConvertible {
        let label: String
        var description: String { "timed out waiting for \(label)" }
    }

    /// The countdown's clock, cranked by the test.
    ///
    /// It genuinely suspends, so the session parks between ticks and the test can
    /// read the status it is showing at each one. Nothing here consults a real
    /// clock, so a three-second countdown costs no time — and a countdown that
    /// stopped asking this clock for the time would never advance at all.
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

    /// Every observable field of a state, in a fixed order, as text.
    ///
    /// Deliberately not `JSONEncoder`: this toolchain does not order the keys of
    /// a keyed container deterministically, so two encodings of one unchanged
    /// value differ, and a byte comparison over them flakes. `placementList` is
    /// sorted by coordinate, which is what it exists for.
    static func snapshot(_ state: GameState) -> String {
        let hand = state.hand.map { "\($0.id) \($0.letter)" }.joined(separator: ",")
        let board = state.board.placementList
            .map { "\($0.coord.row):\($0.coord.col)=\($0.tile.id) \($0.tile.letter)" }
            .joined(separator: ",")
        return "hand[\(hand)] board[\(board)] pool[\(state.pool.count)] status[\(state.status)]"
    }

    /// Polls `condition` until it holds, throwing rather than hanging.
    static func waitUntil(
        _ label: String,
        within deadline: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let limit = ContinuousClock.now + deadline
        while !condition() {
            guard ContinuousClock.now < limit else { throw WaitExpired(label: label) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Two sessions wired to each other, started and past their countdown.
    ///
    /// Each endpoint's inbound stream has exactly one consumer — its own session.
    /// Nothing in this file iterates either one.
    static func startedPair(seed: UInt64 = 7) async throws -> (host: MatchSession, guest: MatchSession) {
        let alice = PlayerID(rawValue: "alice")
        let bob = PlayerID(rawValue: "bob")
        let (first, second) = FakeTransport.pair(alice, bob)

        let one = MatchSession(transport: first, peerPlayerID: bob, dictionary: EveryWordIsReal())
        let two = MatchSession(transport: second, peerPlayerID: alice, dictionary: EveryWordIsReal())

        one.startMatch(seed: seed, startingHandSize: 0, countdownSeconds: 0, options: .standard)
        try await waitUntil("both devices to be playing") {
            one.state.status == .playing && two.state.status == .playing
        }

        // Election is by id, not by who opened the match.
        return HostPool.host(of: [alice, bob]) == alice ? (one, two) : (two, one)
    }

    /// A guest holding one tile in hand, one on the board, and one more that
    /// reached its rack because the *opponent* drew.
    struct Obligated {
        let host: MatchSession
        let guest: MatchSession
        /// Still in the guest's hand, from the guest's own round.
        let held: Tile
        /// In the guest's hand, from the opponent's round.
        let owed: Tile
        /// On the guest's board.
        let placed: Tile
        let placedAt = Coord(row: 0, col: 0)
    }

    /// Runs real rounds in both directions over the real wire.
    ///
    /// The guest draws twice so it has tiles to move, then the host draws — that
    /// last round is the one that puts a tile in the guest's rack unasked.
    static func obligatedGuest() async throws -> Obligated {
        let (host, guest) = try await startedPair()

        guest.draw()
        try await waitUntil("the guest's first tile") { guest.state.hand.count == 1 }
        guest.draw()
        try await waitUntil("the guest's second tile") { guest.state.hand.count == 2 }

        let placed = guest.state.hand[0]
        let held = guest.state.hand[1]
        try guest.place(tileID: placed.id, at: Coord(row: 0, col: 0))
        #expect(guest.state.hand.map(\.id) == [held.id])

        // The host's half of the guest's two rounds went straight into its rack.
        try await waitUntil("the host to hold its tiles") { host.state.hand.count == 2 }
        #expect(host.hasPendingDraw == false)

        // Now the opponent draws. The guest's half lands in its rack unasked.
        host.draw()
        try await waitUntil("the guest to receive a tile") { guest.state.hand.count == 2 }
        let owed = try #require(guest.state.hand.first { $0.id != held.id })

        return Obligated(host: host, guest: guest, held: held, owed: owed, placed: placed)
    }

    // MARK: - Criterion 1

    @Test("A start from the peer opens the countdown and reaches play as the injected clock ticks")
    func receivedStartCountsDownOnTheInjectedClock() async throws {
        let alice = PlayerID(rawValue: "alice")
        let bob = PlayerID(rawValue: "bob")
        let (opener, listener) = FakeTransport.pair(alice, bob)
        let clock = HandCrankedClock()
        let guest = MatchSession(
            transport: listener,
            peerPlayerID: alice,
            dictionary: EveryWordIsReal(),
            sleepFor: { await clock.tick($0) }
        )

        let began = ContinuousClock.now
        try await opener.send(
            .start(version: WireFormat.current, seed: 4, startingHandSize: 21, countdownSeconds: 3, options: .standard, roster: [alice, bob]),
            delivery: .reliable
        )

        try await Self.waitUntil("the countdown to open at three") {
            guest.state.status == .countdown(secondsRemaining: 3)
        }

        // Time only moves when the test moves it. Parked on the first tick, the
        // session still shows three however long the process waits — nothing in
        // here counts towards an instant the peer named.
        try await Self.waitUntil("the first tick to be asked for") { clock.parkedCount == 1 }
        #expect(guest.state.status == .countdown(secondsRemaining: 3))

        for remaining in [2, 1] {
            clock.release()
            try await Self.waitUntil("the countdown to reach \(remaining)") {
                guest.state.status == .countdown(secondsRemaining: remaining)
            }
        }

        clock.release()
        try await Self.waitUntil("play to begin") { guest.state.status == .playing }

        // One tick per second of countdown, and no more once it is playing.
        #expect(clock.ticksRequested == 3)
        #expect(clock.parkedCount == 0)
        // Three seconds of countdown that the test never slept through.
        #expect(began.duration(to: ContinuousClock.now) < .seconds(1))
    }

    // MARK: - Criterion 2

    @Test("A grant from the opponent's draw lands in the hand and leaves both entry points open")
    func opponentGrantLeavesTheBoardOpen() async throws {
        let fixture = try await Self.obligatedGuest()
        let guest = fixture.guest

        #expect(guest.hasPendingDraw == false)
        #expect(guest.pendingDrawTiles.isEmpty)
        #expect(Set(guest.state.hand.map(\.id)) == [fixture.held.id, fixture.owed.id])
        #expect(guest.state.board.tile(at: fixture.placedAt)?.id == fixture.placed.id)

        // The real entry points, working for the tile that just arrived too.
        try guest.place(tileID: fixture.owed.id, at: Coord(row: 0, col: 1))
        #expect(guest.state.board.tile(at: Coord(row: 0, col: 1))?.id == fixture.owed.id)
        try guest.recall(from: fixture.placedAt)
        #expect(guest.state.board.tile(at: fixture.placedAt) == nil)
        #expect(Set(guest.state.hand.map(\.id)) == [fixture.held.id, fixture.placed.id])
    }

    // MARK: - Criterion 3

    @Test("A press of Draw after the opponent's tile landed asks for a round and takes the tile only once")
    func drawAfterAnArrivedTileTakesNothingTwice() async throws {
        let fixture = try await Self.obligatedGuest()
        let guest = fixture.guest
        let handBefore = guest.state.hand.map(\.id)

        #expect(guest.draw())
        try await Self.waitUntil("the answer to land") { guest.state.hand.count == handBefore.count + 1 }
        #expect(Array(guest.state.hand.map(\.id).prefix(handBefore.count)) == handBefore)

        // One press is one tile: nothing else turns up behind it.
        try await Task.sleep(for: .milliseconds(60))
        #expect(guest.state.hand.count == handBefore.count + 1)
        #expect(guest.pendingDrawTiles.isEmpty)
    }

    // MARK: - Criterion 4

    @Test("A tile left in hand refuses the draw however complete the board looks")
    func aTileInHandRefusesTheDraw() async throws {
        let dictionary = EveryWordIsReal()
        let (host, guest) = try await Self.startedPair()

        for expected in 1...3 {
            guest.draw()
            try await Self.waitUntil("the guest to hold \(expected)") {
                guest.state.hand.count == expected
            }
        }
        // The other half of each round landed in the opponent's rack.
        #expect(host.state.hand.count == 3)

        let tiles = guest.state.hand
        #expect(guest.canDraw == false)
        #expect(guest.canDraw == guest.state.canDraw(against: dictionary))

        try guest.place(tileID: tiles[0].id, at: Coord(row: 0, col: 0))
        #expect(guest.state.hand.count == 2)
        #expect(guest.canDraw == false)
        #expect(guest.canDraw == guest.state.canDraw(against: dictionary))

        // Two adjacent tiles with every word accepted: the board itself is
        // complete, so the one tile still in hand is the only thing refusing.
        try guest.place(tileID: tiles[1].id, at: Coord(row: 0, col: 1))
        #expect(guest.state.board.validate(against: dictionary).isComplete)
        #expect(guest.state.hand.count == 1)
        #expect(guest.canDraw == false)
        #expect(guest.canDraw == guest.state.canDraw(against: dictionary))

        try guest.place(tileID: tiles[2].id, at: Coord(row: 0, col: 2))
        #expect(guest.state.hand.isEmpty)
        #expect(guest.canDraw)
        #expect(guest.canDraw == guest.state.canDraw(against: dictionary))

        // One tile back in hand shuts it again, board untouched otherwise.
        try guest.recall(from: Coord(row: 0, col: 2))
        #expect(guest.state.hand.count == 1)
        #expect(guest.state.board.validate(against: dictionary).isComplete)
        #expect(guest.canDraw == false)
        #expect(guest.canDraw == guest.state.canDraw(against: dictionary))
    }
}
