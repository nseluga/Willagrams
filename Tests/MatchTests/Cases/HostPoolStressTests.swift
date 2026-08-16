import Foundation
import Testing
import WillagramsRules
@testable import Match

/// Every tile the host actually handed to a player, swap grants included and
/// the returned tile excluded.
///
/// Distinct from the shared `grants(in:)`, which only sees `.grant`, and from
/// `tileIDs(in:)`, which counts a swap's *returned* tile too — the opposite of
/// what "was this tile handed out twice" needs.
private func handedOut(in messages: [MatchMessage]) -> [(player: PlayerID, tiles: [Tile])] {
    messages.compactMap { (message) -> (player: PlayerID, tiles: [Tile])? in
        switch message {
        case let .grant(player, tiles): return (player, tiles)
        case let .swapGrant(player, tiles, _): return (player, tiles)
        default: return nil
        }
    }
}

/// The pool under real contention.
///
/// ``HostPoolAdversarialTests`` races two callers. Two is not enough to trust an
/// actor that suspends mid-request: the failure this covers — the same tile
/// handed to both players — needs enough concurrent requests that the window
/// between `Pool.draw` and the `await` on the wire is actually entered while
/// another caller is inside it. Twenty requests against a pool that cannot serve
/// them all is that.
///
/// Wire *order* is deliberately not asserted anywhere here. `HostPool.handle(_:)`
/// documents single-caller serialization as a precondition and these tests break
/// it on purpose, so order across concurrent callers is undefined by contract;
/// what must hold regardless is that no tile leaves the pool twice and the pool
/// balances.
@Suite("Host pool authority under load")
struct HostPoolStressTests {

    private let hostID = PlayerID(rawValue: "alpha-host")
    private let guestID = PlayerID(rawValue: "beta-guest")

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// Distinct tiles with distinct ids, so "the same tile twice" is a real
    /// question rather than two tiles that happen to share a letter.
    private func tiles(_ count: Int) -> [Tile] {
        (0..<count).map { Tile(letter: Self.alphabet[$0 % Self.alphabet.count]) }
    }

    // MARK: - Twenty draws at once

    /// Nine tiles, twenty simultaneous requests, two players. Four rounds can be
    /// served and sixteen cannot, and which is which is not knowable in advance
    /// — but the counts are, because the actor serialises the pool move even
    /// though it does not serialise the wire.
    @Test("Twenty draw requests at once never hand the same tile out twice")
    func concurrentDrawsNeverHandOutATileTwice() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)
        let start = Pool(tiles: tiles(9))
        let startIDs = Set(start.tiles.map(\.id))
        let authority = HostPool(players: (hostID, guestID), pool: start, seed: 42, transport: host)

        let results = await withTaskGroup(of: [MatchMessage].self) { group in
            for _ in 0..<20 {
                group.addTask { await authority.handle(.drawRequest(player: self.guestID)) }
            }
            return await group.reduce(into: [[MatchMessage]]()) { $0.append($1) }
        }
        #expect(results.count == 20)
        #expect(results.allSatisfy { !$0.isEmpty }, "a request under load went unanswered")

        let produced = results.flatMap { $0 }
        let granted = grants(in: produced)
        #expect(granted.count == 8, "nine tiles serve four rounds of two, got \(granted.count) grants")
        #expect(produced.filter { $0 == .poolExhausted }.count == 16, "wrong number of refusals: \(produced.count)")
        #expect(granted.filter { $0.player == self.hostID }.count == 4, "the host was served a different number of times")
        #expect(granted.filter { $0.player == self.guestID }.count == 4, "the peer was served a different number of times")
        #expect(granted.allSatisfy { $0.tiles.count == 1 }, "a rack grew by more than one in a round")

        // The criterion the old "same tile went to both players" failure broke.
        let grantedIDs = granted.flatMap { $0.tiles.map(\.id) }
        #expect(Set(grantedIDs).count == 8, "a tile was handed out twice under load")
        #expect(grantedIDs.allSatisfy(startIDs.contains), "a tile was minted outside the pool")

        // Neither over-drained nor under-drained: what left is exactly what the
        // pool lost, and none of it is still in there.
        let after = await authority.pool
        #expect(after.count == start.count - grantedIDs.count, "the pool did not balance: \(after.count) left")
        #expect(after.count == 1)
        #expect(Set(after.tiles.map(\.id)).isDisjoint(with: Set(grantedIDs)), "a granted tile is still in the pool")

        // The wire still carries the peer's half and only the peer's half, even
        // when twenty requests interleave on it.
        let messages = try #require(await drain(host, guest), "no reply reached the peer")
        #expect(grants(in: messages).count == 4, "the wire should carry the peer's four grants, got \(messages.count) messages")
        #expect(grants(in: messages).allSatisfy { $0.player == self.guestID }, "the host's tiles reached the peer")
        #expect(messages.filter { $0 == .poolExhausted }.count == 16, "the peer heard a different number of refusals")
    }

    // MARK: - Draws and swaps at once

    /// Draws take two and give nothing back; swaps take three and give one back,
    /// through a different frozen entry point and a generator held across
    /// requests. Mixing them is the case where a lost `await` shows up as a tile
    /// that exists in two places at once.
    ///
    /// How many of each are served depends on the order the actor admits them,
    /// so this asserts the conservation law rather than fixed counts.
    @Test("Draws and swaps arriving together conserve every tile")
    func concurrentDrawsAndSwapsConserveThePool() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)
        let start = Pool(tiles: tiles(12))
        let startIDs = Set(start.tiles.map(\.id))
        // A distinct tile per swap: a returned tile legitimately re-enters the
        // pool and may be granted later, so reusing one would make "handed out
        // twice" unanswerable.
        let returning = tiles(10)
        let returningIDs = Set(returning.map(\.id))
        let authority = HostPool(players: (hostID, guestID), pool: start, seed: 42, transport: host)

        let results = await withTaskGroup(of: [MatchMessage].self) { group in
            for _ in 0..<10 {
                group.addTask { await authority.handle(.drawRequest(player: self.guestID)) }
            }
            for tile in returning {
                group.addTask {
                    await authority.handle(.swapRequest(player: self.guestID, returning: tile))
                }
            }
            return await group.reduce(into: [[MatchMessage]]()) { $0.append($1) }
        }
        #expect(results.count == 20)
        #expect(results.allSatisfy { !$0.isEmpty }, "a request under load went unanswered")

        let produced = results.flatMap { $0 }
        let handed = handedOut(in: produced)
        let handedIDs = handed.flatMap { $0.tiles.map(\.id) }
        #expect(Set(handedIDs).count == handedIDs.count, "a tile was handed out twice under load")
        #expect(
            handedIDs.allSatisfy { startIDs.contains($0) || returningIDs.contains($0) },
            "a tile appeared that was never in the pool"
        )

        let swapsServed = produced.filter { if case .swapGrant = $0 { return true } else { return false } }.count
        let after = await authority.pool
        // The conservation law: out, minus what a served swap put back, is
        // exactly what the pool lost. Over-drain and under-drain both fail it.
        #expect(
            after.count == start.count - handedIDs.count + swapsServed,
            "the pool did not balance: \(after.count) left, \(handedIDs.count) out, \(swapsServed) returned"
        )
        #expect(handedIDs.count <= start.count + swapsServed, "more tiles left the pool than ever existed in it")
        #expect(Set(after.tiles.map(\.id)).isDisjoint(with: Set(handedIDs)), "a handed-out tile is still in the pool")

        // Twenty requests, each costing the pool two of twelve tiles: some had
        // to be served and some had to be refused however they interleaved.
        #expect(!handed.isEmpty, "nothing was served at all")
        #expect(
            produced.contains { $0 == .poolExhausted || $0 == .rejected(reason: .notEnoughTilesToSwap) },
            "twenty requests against twelve tiles should have run it out"
        )

        let messages = try #require(await drain(host, guest), "no reply reached the peer")
        let hostsOwnIDs = Set(handed.filter { $0.player == self.hostID }.flatMap { $0.tiles.map(\.id) })
        #expect(handedOut(in: messages).allSatisfy { $0.player == self.guestID }, "the host's grants reached the peer")
        #expect(
            Set(handedOut(in: messages).flatMap { $0.tiles.map(\.id) }).isDisjoint(with: hostsOwnIDs),
            "the host's own tiles reached the peer"
        )
    }

    // MARK: - Both halves of a round

    /// One round now lands in two different places: the peer's grant on the wire
    /// and the host's grant in the return value. Both have to be real movements
    /// of the one pool, and neither may carry the other's tile.
    ///
    /// The second pass runs the pool on the endpoint whose id sorts *second*, so
    /// "keep my own grant off the wire" cannot be reading the sorted player list
    /// instead of `transport.localPlayerID`.
    @Test("Both halves of a round are real, whichever device holds the pool")
    func bothHalvesOfARoundAreReal() async throws {
        for poolHolderSortsFirst in [true, false] {
            let localID = poolHolderSortsFirst ? hostID : PlayerID(rawValue: "zulu-device")
            let peerID = poolHolderSortsFirst ? guestID : PlayerID(rawValue: "alpha-peer")
            let (local, peer) = FakeTransport.pair(localID, peerID)
            let start = Pool(tiles: tiles(6))
            let authority = HostPool(players: (localID, peerID), pool: start, seed: 17, transport: local)

            try await peer.send(.drawRequest(player: peerID), delivery: .reliable)
            let produced = try #require(
                await pump(1, from: local, into: authority), "the host never received the request"
            ).flatMap { $0 }
            let received = try #require(await drain(local, peer), "the peer's stream never finished")

            let granted = grants(in: produced)
            #expect(granted.count == 2, "expected one grant per player, got \(produced)")
            let mine = try #require(granted.first { $0.player == localID }?.tiles, "the pool holder was not granted a tile")
            let theirs = try #require(granted.first { $0.player == peerID }?.tiles, "the peer was not granted a tile")

            // Half one, on the wire: the peer's grant and nothing else.
            #expect(received == [.grant(player: peerID, tiles: theirs)], "the wire carried \(received)")

            // Half two, in the return value: the host's grant moved real tiles
            // out of the one pool rather than naming tiles it still holds.
            let after = await authority.pool
            let mineIDs = Set(mine.map(\.id))
            let theirsIDs = Set(theirs.map(\.id))
            #expect(mineIDs.isDisjoint(with: theirsIDs), "the same tile appeared in both grants")
            #expect(Set(after.tiles.map(\.id)).isDisjoint(with: mineIDs), "the host's grant left its tiles in the pool")
            #expect(Set(after.tiles.map(\.id)).isDisjoint(with: theirsIDs), "the peer's grant left its tiles in the pool")
            #expect(Set(start.tiles.map(\.id)).isSuperset(of: mineIDs.union(theirsIDs)), "a granted tile was not from the pool")
            #expect(after.count == start.count - 2, "two players, two tiles, one round")
        }
    }
}
