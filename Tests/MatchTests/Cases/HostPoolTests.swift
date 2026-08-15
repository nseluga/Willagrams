import Testing
import WillagramsRules
@testable import Match

/// Every case here drives the real entry point — a request sent from the guest
/// endpoint, read off the host's real inbound stream — and asserts on what
/// actually reached the peer, never on a flag the host set for itself. Every
/// await on a stream races the `outcome` deadline, so a message that never
/// arrives fails this run rather than hanging it.
@Suite("Host pool authority")
struct HostPoolTests {

    private let hostID = PlayerID(rawValue: "alpha-host")
    private let guestID = PlayerID(rawValue: "beta-guest")

    // MARK: - Driving one request through the wire

    /// Sends `request` from the guest, lets the host answer it off its own
    /// inbound stream, then ends the match so the guest's stream finishes.
    ///
    /// Draining the guest's stream to completion — rather than reading a fixed
    /// number of elements — is what makes "and nothing else was sent" a real
    /// assertion instead of "nothing else has arrived yet".
    ///
    /// - Returns: every message the guest received, or nil if the host never
    ///   saw the request.
    private func exchange(
        _ request: MatchMessage,
        with authority: HostPool,
        host: FakeTransport,
        guest: FakeTransport
    ) async throws -> [MatchMessage]? {
        try await guest.send(request, delivery: .reliable)

        let pumped = await outcome { () -> Bool in
            for await inbound in host.inboundMessages {
                await authority.handle(inbound)
                return true
            }
            return false
        }
        #expect(pumped == true, "the host never received the request")

        host.leave()
        return await outcome { () -> [MatchMessage] in
            var seen: [MatchMessage] = []
            for await message in guest.inboundMessages { seen.append(message) }
            return seen
        }
    }

    private func grantedTiles(in messages: [MatchMessage]) -> [PlayerID: [Tile]] {
        var granted: [PlayerID: [Tile]] = [:]
        for message in messages {
            if case let .grant(player, tiles) = message { granted[player] = tiles }
        }
        return granted
    }

    // MARK: - The fan-out

    @Test("One draw request grows both racks by exactly one, whichever player asked")
    func drawGrantsOneTileToEachPlayer() async throws {
        for requester in [hostID, guestID] {
            let (host, guest) = FakeTransport.pair(hostID, guestID)
            let start = Pool.standard(seed: 7)
            let authority = HostPool(
                players: (hostID, guestID), pool: start, seed: 99, transport: host
            )

            let received = try await exchange(
                .drawRequest(player: requester), with: authority, host: host, guest: guest
            )
            let messages = try #require(received, "no reply reached the peer")

            #expect(messages.count == 2, "expected one grant per player, got \(messages)")
            let granted = grantedTiles(in: messages)
            #expect(Set(granted.keys) == [hostID, guestID])
            #expect(granted[hostID]?.count == 1)
            #expect(granted[guestID]?.count == 1)

            let grantedIDs = granted.values.flatMap { $0.map(\.id) }
            #expect(Set(grantedIDs).count == 2, "the same tile was handed to both players")

            // Every granted tile came out of the pool that existed before the
            // request, and none of them is still in it afterwards.
            let startIDs = Set(start.tiles.map(\.id))
            #expect(grantedIDs.allSatisfy(startIDs.contains), "a granted tile was not from the pool")

            let after = await authority.pool
            #expect(after.count == start.count - 2)
            #expect(Set(after.tiles.map(\.id)).isDisjoint(with: Set(grantedIDs)))
        }
    }

    // MARK: - Too few tiles to go round

    @Test("A draw request against a pool smaller than the match refuses and takes nothing")
    func drawAgainstAPoolTooSmallToGoRound() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)
        // One tile, two players: nobody can be dealt from this.
        let start = Pool(tiles: [Tile(letter: "Z")])
        let authority = HostPool(players: (hostID, guestID), pool: start, seed: 5, transport: host)

        let received = try await exchange(
            .drawRequest(player: guestID), with: authority, host: host, guest: guest
        )
        let messages = try #require(received, "no reply reached the peer")

        #expect(messages == [.poolExhausted], "expected only poolExhausted, got \(messages)")
        #expect(await authority.pool == start, "a refused request moved the pool")
    }

    // MARK: - Swap

    @Test("A swap request with fewer than three left is refused and the pool is unchanged")
    func swapWithTooFewTilesIsRefused() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)
        let start = Pool(tiles: [Tile(letter: "A"), Tile(letter: "B")])
        let authority = HostPool(players: (hostID, guestID), pool: start, seed: 5, transport: host)

        let received = try await exchange(
            .swapRequest(player: guestID, returning: Tile(letter: "Q")),
            with: authority, host: host, guest: guest
        )
        let messages = try #require(received, "no reply reached the peer")

        #expect(
            messages == [.rejected(reason: .notEnoughTilesToSwap)],
            "expected only a refusal, got \(messages)"
        )
        // Whole-value equality: the pool is byte-identical, not merely the same size.
        #expect(await authority.pool == start, "a refused swap moved the pool")
    }

    @Test("A swap hands back three tiles from the pool and puts the returned one in it")
    func swapGrantsThreeAndTakesOneBack() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)
        let start = Pool.standard(seed: 11)
        let returned = Tile(letter: "Q")
        let authority = HostPool(players: (hostID, guestID), pool: start, seed: 5, transport: host)

        let received = try await exchange(
            .swapRequest(player: guestID, returning: returned),
            with: authority, host: host, guest: guest
        )
        let messages = try #require(received, "no reply reached the peer")

        #expect(messages.count == 1, "expected exactly one reply, got \(messages)")
        guard case let .swapGrant(player, tiles, echoed) = try #require(messages.first) else {
            Issue.record("expected a swapGrant, got \(messages)")
            return
        }
        #expect(player == guestID)
        #expect(echoed == returned)
        #expect(tiles.count == 3)

        let startIDs = Set(start.tiles.map(\.id))
        #expect(tiles.map(\.id).allSatisfy(startIDs.contains), "a granted tile was not from the pool")
        #expect(!tiles.contains(returned), "the swap handed back the tile it was given")

        let after = await authority.pool
        #expect(after.count == start.count - 2, "three out and one in")
        #expect(after.tiles.contains(returned), "the returned tile never went back")
        #expect(Set(after.tiles.map(\.id)).isDisjoint(with: Set(tiles.map(\.id))))
    }

    // MARK: - Trust boundary

    @Test("A request naming a player who is not in this match cannot move the pool")
    func requestFromAnUnknownPlayerIsRefused() async throws {
        let stranger = PlayerID(rawValue: "not-in-this-match")
        let requests: [MatchMessage] = [
            .drawRequest(player: stranger),
            .swapRequest(player: stranger, returning: Tile(letter: "Q")),
        ]

        for request in requests {
            let (host, guest) = FakeTransport.pair(hostID, guestID)
            let start = Pool.standard(seed: 3)
            let authority = HostPool(
                players: (hostID, guestID), pool: start, seed: 5, transport: host
            )

            let received = try await exchange(request, with: authority, host: host, guest: guest)
            let messages = try #require(received, "no reply reached the peer")

            #expect(
                messages == [.rejected(reason: .unknownPlayer)],
                "expected only a refusal for \(request), got \(messages)"
            )
            #expect(await authority.pool == start, "a stranger's request moved the pool")
        }
    }

    // MARK: - Election

    @Test("Both devices elect the same host from the same two ids, in either order")
    func electionIsPureAndOrderIndependent() {
        let pairs = [
            ("alpha", "beta"),
            ("zeta", "alpha"),
            ("A", "a"),
            ("player-1", "player-10"),
            ("G:1234567890", "G:0987654321"),
        ]

        for (left, right) in pairs {
            let first = PlayerID(rawValue: left)
            let second = PlayerID(rawValue: right)
            let elected = HostPool.host(of: first, second)

            // Order independence is what lets each device evaluate it locally:
            // neither knows which id the other passed first.
            #expect(elected == HostPool.host(of: second, first), "\(left)/\(right) elected two hosts")
            #expect(elected.rawValue == min(left, right), "the lower rawValue did not win")
        }

        let only = PlayerID(rawValue: "same")
        #expect(HostPool.host(of: only, only) == only)
    }
}
