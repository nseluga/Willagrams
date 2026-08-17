import Foundation
import Testing
import WillagramsRules
@testable import Match

/// QA's independent audit of the opening deal.
///
/// Everything here drives two real `MatchSession`s over a real `FakeTransport`
/// pair — no adapter shortcuts, no assertions on mocks. The negative criterion
/// (a playing-phase grant is held behind the obligation) is exercised through
/// the production entry point: the host really presses Draw, the grant really
/// travels, and the guest's own `draw()` really resolves it.
@MainActor
@Suite("Match session opening deal audit")
struct MatchSessionOpeningDealAuditTests {

    struct AnyWordList: WordList {
        func contains(_ word: String) -> Bool { true }
    }

    /// Holds a session inside its countdown until the test releases it.
    @MainActor
    final class Gate {
        var open = false
    }

    /// Swallows the first grant addressed to `player`, standing in for a deal
    /// lost or reordered in flight. Locked because the drop filter runs off the
    /// main actor.
    final class SwallowFirstGrant: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let player: PlayerID
        init(to player: PlayerID) { self.player = player }
        func callAsFunction(_ message: MatchMessage) -> Bool {
            guard case let .grant(who, _) = message, who == player else { return false }
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    static let alice = PlayerID(rawValue: "alice")
    static let bob = PlayerID(rawValue: "bob")

    static func waitUntil(_ label: String, _ condition: @MainActor () -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < limit else {
                Issue.record("timed out waiting for \(label)")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    static func settle() async throws {
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(2)) }
    }

    /// Two live sessions on one wire. `alice` wins the host election by id.
    static func livePair(
        countdownSeconds: Int,
        handSize: Int
    ) async throws -> (host: MatchSession, guest: MatchSession, hostWire: FakeTransport) {
        let (first, second) = FakeTransport.pair(alice, bob)
        let host = MatchSession(
            transport: first, peerPlayerID: bob, dictionary: AnyWordList(), sleepFor: { _ in }
        )
        let guest = MatchSession(
            transport: second, peerPlayerID: alice, dictionary: AnyWordList(), sleepFor: { _ in }
        )
        host.startMatch(seed: 77, startingHandSize: handSize, countdownSeconds: countdownSeconds)
        try await waitUntil("both sessions playing") {
            host.state.status == .playing && guest.state.status == .playing
        }
        return (host, guest, first)
    }

    // MARK: - The deal itself, end to end

    @Test("Countdown end deals both hands and leaves nothing behind the Draw button", arguments: [0, 2])
    func dealLandsInBothHands(countdownSeconds: Int) async throws {
        let handSize = 6
        let (host, guest, _) = try await Self.livePair(
            countdownSeconds: countdownSeconds, handSize: handSize
        )

        try await Self.waitUntil("both hands dealt") {
            host.state.hand.count == handSize && guest.state.hand.count == handSize
        }
        #expect(host.pendingDrawTiles.isEmpty)
        #expect(guest.pendingDrawTiles.isEmpty)
        #expect(host.hasPendingDraw == false)
        #expect(guest.hasPendingDraw == false)

        // Exactly `handSize * 2` distinct tiles left the one pool, and no tile
        // reached two racks.
        let hostIDs = Set(host.state.hand.map(\.id))
        let guestIDs = Set(guest.state.hand.map(\.id))
        #expect(hostIDs.count == handSize)
        #expect(guestIDs.count == handSize)
        #expect(hostIDs.union(guestIDs).count == handSize * 2)

        // And it settles there: nothing deals a second time.
        try await Self.settle()
        #expect(host.state.hand.count == handSize)
        #expect(guest.state.hand.count == handSize)
    }

    /// The pool half of the accounting, at the only place it is observable.
    @Test("One deal takes exactly two hands out of the pool")
    func poolFallsByTwiceTheHandSize() async throws {
        let (transport, _) = FakeTransport.pair(Self.alice, Self.bob)
        let pool = Pool.standard(seed: 31)
        let before = pool.count
        let hostPool = HostPool(
            players: (Self.alice, Self.bob), pool: pool, seed: 31, transport: transport
        )
        let handSize = 9
        let produced = await hostPool.deal(handSize: handSize)
        #expect(await hostPool.pool.count == before - handSize * 2)

        var perPlayer: [PlayerID: [Tile]] = [:]
        for case let .grant(player, tiles) in produced { perPlayer[player, default: []] += tiles }
        #expect(perPlayer.count == 2)
        #expect(perPlayer[Self.alice]?.count == handSize)
        #expect(perPlayer[Self.bob]?.count == handSize)
        let aliceIDs = Set(perPlayer[Self.alice]!.map(\.id))
        #expect(aliceIDs.isDisjoint(with: Set(perPlayer[Self.bob]!.map(\.id))))
    }

    // MARK: - The negative criterion, through the production entry point

    /// The Draw obligation must survive the opening deal untouched. This does
    /// not re-derive it from `applyGrant` or from a `HostPool` call: the host
    /// session presses `draw()`, the grant crosses a real wire, and the guest's
    /// own `draw()` is what finally takes it.
    @Test("After the deal, a peer's draw is still held until this player presses Draw")
    func aPeerDrawIsStillAnObligationAfterTheDeal() async throws {
        let handSize = 4
        let (host, guest, _) = try await Self.livePair(countdownSeconds: 0, handSize: handSize)
        try await Self.waitUntil("both hands dealt") {
            host.state.hand.count == handSize && guest.state.hand.count == handSize
        }
        let dealtToGuest = Set(guest.state.hand.map(\.id))

        // The real button on the real host session.
        #expect(host.draw())
        try await Self.waitUntil("the peer's round to reach the guest") { guest.hasPendingDraw }

        // Held, not taken. The board is shut behind it.
        #expect(guest.pendingDrawTiles.count == 1)
        #expect(guest.state.hand.count == handSize)
        #expect(Set(guest.state.hand.map(\.id)) == dealtToGuest)
        let waiting = guest.pendingDrawTiles[0].id
        #expect(dealtToGuest.contains(waiting) == false)
        #expect(throws: BoardActionError.drawPending) {
            try guest.place(tileID: guest.state.hand[0].id, at: Coord(row: 0, col: 0))
        }
        // It stays held across time, not merely at the instant it arrives.
        try await Self.settle()
        #expect(guest.pendingDrawTiles.count == 1)
        #expect(guest.state.hand.count == handSize)

        // And the player's own press is what resolves it.
        #expect(guest.draw())
        #expect(guest.pendingDrawTiles.isEmpty)
        #expect(guest.state.hand.count == handSize + 1)
        #expect(guest.state.hand.map(\.id).contains(waiting))
        // The host took its half of the same round straight into hand.
        #expect(host.state.hand.count == handSize + 1)
        #expect(host.pendingDrawTiles.isEmpty)
    }

    // MARK: - Probes of the receipt heuristic's second trigger

    /// The `tiles.count == startingHandSize` trigger, probed on a legitimate
    /// playing-phase peer draw whose count happens to match.
    ///
    /// A round grants exactly one tile, so the collision needs
    /// `startingHandSize == 1`. The opening deal is dropped in flight, which
    /// leaves `awaitingOpeningDeal` armed on the guest with no deal coming.
    ///
    /// Characterisation, not a wish: this pins the *known ceiling* named in
    /// `takeOpeningDeal`'s `ponytail:` comment. The peer's round is misread as
    /// the deal and skips the obligation. If the wire v2 `deal` case lands, this
    /// test should flip to expecting `hasPendingDraw`.
    @Test("KNOWN CEILING: with a hand size of one, a peer's draw is misread as the deal")
    func theCountTriggerMisfiresAtHandSizeOne() async throws {
        let handSize = 1
        let (first, second) = FakeTransport.pair(Self.alice, Self.bob)
        let host = MatchSession(
            transport: first, peerPlayerID: Self.bob, dictionary: AnyWordList(), sleepFor: { _ in }
        )
        let guest = MatchSession(
            transport: second, peerPlayerID: Self.alice, dictionary: AnyWordList(), sleepFor: { _ in }
        )
        // The opening grant addressed to the guest never arrives.
        let swallow = SwallowFirstGrant(to: Self.bob)
        await first.setDropFilter { swallow($0) }
        host.startMatch(seed: 5, startingHandSize: handSize, countdownSeconds: 0)
        try await Self.waitUntil("the host to hold its own hand") { host.state.hand.count == handSize }
        try await Self.settle()
        #expect(guest.state.hand.isEmpty)

        // A legitimate playing-phase round: one tile each.
        #expect(host.draw())
        try await Self.waitUntil("the round to reach the guest") { !guest.state.hand.isEmpty }

        // The misfire: it went to the hand, and no obligation was raised.
        #expect(guest.state.hand.count == 1)
        #expect(guest.pendingDrawTiles.isEmpty)
        #expect(guest.hasPendingDraw == false)

        // Contained: the flag is spent, so the very next peer round is an
        // obligation again. One grant is the whole blast radius.
        #expect(host.draw())
        try await Self.waitUntil("the second round to be held") { guest.hasPendingDraw }
        #expect(guest.pendingDrawTiles.count == 1)
        #expect(guest.state.hand.count == 1)
    }

    /// The `.countdown` trigger, probed the same way — and it is *not* bounded
    /// by the hand size.
    ///
    /// A guest still counting down while the host is already playing takes any
    /// grant that reaches it as the deal. The in-order wire normally saves this
    /// (the deal is enqueued before any later draw), so this drops the deal to
    /// stand in for the reordering the session's own doc comment says the
    /// transport is allowed to do.
    @Test("KNOWN CEILING: a grant reaching a guest still in countdown is taken as the deal at any size")
    func theCountdownTriggerMisfiresAtAnyHandSize() async throws {
        let handSize = 7
        let gate = Gate()
        let (first, second) = FakeTransport.pair(Self.alice, Self.bob)
        let host = MatchSession(
            transport: first, peerPlayerID: Self.bob, dictionary: AnyWordList(), sleepFor: { _ in }
        )
        let guest = MatchSession(
            transport: second,
            peerPlayerID: Self.alice,
            dictionary: AnyWordList(),
            // The guest's countdown lags the host's and is held open here.
            sleepFor: { _ in while !gate.open { try await Task.sleep(for: .milliseconds(1)) } }
        )
        let swallow = SwallowFirstGrant(to: Self.bob)
        await first.setDropFilter { swallow($0) }
        host.startMatch(seed: 8, startingHandSize: handSize, countdownSeconds: 2)
        try await Self.waitUntil("the guest to be counting down") {
            if case .countdown = guest.state.status { return true }
            return false
        }
        try await Self.waitUntil("the host to be playing with a hand") {
            host.state.status == .playing && host.state.hand.count == handSize
        }

        // A one-tile round arriving while the guest is still in `.countdown`.
        #expect(host.draw())
        try await Self.waitUntil("the round to reach the guest") { !guest.state.hand.isEmpty }

        // Misfired on the phase alone: one tile, taken as a whole opening hand,
        // no obligation — and the hand size never entered into it.
        #expect(guest.state.hand.count == 1)
        #expect(guest.pendingDrawTiles.isEmpty)
        #expect(guest.hasPendingDraw == false)

        gate.open = true
        try await Self.waitUntil("the guest to be playing") { guest.state.status == .playing }
    }

    /// The `applyStart` clamp still holds with a real deal behind it: a hand
    /// size of zero deals nothing and raises no obligation.
    @Test("A zero hand size deals nothing on either device")
    func zeroHandSizeDealsNothing() async throws {
        let (host, guest, _) = try await Self.livePair(countdownSeconds: 0, handSize: 0)
        try await Self.settle()
        #expect(host.state.hand.isEmpty)
        #expect(guest.state.hand.isEmpty)
        #expect(host.pendingDrawTiles.isEmpty)
        #expect(guest.pendingDrawTiles.isEmpty)

        // And a round after a dealless start is a normal obligation.
        #expect(host.draw())
        try await Self.waitUntil("the round to be held") { guest.hasPendingDraw }
        #expect(guest.pendingDrawTiles.count == 1)
        #expect(guest.state.hand.isEmpty)
    }

    /// A negative hand size off the wire is clamped and cannot arm the deal.
    @Test("A negative hand size off the wire deals nothing")
    func negativeHandSizeIsClamped() async throws {
        let (wire, endpoint) = FakeTransport.pair(Self.alice, Self.bob)
        let guest = MatchSession(
            transport: endpoint, peerPlayerID: Self.alice, dictionary: AnyWordList(), sleepFor: { _ in }
        )
        try await wire.send(
            .start(version: WireFormat.current, seed: 2, startingHandSize: -4, countdownSeconds: 0),
            delivery: .reliable
        )
        try await Self.waitUntil("the guest to be playing") { guest.state.status == .playing }
        #expect(guest.startingHandSize == 0)

        try await wire.send(.grant(player: Self.bob, tiles: [Tile(letter: "A")]), delivery: .reliable)
        try await Self.waitUntil("the grant to be held") { guest.hasPendingDraw }
        #expect(guest.pendingDrawTiles.count == 1)
        #expect(guest.state.hand.isEmpty)
    }
}
