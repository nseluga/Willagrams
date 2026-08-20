import Foundation
import Testing
import WillagramsRules
@testable import Match

/// Regression for the deal dropped by a freeze that lands mid-enqueue.
///
/// `dealOpeningHands()` clears `awaitingOpeningDeal` synchronously and does the
/// dealing after a suspension. A freeze arriving in that gap made the closure
/// bail with the flag already spent, so the countdown was gone, the host would
/// never deal again, and the guest's flag was left armed on a deal that was
/// never coming — both racks empty for the rest of a match that goes on to be
/// played.
///
/// This drives the real path, not a re-derivation: the freeze is delivered on
/// the session's own connection-state stream, the deal really sits parked on the
/// session's chain behind a real `transport.send`, and the recovery is the
/// production `.connected` that `peerReturned()` handles.
@MainActor
@Suite("Match session opening deal across a reconnect")
struct MatchSessionOpeningDealReconnectTests {

    struct AnyWordList: WordList {
        func contains(_ word: String) -> Bool { true }
    }

    static let alice = PlayerID(rawValue: "alice")
    static let bob = PlayerID(rawValue: "bob")

    /// The transport is `MatchSessionTerminalTests.PresenceTransport`: it keeps
    /// both streams open across a drop — which `FakeTransport.leave()` cannot —
    /// and its gate parks a send *inside* the transport, which is what puts the
    /// deal on the chain behind it with no sleep and no race to lose.
    typealias PresenceTransport = MatchSessionTerminalTests.PresenceTransport

    static func waitUntil(_ label: String, _ condition: () async -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(2)
        while await !condition() {
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

    @Test("A freeze between the enqueue and the deal is recovered when the peer comes back")
    func theDealSurvivesAFreezeAtTheMomentItIsEnqueued() async throws {
        let handSize = 6
        let hostWire = PresenceTransport(localPlayerID: Self.alice, peer: Self.bob)
        let guestWire = PresenceTransport(localPlayerID: Self.bob, peer: Self.alice)
        let host = MatchSession(
            transport: hostWire,
            peerPlayerID: Self.bob,
            dictionary: AnyWordList(),
            // Only the reconnect window uses this — the countdown is zero. It must
            // not expire on its own, or the peer is `.gone` before it returns.
            sleepFor: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        let guest = MatchSession(
            transport: guestWire, peerPlayerID: Self.alice, dictionary: AnyWordList(), sleepFor: { _ in }
        )

        // The `.start` send parks inside the transport, so the deal enqueued right
        // behind it is stuck on the chain at exactly the moment under test.
        await hostWire.closeGate()
        host.startMatch(seed: 77, startingHandSize: handSize, countdownSeconds: 0)
        try await Self.waitUntil("the start send to park") { await hostWire.parkedCount == 1 }
        #expect(host.state.status == .playing)
        #expect(host.state.hand.isEmpty)

        // The peer drops while the deal is parked.
        hostWire.drop(Self.bob)
        try await Self.waitUntil("the host to freeze") { host.peerPresence != .present }

        // The chain drains into a frozen session: the deal bails out. Gate on the
        // parked `.start` actually reaching the wire, not on a fixed sleep — an
        // empty hand alone cannot tell "bailed and re-armed" from "not run yet",
        // and the deal is chained strictly behind that send.
        await hostWire.releaseAll()
        try await Self.waitUntil("the parked start to reach the wire") { await hostWire.count == 1 }
        #expect(host.state.hand.isEmpty)
        #expect(guest.state.hand.isEmpty)

        // The peer comes back, inside the window. Nothing else is called.
        hostWire.restore(Self.bob)
        try await Self.waitUntil("the host to be present again") { host.peerPresence == .present }
        try await Self.waitUntil("the host's own hand") { host.state.hand.count == handSize }

        // Exactly one grant for the peer went out: the re-arm must not put a
        // second opening hand on the wire.
        let grants = await hostWire.wire.filter {
            if case let .grant(player, tiles) = $0 { return player == Self.bob && tiles.count == handSize }
            return false
        }
        #expect(grants.count == 1)

        // Everything the host really put on the wire, in landing order, into the
        // guest's real inbound stream: the `.start` it missed, then the deal.
        for message in await hostWire.wire { guestWire.deliver(message) }
        try await Self.waitUntil("the guest's hand") { guest.state.hand.count == handSize }

        // Both racks hold a full opening hand, out of one pool, and nothing is
        // stuck behind the Draw button on either device.
        #expect(host.state.hand.count == handSize)
        #expect(guest.state.hand.count == handSize)
        #expect(host.pendingDrawTiles.isEmpty)
        #expect(guest.pendingDrawTiles.isEmpty)
        #expect(host.hasPendingDraw == false)
        #expect(guest.hasPendingDraw == false)
        let hostIDs = Set(host.state.hand.map(\.id))
        let guestIDs = Set(guest.state.hand.map(\.id))
        #expect(hostIDs.union(guestIDs).count == handSize * 2)

        // And it deals once: the re-arm must not leave a second hand behind it.
        try await Self.settle()
        #expect(host.state.hand.count == handSize)
        #expect(guest.state.hand.count == handSize)

        host.leave()
        guest.leave()
        await hostWire.releaseAll()
    }

    /// The clamp the reviewer moved to half the pool: above it, `HostPool.deal`
    /// needs more tiles than the pool holds and silently deals nothing.
    @Test("A hand size the pool cannot deal is refused, not started")
    func aHandSizeAboveHalfThePoolIsRefused() async throws {
        let (wire, endpoint) = FakeTransport.pair(Self.alice, Self.bob)
        let guest = MatchSession(
            transport: endpoint, peerPlayerID: Self.alice, dictionary: AnyWordList(), sleepFor: { _ in }
        )
        try await wire.send(
            .start(
                version: WireFormat.current,
                seed: 3,
                startingHandSize: LetterDistribution.totalTiles,
                countdownSeconds: 0,
                options: .standard
            , roster: [Self.alice, Self.bob]),
            delivery: .reliable
        )
        // Refused at the wire, not clamped into something the sender never
        // asked for: a hand this size is a modified peer, and the host that
        // opened this match validated the same message before it sent it.
        try await Self.waitUntil("the guest to refuse the start") { guest.lastNote != nil }
        #expect(guest.state.status == .countdown(secondsRemaining: 0))
        #expect(guest.startingHandSize == 0)

        // Half the pool is the largest hand that is *not* refused, and a real
        // pool serves it to both players.
        let servable = LetterDistribution.totalTiles / 2
        let (transport, _) = FakeTransport.pair(Self.alice, Self.bob)
        let hostPool = HostPool(
            players: [Self.alice, Self.bob], pool: Pool.standard(seed: 3), seed: 3, transport: transport
        )
        let produced = await hostPool.deal(handSize: servable)
        var perPlayer: [PlayerID: [Tile]] = [:]
        for case let .grant(player, tiles) in produced { perPlayer[player, default: []] += tiles }
        #expect(perPlayer[Self.alice]?.count == servable)
        #expect(perPlayer[Self.bob]?.count == servable)
    }
}
