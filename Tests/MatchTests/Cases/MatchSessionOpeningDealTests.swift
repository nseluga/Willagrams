import Foundation
import Testing
import WillagramsRules
@testable import Match

/// The opening deal: the host draws both hands when the countdown reaches zero
/// and grants them, and the receiving side reads the *phase* to tell that grant
/// from a peer's draw.
///
/// Wire v1 has one `.grant` case for both, so the placement rule is the whole of
/// the feature and is asserted directly — a countdown grant and a playing grant
/// carrying the same letters must land in different places.
@MainActor
@Suite("Match session opening deal")
struct MatchSessionOpeningDealTests {

    struct AnyWordList: WordList {
        func contains(_ word: String) -> Bool { true }
    }

    /// Lets a test hold a session inside its countdown and release it on demand,
    /// without spending real seconds.
    @MainActor
    final class Gate {
        var open = false
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

    /// Two real sessions on a real fake wire. `first` is alice, who is elected
    /// host by id and so is the device that opens the match and holds the pool.
    static func pair(
        countdownSeconds: Int,
        handSize: Int
    ) async throws -> (host: MatchSession, guest: MatchSession) {
        let (first, second) = FakeTransport.pair(alice, bob)
        // A countdown that costs no time, so a ticking start is as fast as a
        // zero-second one.
        let host = MatchSession(
            transport: first,
            peerPlayerID: bob,
            dictionary: AnyWordList(),
            sleepFor: { _ in }
        )
        let guest = MatchSession(
            transport: second,
            peerPlayerID: alice,
            dictionary: AnyWordList(),
            sleepFor: { _ in }
        )
        host.startMatch(seed: 11, startingHandSize: handSize, countdownSeconds: countdownSeconds)
        try await waitUntil("both sessions playing") {
            host.state.status == .playing && guest.state.status == .playing
        }
        return (host, guest)
    }

    @Test("Both players hold a full hand once the countdown reaches zero", arguments: [0, 3])
    func countdownEndDealsBothHands(countdownSeconds: Int) async throws {
        let handSize = 7
        let (host, guest) = try await Self.pair(countdownSeconds: countdownSeconds, handSize: handSize)

        try await Self.waitUntil("both hands dealt") {
            host.state.hand.count == handSize && guest.state.hand.count == handSize
        }
        // The deal is not an obligation: nothing waits behind the Draw button.
        #expect(host.pendingDrawTiles.isEmpty)
        #expect(guest.pendingDrawTiles.isEmpty)

        // No tile reaches two racks.
        let hostIDs = Set(host.state.hand.map(\.id))
        let guestIDs = Set(guest.state.hand.map(\.id))
        #expect(hostIDs.count == handSize)
        #expect(hostIDs.isDisjoint(with: guestIDs))
    }

    @Test("A hand size of zero deals nothing and leaves the board open")
    func zeroHandSizeDealsNothing() async throws {
        let (host, guest) = try await Self.pair(countdownSeconds: 0, handSize: 0)
        #expect(host.state.hand.isEmpty)
        #expect(guest.state.hand.isEmpty)
        #expect(guest.pendingDrawTiles.isEmpty)
    }

    @Test("The same grant lands in hand during the countdown and behind the obligation in play")
    func phaseDecidesWhereAGrantLands() async throws {
        let gate = Gate()
        let (wire, endpoint) = FakeTransport.pair(Self.alice, Self.bob)
        // Bob is not the elected host, so this session holds no pool and every
        // grant it sees comes off the wire — the path under test.
        let guest = MatchSession(
            transport: endpoint,
            peerPlayerID: Self.alice,
            dictionary: AnyWordList(),
            sleepFor: { _ in
                while !gate.open { try await Task.sleep(for: .milliseconds(1)) }
            }
        )

        try await wire.send(
            .start(version: WireFormat.current, seed: 4, startingHandSize: 2, countdownSeconds: 3),
            delivery: .reliable
        )
        try await Self.waitUntil("the guest to be counting down") {
            guest.state.status == .countdown(secondsRemaining: 3)
        }

        // Identical shape, identical letters, distinct ids — a grant repeating a
        // tile the rack already holds is dropped as a duplicate, so "the same
        // bytes" has to mean the same payload freshly minted.
        let dealt = [Tile(letter: "A"), Tile(letter: "B")]
        let drawn = [Tile(letter: "A"), Tile(letter: "B")]

        try await wire.send(.grant(player: Self.bob, tiles: dealt), delivery: .reliable)
        try await Self.waitUntil("the opening deal in hand") { guest.state.hand.count == 2 }
        #expect(guest.state.hand.map(\.id) == dealt.map(\.id))
        #expect(guest.pendingDrawTiles.isEmpty)
        #expect(guest.hasPendingDraw == false)

        gate.open = true
        try await Self.waitUntil("the guest to be playing") { guest.state.status == .playing }

        try await wire.send(.grant(player: Self.bob, tiles: drawn), delivery: .reliable)
        try await Self.waitUntil("the peer's round to be waiting") { guest.hasPendingDraw }
        // Same message, played phase: held behind the obligation, not taken.
        #expect(guest.pendingDrawTiles.map(\.id) == drawn.map(\.id))
        #expect(guest.state.hand.map(\.id) == dealt.map(\.id))

        // And the obligation still resolves the way it always did.
        #expect(guest.draw())
        #expect(guest.pendingDrawTiles.isEmpty)
        #expect(guest.state.hand.count == 4)
    }

    /// The deal is enqueued, and a freeze can land between the enqueue and the
    /// work running. Dropped there it would never happen again: the countdown is
    /// spent, so both racks would stay empty for a match that goes on to be
    /// played.
    ///
    /// The guest's half is asserted as the grant that reached the wire rather
    /// than through a second session: `GatedTransport` is the only fake that can
    /// freeze and thaw without finishing its streams, and it is not paired.
    /// Where that grant lands once it arrives is covered by the phase test above.
    @Test("A freeze at the moment of the deal defers it to the peer's return")
    func aFreezeAtCountdownEndDefersTheDeal() async throws {
        let handSize = 7
        let wire = MatchSessionTerminalTests.PresenceTransport(
            localPlayerID: Self.alice,
            peer: Self.bob
        )
        let host = MatchSession(
            transport: wire,
            peerPlayerID: Self.bob,
            dictionary: AnyWordList(),
            // Only the reconnect window reads the clock here, and it must not
            // expire: an expired window ends the match instead of thawing it.
            sleepFor: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )

        // The gate parks the `.start` send, so the deal is enqueued behind it
        // and has not run when the peer goes.
        await wire.closeGate()
        host.startMatch(seed: 6, startingHandSize: handSize, countdownSeconds: 0)
        let limit = ContinuousClock.now + .seconds(2)
        while await wire.parkedCount == 0, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await wire.parkedCount == 1)

        wire.drop(Self.bob)
        try await Self.waitUntil("the freeze") {
            if case .reconnecting = host.peerPresence { return true }
            return false
        }

        // The deal now runs, sees the lock, and must put itself back.
        await wire.releaseAll()
        while await wire.count == 0, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await wire.count == 1)
        #expect(host.state.hand.isEmpty)

        wire.restore(Self.bob)
        try await Self.waitUntil("the deal to land after the thaw") {
            host.state.hand.count == handSize
        }
        let grants = await wire.wire.filter {
            if case let .grant(player, tiles) = $0 { return player == Self.bob && tiles.count == handSize }
            return false
        }
        #expect(grants.count == 1)
        #expect(host.pendingDrawTiles.isEmpty)
    }

    @Test("One deal takes both hands out of one pool")
    func dealMovesThePoolOnce() async throws {
        let (transport, _) = FakeTransport.pair(Self.alice, Self.bob)
        let pool = Pool.standard(seed: 5)
        let hostPool = HostPool(
            players: (Self.alice, Self.bob),
            pool: pool,
            seed: 5,
            transport: transport
        )
        let handSize = 5

        let produced = await hostPool.deal(handSize: handSize)
        #expect(produced.count == 2)

        let tiles = produced.flatMap { message -> [Tile] in
            guard case let .grant(_, tiles) = message else { return [] }
            return tiles
        }
        #expect(tiles.count == handSize * 2)
        #expect(Set(tiles.map(\.id)).count == handSize * 2)
        #expect(await hostPool.pool.count == pool.count - handSize * 2)
    }

    @Test("A pool too small to deal both hands deals neither")
    func aShortPoolDealsNothing() async throws {
        let (transport, _) = FakeTransport.pair(Self.alice, Self.bob)
        let hostPool = HostPool(
            players: (Self.alice, Self.bob),
            pool: Pool(tiles: [Tile(letter: "A"), Tile(letter: "B"), Tile(letter: "C")]),
            seed: 1,
            transport: transport
        )
        #expect(await hostPool.deal(handSize: 2).isEmpty)
        #expect(await hostPool.pool.count == 3)
    }
}
