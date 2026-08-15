import Foundation
import Testing
import WillagramsRules
@testable import Match

// MARK: - Shared harness

// Used by both host-pool suites. File scope rather than a method on either, so
// there is one pump and one drain in this target instead of a copy per suite.

/// Reads exactly `count` messages off `transport` and hands each to the host.
///
/// One subscription, one pass — a second iterator on the same stream would
/// divide the elements between them and read as a lost message.
///
/// - Returns: what each handled message produced, in order. Fewer entries than
///   `count` means the host never saw that many; nil means the deadline won.
func pump(
    _ count: Int,
    from transport: FakeTransport,
    into authority: HostPool
) async -> [[MatchMessage]]? {
    await outcome {
        var produced: [[MatchMessage]] = []
        for await inbound in transport.inboundMessages {
            produced.append(await authority.handle(inbound))
            if produced.count == count { break }
        }
        return produced
    }
}

/// Ends the match and reads the peer's stream to completion, so "and nothing
/// else was sent" is an assertion rather than a race.
func drain(_ host: FakeTransport, _ guest: FakeTransport) async -> [MatchMessage]? {
    host.leave()
    return await outcome {
        var seen: [MatchMessage] = []
        for await message in guest.inboundMessages { seen.append(message) }
        return seen
    }
}

/// Grants as pairs, not a dictionary keyed by player: two grants to the same
/// player must stay two entries, since collapsing them is exactly the bug.
func grants(in messages: [MatchMessage]) -> [(player: PlayerID, tiles: [Tile])] {
    messages.compactMap { message in
        if case let .grant(player, tiles) = message { return (player, tiles) }
        return nil
    }
}

/// Every tile id anywhere in `messages`. The privacy rule is a claim about
/// which of these must *not* appear, so it needs all of them.
func tileIDs(in messages: [MatchMessage]) -> Set<UUID> {
    var ids: Set<UUID> = []
    for message in messages {
        switch message {
        case let .grant(_, tiles):
            ids.formUnion(tiles.map(\.id))
        case let .swapGrant(_, tiles, returned):
            ids.formUnion(tiles.map(\.id))
            ids.insert(returned.id)
        default:
            break
        }
    }
    return ids
}

// MARK: - Suite

/// Every case here drives the real entry point — a request sent from the guest
/// endpoint, read off the host's real inbound stream — and asserts on both what
/// the request produced and what actually reached the peer, never on a flag the
/// host set for itself. Every await on a stream races the `outcome` deadline, so
/// a message that never arrives fails this run rather than hanging it.
@Suite("Host pool authority")
struct HostPoolTests {

    private let hostID = PlayerID(rawValue: "alpha-host")
    private let guestID = PlayerID(rawValue: "beta-guest")

    /// Sends `request` from the guest, lets the host answer it off its own
    /// inbound stream, then ends the match and reads the peer's stream out.
    ///
    /// - Returns: what the request produced, and everything the peer received.
    ///   The two differ on purpose — see `HostPool.handle(_:)`.
    private func exchange(
        _ request: MatchMessage,
        with authority: HostPool,
        host: FakeTransport,
        guest: FakeTransport
    ) async throws -> (produced: [MatchMessage], received: [MatchMessage]) {
        try await guest.send(request, delivery: .reliable)
        let produced = try #require(
            await pump(1, from: host, into: authority), "the host never received the request"
        )
        let received = try #require(await drain(host, guest), "the peer's stream never finished")
        return (produced.flatMap { $0 }, received)
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

            let (produced, received) = try await exchange(
                .drawRequest(player: requester), with: authority, host: host, guest: guest
            )

            // One grant per player, from one request.
            let granted = grants(in: produced)
            #expect(produced.count == 2, "expected one grant per player, got \(produced)")
            #expect(granted.count == 2, "expected two grants, got \(produced)")
            #expect(Set(granted.map(\.player)) == [hostID, guestID])
            #expect(granted.allSatisfy { $0.tiles.count == 1 }, "a rack grew by more than one")

            let grantedIDs = granted.flatMap { $0.tiles.map(\.id) }
            #expect(Set(grantedIDs).count == 2, "the same tile was handed to both players")

            // Every granted tile came out of the pool that existed before the
            // request, and none of them is still in it afterwards.
            let startIDs = Set(start.tiles.map(\.id))
            #expect(grantedIDs.allSatisfy(startIDs.contains), "a granted tile was not from the pool")

            let after = await authority.pool
            #expect(after.count == start.count - 2)
            #expect(Set(after.tiles.map(\.id)).isDisjoint(with: Set(grantedIDs)))

            // The peer is told what it got and nothing more: the host's tile is
            // the host's business, whoever asked for the round.
            let guestTiles = try #require(granted.first { $0.player == self.guestID }?.tiles)
            #expect(
                received == [.grant(player: guestID, tiles: guestTiles)],
                "the wire should carry the peer's own grant and only that, got \(received)"
            )
        }
    }

    // MARK: - What the peer is not told

    @Test("The peer is never told which tiles the host holds")
    func theHostsOwnTilesStayOffTheWire() async throws {
        let requests: [MatchMessage] = [
            .drawRequest(player: hostID),
            .swapRequest(player: hostID, returning: Tile(letter: "Q")),
        ]

        for request in requests {
            let (host, guest) = FakeTransport.pair(hostID, guestID)
            let start = Pool.standard(seed: 13)
            let authority = HostPool(
                players: (hostID, guestID), pool: start, seed: 21, transport: host
            )

            let (produced, received) = try await exchange(
                request, with: authority, host: host, guest: guest
            )

            // Whatever the host was given, the peer did not see it.
            let hostsOwn = produced.filter { message in
                switch message {
                case let .grant(player, _), let .swapGrant(player, _, _): return player == self.hostID
                default: return false
                }
            }
            #expect(!hostsOwn.isEmpty, "\(request) produced nothing for the host")
            #expect(
                tileIDs(in: received).isDisjoint(with: tileIDs(in: hostsOwn)),
                "\(request) put the host's own tiles on the wire: \(received)"
            )
            #expect(!received.contains { hostsOwn.contains($0) })
        }
    }

    // MARK: - Too few tiles to go round

    @Test("A draw request against a pool smaller than the match refuses and takes nothing")
    func drawAgainstAPoolTooSmallToGoRound() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)
        // One tile, two players: nobody can be dealt from this.
        let start = Pool(tiles: [Tile(letter: "Z")])
        let authority = HostPool(players: (hostID, guestID), pool: start, seed: 5, transport: host)

        let (produced, received) = try await exchange(
            .drawRequest(player: guestID), with: authority, host: host, guest: guest
        )

        #expect(produced == [.poolExhausted], "expected only poolExhausted, got \(produced)")
        // Criterion: no grant reached the peer, asserted on the drained stream.
        #expect(received == [.poolExhausted], "expected only poolExhausted on the wire, got \(received)")
        #expect(grants(in: received).isEmpty, "an exhausted pool still granted tiles")
        #expect(await authority.pool == start, "a refused request moved the pool")
    }

    // MARK: - Swap

    @Test("A swap request with fewer than three left is refused and the pool is unchanged")
    func swapWithTooFewTilesIsRefused() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)
        let start = Pool(tiles: [Tile(letter: "A"), Tile(letter: "B")])
        let authority = HostPool(players: (hostID, guestID), pool: start, seed: 5, transport: host)

        let (produced, received) = try await exchange(
            .swapRequest(player: guestID, returning: Tile(letter: "Q")),
            with: authority, host: host, guest: guest
        )

        #expect(produced == [.rejected(reason: .notEnoughTilesToSwap)])
        #expect(
            received == [.rejected(reason: .notEnoughTilesToSwap)],
            "the player who asked was not told, got \(received)"
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

        let (produced, received) = try await exchange(
            .swapRequest(player: guestID, returning: returned),
            with: authority, host: host, guest: guest
        )

        #expect(produced.count == 1, "expected exactly one answer, got \(produced)")
        // The player who asked is the peer, so this one does belong on the wire.
        #expect(received == produced, "the peer's own swap did not reach it: \(received)")

        guard case let .swapGrant(player, tiles, echoed) = try #require(produced.first) else {
            Issue.record("expected a swapGrant, got \(produced)")
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

            let (produced, received) = try await exchange(
                request, with: authority, host: host, guest: guest
            )

            #expect(produced == [.rejected(reason: .unknownPlayer)], "for \(request), got \(produced)")
            // A stranger's message can only have come down the peer's
            // connection, so the refusal goes back that way.
            #expect(received == [.rejected(reason: .unknownPlayer)], "for \(request), got \(received)")
            #expect(await authority.pool == start, "a stranger's request moved the pool")
        }
    }

    // MARK: - Election

    @Test("Both devices elect the same host from the same two ids, in either order")
    func electionIsPureAndOrderIndependent() {
        // Hardcoded, so this case fails if the rule is reversed — the cases
        // below re-derive their expectation with the same comparator the
        // implementation uses, and would agree with it either way round.
        #expect(
            HostPool.host(of: PlayerID(rawValue: "G:222"), PlayerID(rawValue: "G:111"))
                == PlayerID(rawValue: "G:111")
        )

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
