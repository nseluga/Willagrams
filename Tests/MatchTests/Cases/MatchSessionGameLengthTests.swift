import Foundation
import Testing
import WillagramsRules
@testable import Match

/// The half-length game: which pool gets built, and on whose word.
///
/// The pool lives on one device, `roster[0]`, and that is not always the device
/// that opens the match. So the choice travels as `gameLength`, just ahead of
/// `.start`, and these tests pin both ends of that: the opener that also holds
/// the pool, and the pool holder that only hears about it.
@MainActor
@Suite("Match session game length: half and full pools")
struct MatchSessionGameLengthTests {

    typealias Terminal = MatchSessionTerminalTests
    typealias Wire = MatchSessionTerminalTests.PresenceTransport

    static let alice = Terminal.alice
    static let bob = Terminal.bob

    /// `alice` sorts first, so she is `roster[0]` and holds the pool.
    static func pair() -> (alice: MatchSession, bob: MatchSession, aliceWire: Wire, bobWire: Wire) {
        let aliceWire = Wire(localPlayerID: alice, peer: bob)
        let bobWire = Wire(localPlayerID: bob, peer: alice)
        let a = MatchSession(
            transport: aliceWire, peerPlayerID: bob, dictionary: Terminal.EveryWordIsReal(),
            sleepFor: { _ in }
        )
        let b = MatchSession(
            transport: bobWire, peerPlayerID: alice, dictionary: Terminal.EveryWordIsReal(),
            sleepFor: { _ in }
        )
        return (a, b, aliceWire, bobWire)
    }

    static func start(hand: Int, roster: [PlayerID]? = nil) -> MatchMessage {
        .start(
            version: WireFormat.current, seed: 5, startingHandSize: hand, countdownSeconds: 0,
            options: .standard, roster: roster ?? [alice, bob]
        )
    }

    // MARK: - The half pool itself

    @Test("The half pool is 72 tiles, and every letter is within one of half its count")
    func theHalfPoolIsAProportionalHalf() {
        #expect(LetterDistribution.halfTotalTiles == 72)
        #expect((70...74).contains(Pool.half(seed: 7).count))
        for (letter, full) in LetterDistribution.standard {
            let half = LetterDistribution.half[letter] ?? 0
            #expect(abs(half * 2 - full) <= 1, "\(letter): \(half) of \(full)")
            #expect(half >= 1, "\(letter) is missing from the half pool")
        }
    }

    // MARK: - Which pool a match gets

    @Test("An opener that holds the pool builds 72 tiles for a half game and 144 for a full one")
    func theOpenerBuildsThePoolItAskedFor() async throws {
        let half = Self.pair()
        half.alice.startMatch(seed: 5, startingHandSize: 3, countdownSeconds: 0, halfGame: true)
        try await Terminal.waitUntil("the half deal") { half.alice.state.hand.count == 3 }
        #expect(half.alice.poolRemaining == 72 - 6)

        let full = Self.pair()
        full.alice.startMatch(seed: 5, startingHandSize: 3, countdownSeconds: 0)
        try await Terminal.waitUntil("the full deal") { full.alice.state.hand.count == 3 }
        #expect(full.alice.poolRemaining == LetterDistribution.totalTiles - 6)

        for session in [half.alice, half.bob, full.alice, full.bob] { session.leave() }
    }

    @Test("A pool holder that did not open the match builds the half pool it was asked for")
    func thePoolHolderHearsTheChoiceOffTheWire() async throws {
        let table = Self.pair()
        table.bob.startMatch(seed: 5, startingHandSize: 3, countdownSeconds: 0, halfGame: true)
        try await Terminal.waitUntil("both messages to reach the wire") {
            await table.bobWire.wire.count >= 2
        }
        // The length goes first: the start is what builds the pool.
        let sent = await table.bobWire.wire
        #expect(sent.first == .gameLength(half: true))
        for message in sent { table.aliceWire.deliver(message) }

        try await Terminal.waitUntil("alice's deal") { table.alice.state.hand.count == 3 }
        #expect(table.alice.poolRemaining == 72 - 6)
        table.alice.leave()
        table.bob.leave()
    }

    @Test("A pool holder that never hears the choice deals a full pool")
    func aDroppedChoiceDealsAFullPool() async throws {
        // What a 1.0 build does: it cannot decode `gameLength`, so only the
        // start arrives. The game is longer than asked for and still has one pool.
        let table = Self.pair()
        table.bob.startMatch(seed: 5, startingHandSize: 3, countdownSeconds: 0, halfGame: true)
        try await Terminal.waitUntil("both messages to reach the wire") {
            await table.bobWire.wire.count >= 2
        }
        for message in await table.bobWire.wire where message != .gameLength(half: true) {
            table.aliceWire.deliver(message)
        }

        try await Terminal.waitUntil("alice's deal") { table.alice.state.hand.count == 3 }
        #expect(table.alice.poolRemaining == LetterDistribution.totalTiles - 6)
        table.alice.leave()
        table.bob.leave()
    }

    @Test("The opener's own choice wins over a game length heard off the wire")
    func aPeerCannotOverrideTheOpener() async throws {
        let table = Self.pair()
        table.aliceWire.deliver(.gameLength(half: true))
        try await Terminal.settle()

        table.alice.startMatch(seed: 5, startingHandSize: 3, countdownSeconds: 0)
        try await Terminal.waitUntil("the deal") { table.alice.state.hand.count == 3 }
        #expect(table.alice.poolRemaining == LetterDistribution.totalTiles - 6)

        // And once the pool exists, the kind changes nothing.
        table.aliceWire.deliver(.gameLength(half: true))
        try await Terminal.settle()
        #expect(table.alice.poolRemaining == LetterDistribution.totalTiles - 6)
        table.alice.leave()
        table.bob.leave()
    }

    /// The pool holder clamps for itself. A start built by a device that did
    /// not clamp, a modified one for instance, asks a 72-tile pool for 80 tiles,
    /// and an opening deal is all or nothing.
    @Test("The pool holder clamps a hand the opener did not")
    func thePoolHolderClampsForItself() async throws {
        let table = Self.pair()
        table.aliceWire.deliver(.gameLength(half: true))
        table.aliceWire.deliver(Self.start(hand: 40))
        try await Terminal.waitUntil("alice's deal") { table.alice.state.hand.count == 36 }
        #expect(table.alice.poolRemaining == 0)
        table.alice.leave()
        table.bob.leave()
    }

    @Test("A game length heard ahead of a refused start does not shape a later match")
    func aRefusedStartClearsTheChoice() async throws {
        let table = Self.pair()
        table.aliceWire.deliver(.gameLength(half: true))
        table.aliceWire.deliver(Self.start(hand: 3, roster: [Self.alice, PlayerID(rawValue: "zed")]))
        table.aliceWire.deliver(Self.start(hand: 3))
        try await Terminal.waitUntil("alice's deal") { table.alice.state.hand.count == 3 }
        #expect(table.alice.poolRemaining == LetterDistribution.totalTiles - 6)
        table.alice.leave()
        table.bob.leave()
    }

    // MARK: - The deal can always be made

    @Test(
        "A half game deals a full opening hand at every hand size the screens offer and beyond",
        arguments: [5, 21, 30, 36, 37, 40, 72]
    )
    func theOpeningDealIsNeverEmpty(handSize: Int) async throws {
        let table = Self.pair()
        table.alice.startMatch(
            seed: 5, startingHandSize: handSize, countdownSeconds: 0, halfGame: true
        )
        // A half pool is 72 tiles and there are two players, so 36 is the most
        // either can be dealt. A larger ask is clamped, never refused: an
        // unclamped one would ask the pool for more than it holds and deal nobody
        // anything.
        let dealt = min(handSize, 36)
        try await Terminal.waitUntil("the deal of \(dealt)") {
            table.alice.state.hand.count == dealt
        }
        #expect(table.alice.poolRemaining == 72 - dealt * 2)
        // The clamped size is what travels, so both devices expect the same hand.
        let start = await table.aliceWire.wire.compactMap { message -> Int? in
            if case .start(_, _, let hand, _, _, _) = message { return hand }
            return nil
        }
        #expect(start == [dealt])
        table.alice.leave()
        table.bob.leave()
    }

    /// Row 4c says any hand size *and any player count*. The pair above covers
    /// two players; this covers three to six, with the largest hand the setup
    /// screen allows for a half game, so the clamp is what is under test.
    @Test("A half game deals every player a full hand at every table size", arguments: 3...6)
    func theOpeningDealCoversEveryTableSize(players: Int) async throws {
        let extras = (0..<(players - 2)).map { PlayerID(rawValue: "zz-\($0)") }
        let wire = Wire(localPlayerID: Self.alice, peer: Self.bob)
        let host = MatchSession(
            transport: wire, roster: [Self.alice, Self.bob] + extras,
            dictionary: Terminal.EveryWordIsReal(), sleepFor: { _ in }
        )
        #expect(host.roster.first == Self.alice)
        host.startMatch(seed: 5, startingHandSize: 30, countdownSeconds: 0, halfGame: true)
        let dealt = min(30, 72 / players)
        try await Terminal.waitUntil("the deal of \(dealt) to \(players) players") {
            host.state.hand.count == dealt
        }
        #expect(dealt > 0)
        #expect(host.poolRemaining == 72 - dealt * players)
        host.leave()
    }
}
