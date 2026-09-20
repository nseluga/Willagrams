import Foundation
import Testing
import WillagramsRules
@testable import Match

/// The guest's bag: `HostPool` broadcasts `.poolCount` after every movement of
/// the pool, and a guest shows it. Informational only — the guards here are
/// what stop a peer's number overriding the pool's own device or growing it.
@MainActor
@Suite("Guest pool count")
struct MatchSessionPoolCountTests {
    typealias T = MatchSessionTests

    @Test("A guest's count matches the host's after the deal, a round and a swap")
    func guestTracksTheHostsPool() async throws {
        let alice = PlayerID(rawValue: "alice")
        let bob = PlayerID(rawValue: "bob")
        let (first, second) = FakeTransport.pair(alice, bob)
        let host = MatchSession(transport: first, peerPlayerID: bob, dictionary: T.AnyWordList())
        let guest = MatchSession(transport: second, peerPlayerID: alice, dictionary: T.AnyWordList())
        #expect(HostPool.host(of: [alice, bob]) == alice)

        let total = LetterDistribution.totalTiles
        host.startMatch(seed: 7, startingHandSize: 5, countdownSeconds: 0, options: .standard)

        // Each step waits for the host to have moved, then for the guest to agree.
        try await T.waitUntil("deal: counts agree") {
            host.poolRemaining == total - 10 && guest.poolRemaining == host.poolRemaining
        }
        #expect(guest.poolRemaining == total - 10)

        try await T.drawRound(by: guest, other: host)
        try await T.waitUntil("round: counts agree") {
            host.poolRemaining == total - 12 && guest.poolRemaining == host.poolRemaining
        }
        #expect(guest.poolRemaining == total - 12)

        let returning = try #require(guest.state.hand.first)
        #expect(guest.swap(returning))
        try await T.waitUntil("swap: counts agree") {
            host.poolRemaining == total - 14 && guest.poolRemaining == host.poolRemaining
        }
        #expect(guest.poolRemaining == total - 14)
    }

    @Test("A guest keeps the smallest in-range count; the pool's device keeps its own")
    func receiveGuards() async throws {
        let alice = PlayerID(rawValue: "alice")
        let bob = PlayerID(rawValue: "bob")
        let roster = [alice, bob]

        // Guest side: `first` is a raw host that sends whatever it likes.
        let (first, second) = FakeTransport.pair(alice, bob)
        let guest = MatchSession(transport: second, peerPlayerID: alice, dictionary: T.AnyWordList())
        try await first.send(
            .start(version: WireFormat.current, seed: 1, startingHandSize: 0, countdownSeconds: 0, options: .standard, roster: roster),
            delivery: .reliable
        )
        try await T.waitUntil("the guest to start playing") { guest.state.status == .playing }

        // Each bad count is followed by a sentinel the guest does observe, so
        // "nothing changed" is read after the count was processed, not before.
        // The tile sentinels are obligations rather than grants: a grant goes
        // straight to the rack, and `pendingDrawTiles` is the queue that is
        // easiest to count from outside.
        // Above the pool, onto a nil count, so `min` cannot hide it.
        try await first.send(.poolCount(remaining: MatchLimits.poolSize + 1), delivery: .reliable)
        try await first.send(.poolExhausted(requester: bob), delivery: .reliable)
        try await T.waitUntil("sentinel: exhaustion latch") { guest.poolIsExhausted }
        #expect(guest.poolRemaining == nil, "145 was shown")

        try await first.send(.poolCount(remaining: 90), delivery: .reliable)
        try await T.waitUntil("90 lands") { guest.poolRemaining == 90 }

        try await first.send(.poolCount(remaining: 95), delivery: .reliable)
        try await first.send(.obligation(player: bob, tiles: [Tile(letter: "A")]), delivery: .reliable)
        try await T.waitUntil("sentinel obligation 1") { guest.pendingDrawTiles.count == 1 }
        #expect(guest.poolRemaining == 90, "a late 95 grew the pool")

        try await first.send(.poolCount(remaining: -1), delivery: .reliable)
        try await first.send(.obligation(player: bob, tiles: [Tile(letter: "B")]), delivery: .reliable)
        try await T.waitUntil("sentinel obligation 2") { guest.pendingDrawTiles.count == 2 }
        #expect(guest.poolRemaining == 90, "-1 was shown")

        // Host side: `bob` is raw, `alice` runs the pool.
        let (hostEnd, peerEnd) = FakeTransport.pair(alice, bob)
        let host = MatchSession(transport: hostEnd, peerPlayerID: bob, dictionary: T.AnyWordList())
        host.startMatch(seed: 1, startingHandSize: 0, countdownSeconds: 0, options: .standard)
        try await T.waitUntil("the host to start playing") { host.state.status == .playing }
        let own = try #require(host.poolRemaining)
        try await peerEnd.send(.poolCount(remaining: 90), delivery: .reliable)
        // No sentinel exists here: anything the host observes also moves its
        // pool and re-reads the count, which would mask the guard. A bounded
        // wait instead — the mutation check confirms it is long enough.
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.poolRemaining == own, "the host showed the peer's count")
    }
}
