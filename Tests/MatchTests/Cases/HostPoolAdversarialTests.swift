import Testing
import WillagramsRules
@testable import Match

/// Adversarial cover for the host's pool authority.
///
/// Where ``HostPoolTests`` proves one request behaves, these press on the
/// places a single-request test cannot reach: the same tile handed out across
/// *different* requests, two requests landing at once on the actor, the exact
/// boundaries either side of "too few to go round", and the messages that are
/// not requests at all.
///
/// Every stream await races the `outcome` deadline, so a message that never
/// arrives fails this run rather than hanging an unattended one. Each
/// transport's `inboundMessages` is iterated exactly once per test: a second
/// iterator would divide the elements between them and read as a lost message.
@Suite("Host pool authority under pressure")
struct HostPoolAdversarialTests {

    private let hostID = PlayerID(rawValue: "alpha-host")
    private let guestID = PlayerID(rawValue: "beta-guest")

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// Distinct tiles with distinct ids, so "the same tile twice" is a real
    /// question rather than two different tiles that happen to share a letter.
    private func tiles(_ count: Int) -> [Tile] {
        (0..<count).map { Tile(letter: Self.alphabet[$0 % Self.alphabet.count]) }
    }

    // Driving the real entry point: `pump`, `drain` and `grants` are shared
    // with ``HostPoolTests`` at file scope in that file.

    // MARK: - No tile leaves the pool twice, across the whole match

    /// The within-one-request case is covered elsewhere. This is the harder
    /// one: five tiles, three requests, and the question of whether any tile
    /// granted by the first request can be granted again by the second.
    @Test("Repeated draws to exhaustion never hand the same tile out twice")
    func repeatedDrawsNeverRepeatATile() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)
        let start = Pool(tiles: tiles(5))
        let startIDs = Set(start.tiles.map(\.id))
        let authority = HostPool(players: (hostID, guestID), pool: start, seed: 42, transport: host)

        for _ in 0..<3 {
            try await guest.send(.drawRequest(player: guestID), delivery: .reliable)
        }
        let rounds = try #require(await pump(3, from: host, into: authority))
        // `#require`, not `#expect`: the per-round assertions below index into
        // this, and a run that stops here reports rather than traps.
        try #require(rounds.count == 3, "the host did not answer every request")

        let messages = try #require(await drain(host, guest), "no reply reached the peer")

        // Two rounds go out, the third finds one tile for two players. Counted
        // over what the requests produced: only the peer's own half of each
        // round reaches the wire, so the wire cannot answer "was any tile
        // granted twice" — the host's tiles are the other half of that question.
        let produced = rounds.flatMap { $0 }
        let granted = grants(in: produced)
        #expect(granted.count == 4, "expected two grants per round for two rounds, got \(produced)")
        #expect(produced.last == .poolExhausted, "the third round should have been refused: \(produced)")
        #expect(produced.filter { $0 == .poolExhausted }.count == 1)
        #expect(messages.last == .poolExhausted, "the peer was not told the pool had run out: \(messages)")

        let grantedIDs = granted.flatMap { $0.tiles.map(\.id) }
        #expect(Set(grantedIDs).count == 4, "a tile was granted more than once across requests")
        #expect(grantedIDs.allSatisfy(startIDs.contains), "a granted tile was never in the pool")

        // Each round grew both racks by exactly one.
        for round in 0..<2 {
            let pair = grants(in: rounds[round])
            #expect(Set(pair.map(\.player)) == [hostID, guestID], "round \(round) missed a player")
            #expect(pair.allSatisfy { $0.tiles.count == 1 }, "round \(round) granted more than one tile")
        }

        // Each round put the peer's own grant on the wire, and only that.
        #expect(grants(in: messages).count == 2, "the wire should carry one grant per round: \(messages)")
        #expect(grants(in: messages).allSatisfy { $0.player == guestID }, "the host's tiles reached the peer")

        let after = await authority.pool
        #expect(after.count == 1, "five tiles, four granted")
        #expect(Set(after.tiles.map(\.id)).isDisjoint(with: Set(grantedIDs)), "a granted tile is still in the pool")
    }

    // MARK: - Two requests landing at once

    /// The pool is mutable state behind an actor. Three tiles and two requests
    /// arriving together is the case where a lost `await` would deal four tiles
    /// out of a pool of three, or deal one tile to two players.
    @Test("Two draw requests arriving at once are answered one after the other")
    func concurrentDrawRequestsSerialise() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)
        let start = Pool(tiles: tiles(3))
        let authority = HostPool(players: (hostID, guestID), pool: start, seed: 42, transport: host)

        // Straight at the production entry point, both at once — this is what
        // an inbound pump does when two requests are already buffered. Wire
        // *order* is not serialised across concurrent callers and this does not
        // assert it; what must hold is that the pool moved exactly once.
        let produced = await withTaskGroup(of: [MatchMessage].self) { group in
            for _ in 0..<2 {
                group.addTask { await authority.handle(.drawRequest(player: guestID)) }
            }
            return await group.reduce(into: [MatchMessage]()) { $0 += $1 }
        }

        let messages = try #require(await drain(host, guest), "no reply reached the peer")

        let granted = grants(in: produced)
        #expect(granted.count == 2, "three tiles cannot serve two rounds: \(produced)")
        #expect(produced.filter { $0 == .poolExhausted }.count == 1, "the losing request was not refused: \(produced)")
        #expect(Set(granted.map(\.player)) == [hostID, guestID], "both players should have been served once")
        #expect(Set(granted.flatMap { $0.tiles.map(\.id) }).count == 2, "the same tile went to both players")

        // The peer sees its own grant and the refusal, in some order.
        #expect(messages.count == 2, "expected the peer's grant and the refusal, got \(messages)")
        #expect(grants(in: messages).allSatisfy { $0.player == guestID }, "the host's tile reached the peer")
        #expect(messages.contains(.poolExhausted), "the peer was never told the pool had run out")

        let after = await authority.pool
        #expect(after.count == 1, "the pool should have moved exactly once")
    }

    // MARK: - Either side of the boundary

    @Test("A pool holding exactly one tile per player grants and empties")
    func poolExactlyTheSizeOfTheMatchIsFullyDealt() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)
        let start = Pool(tiles: tiles(2))
        let authority = HostPool(players: (hostID, guestID), pool: start, seed: 1, transport: host)

        for _ in 0..<2 {
            try await guest.send(.drawRequest(player: hostID), delivery: .reliable)
        }
        let produced = try #require(await pump(2, from: host, into: authority)).flatMap { $0 }

        let messages = try #require(await drain(host, guest), "no reply reached the peer")
        #expect(grants(in: produced).count == 2, "two tiles, two players, one round: \(produced)")
        #expect(produced.last == .poolExhausted, "the second round had nothing to give: \(produced)")
        // The host asked, so only the peer's own grant and the refusal go out.
        #expect(grants(in: messages).count == 1, "the wire should carry one grant: \(messages)")
        #expect(messages.last == .poolExhausted, "the peer was not told the pool had run out: \(messages)")
        #expect(await authority.pool.isEmpty)
    }

    @Test("A swap against exactly three tiles is granted, one fewer is refused")
    func swapBoundaryAtThreeTiles() async throws {
        for count in [3, 2] {
            let (host, guest) = FakeTransport.pair(hostID, guestID)
            let start = Pool(tiles: tiles(count))
            let returned = Tile(letter: "Q")
            let authority = HostPool(players: (hostID, guestID), pool: start, seed: 8, transport: host)

            try await guest.send(.swapRequest(player: guestID, returning: returned), delivery: .reliable)
            #expect(await pump(1, from: host, into: authority)?.count == 1)

            // The peer asked, so its answer belongs on the wire either way.
            let messages = try #require(await drain(host, guest), "no reply reached the peer")
            #expect(messages.count == 1, "expected exactly one reply for \(count) tiles, got \(messages)")

            let after = await authority.pool
            if count == 3 {
                guard case let .swapGrant(_, handed, echoed) = try #require(messages.first) else {
                    Issue.record("three tiles should be swappable, got \(messages)")
                    return
                }
                #expect(handed.count == 3)
                #expect(echoed == returned)
                #expect(after.count == 1, "three out, one back in")
            } else {
                #expect(messages == [.rejected(reason: .notEnoughTilesToSwap)])
                #expect(after == start, "a refused swap moved the pool")
            }
        }
    }

    // MARK: - Every refusal leaves the pool byte-identical

    /// Whole-`Pool` equality, not a count: a refusal that reordered the tiles
    /// or replaced one with an equal-lettered copy would pass a count check and
    /// desynchronise the two devices on the next grant.
    @Test("Every refused request leaves the pool exactly as it was")
    func refusalsNeverMoveThePool() async throws {
        let stranger = PlayerID(rawValue: "not-in-this-match")
        // `reachesPeer`: a refusal carries no player, so the only thing that can
        // route it is who asked. The host's own refusal stays home — on the peer
        // it would read as a refusal of the peer's own request. `poolExhausted`
        // is the exception that always goes out: it ends the match for both.
        let cases: [(name: String, pool: [Tile], request: MatchMessage, reachesPeer: Bool)] = [
            ("an empty pool", [], .drawRequest(player: guestID), true),
            ("one tile, two players", tiles(1), .drawRequest(player: guestID), true),
            ("an empty pool, swap", [], .swapRequest(player: guestID, returning: Tile(letter: "Q")), true),
            ("two tiles, swap", tiles(2), .swapRequest(player: hostID, returning: Tile(letter: "Q")), false),
            ("a stranger drawing", tiles(20), .drawRequest(player: stranger), true),
            ("a stranger swapping", tiles(20), .swapRequest(player: stranger, returning: Tile(letter: "Q")), true),
        ]

        for scenario in cases {
            let (host, guest) = FakeTransport.pair(hostID, guestID)
            let start = Pool(tiles: scenario.pool)
            let authority = HostPool(players: (hostID, guestID), pool: start, seed: 3, transport: host)

            try await guest.send(scenario.request, delivery: .reliable)
            let produced = try #require(
                await pump(1, from: host, into: authority), "\(scenario.name): unanswered"
            ).flatMap { $0 }

            let messages = try #require(await drain(host, guest), "\(scenario.name): no reply reached the peer")
            #expect(produced.count == 1, "\(scenario.name): expected one answer, got \(produced)")
            #expect(grants(in: produced).isEmpty, "\(scenario.name): a refusal granted tiles — \(produced)")
            #expect(grants(in: messages).isEmpty, "\(scenario.name): a refusal granted tiles on the wire — \(messages)")
            #expect(
                messages.count == (scenario.reachesPeer ? 1 : 0),
                "\(scenario.name): wrong number of replies on the wire — \(messages)"
            )
            #expect(await authority.pool == start, "\(scenario.name): a refused request moved the pool")
        }
    }

    // MARK: - Determinism of the fan-out

    /// Both devices build the host from the same two ids, but neither can know
    /// which order the other named them in. The same pool must therefore
    /// produce the identical grants either way round.
    @Test("The fan-out does not depend on the order the players were named in")
    func grantsAreIndependentOfConstructorArgumentOrder() async throws {
        let start = Pool(tiles: tiles(8))

        func run(_ players: (PlayerID, PlayerID)) async throws -> (produced: [MatchMessage], received: [MatchMessage]) {
            let (host, guest) = FakeTransport.pair(hostID, guestID)
            let authority = HostPool(players: players, pool: start, seed: 4, transport: host)
            try await guest.send(.drawRequest(player: guestID), delivery: .reliable)
            let produced = try #require(await pump(1, from: host, into: authority)).flatMap { $0 }
            let received = try #require(await drain(host, guest), "no reply reached the peer")
            return (produced, received)
        }

        let forward = try await run((hostID, guestID))
        let reversed = try await run((guestID, hostID))
        // Both halves of the round, not just the half the peer sees: argument
        // order must not change which tile either player got.
        #expect(forward.produced == reversed.produced, "argument order changed who got which tile")
        #expect(forward.received == reversed.received, "argument order changed what the peer was told")
        #expect(grants(in: forward.produced).count == 2)
        #expect(grants(in: forward.received).count == 1, "only the peer's own grant belongs on the wire")
    }

    // MARK: - Messages that are not requests

    @Test("A message that is not a pool request moves nothing and answers nothing")
    func nonRequestMessagesAreIgnored() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)
        let start = Pool(tiles: tiles(20))
        let authority = HostPool(players: (hostID, guestID), pool: start, seed: 6, transport: host)

        let notRequests: [MatchMessage] = [
            .start(version: 1, seed: 9, startingHandSize: 21, countdownSeconds: 3),
            .grant(player: guestID, tiles: tiles(1)),
            .swapGrant(player: guestID, tiles: tiles(3), returned: Tile(letter: "Q")),
            .poolExhausted,
            .rejected(reason: .notYourTurn),
            .resign(player: guestID),
        ]

        for message in notRequests {
            let answered = await authority.handle(message)
            #expect(answered.isEmpty, "\(message) drew an answer out of the host")
        }

        let messages = try #require(await drain(host, guest), "the peer's stream never finished")
        #expect(messages.isEmpty, "a non-request put something on the wire: \(messages)")
        #expect(await authority.pool == start, "a non-request moved the pool")
    }

    // MARK: - Election

    /// The election has to be total and pure: any two ids, either order, same
    /// answer, and the answer is always one of the two ids given.
    @Test("Election is total, returns one of its inputs, and ignores argument order")
    func electionIsTotalAndClosedOverItsInputs() {
        // One literal case, since the sweep below re-derives its expectation
        // with the same comparator the implementation uses and would agree with
        // a reversed rule just as happily.
        #expect(
            HostPool.host(of: PlayerID(rawValue: "G:999"), PlayerID(rawValue: "G:100"))
                == PlayerID(rawValue: "G:100")
        )

        let ids = ["", " ", "a", "A", "alpha", "alpha-host", "beta-guest",
                   "player-2", "player-10", "G:1234567890", "Ω", "zzz"]

        for left in ids {
            for right in ids {
                let first = PlayerID(rawValue: left)
                let second = PlayerID(rawValue: right)
                let elected = HostPool.host(of: first, second)

                #expect(elected == HostPool.host(of: second, first), "\(left)/\(right): order changed the host")
                #expect(elected == first || elected == second, "\(left)/\(right): elected a third party")
                #expect(elected.rawValue == min(left, right), "\(left)/\(right): the lower rawValue did not win")
                // Idempotent: re-running it on a device that already knows the
                // answer must not move it.
                #expect(HostPool.host(of: elected, elected) == elected)
            }
        }
    }
}
