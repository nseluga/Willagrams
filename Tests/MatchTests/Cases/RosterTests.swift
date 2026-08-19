import Foundation
import Testing
import WillagramsRules
@testable import Match

/// The roster amendment: a match is two to six players, and everything that
/// used to name "the peer" now names one of several.
///
/// Two shapes are covered here rather than in the existing pair suites, which
/// stay at two players on purpose — a regression in the two-player path should
/// still read as a two-player failure.
@Suite("Six-player roster")
struct RosterDealTests {

    private static let six = (0..<6).map { PlayerID(rawValue: "p\($0)") }

    @Test("A six-player deal hands every player a distinct hand and takes exactly what it dealt")
    func sixPlayerDealIsDistinctAndExact() async throws {
        let handSize = 21
        let (host, _) = FakeTransport.pair(Self.six[0], Self.six[1])
        let start = Pool.standard(seed: 4321)
        let authority = HostPool(
            players: Self.six, pool: start, seed: 4321, transport: host
        )

        let produced = await authority.deal(handSize: handSize)

        var byPlayer: [PlayerID: [Tile]] = [:]
        for case let .grant(player, tiles) in produced { byPlayer[player, default: []] += tiles }
        #expect(byPlayer.count == 6, "one grant per player, addressed to that player")
        for player in Self.six {
            #expect(byPlayer[player]?.count == handSize)
        }

        // Distinct *tiles*, not distinct letters: six hands of 21 out of one
        // 144-tile pool must not overlap by a single tile id.
        let dealt = byPlayer.values.flatMap { $0 }
        #expect(Set(dealt.map(\.id)).count == handSize * 6, "a tile reached two racks")

        let remaining = await authority.pool.count
        #expect(
            remaining == LetterDistribution.totalTiles - handSize * 6,
            "the pool fell by something other than what was dealt"
        )
    }

    @Test("The host is the lowest id on the roster, whatever order it was built in")
    func hostIsTheLowestID() {
        #expect(HostPool.host(of: Self.six) == Self.six[0])
        #expect(HostPool.host(of: Self.six.reversed()) == Self.six[0])
        #expect(HostPool.host(of: Self.six.shuffled()) == Self.six[0])
    }

    @Test("A sender who is not on the roster is refused, not dealt to")
    func aStrangerIsRefused() async throws {
        let (host, guest) = FakeTransport.pair(Self.six[0], Self.six[1])
        let authority = HostPool(
            players: Self.six, pool: Pool.standard(seed: 9), seed: 9, transport: host
        )
        let before = await authority.pool.count

        let produced = await authority.handle(.drawRequest(player: PlayerID(rawValue: "gatecrasher")))

        #expect(produced == [.rejected(reason: .unknownPlayer)])
        #expect(await authority.pool.count == before, "a stranger moved the pool")
        guest.leave()
    }
}

/// Four players, so "the peer" is genuinely plural: one away is not the same as
/// one gone, and one gone is not the same as the match being over.
@Suite("Four-player presence")
@MainActor
struct RosterPresenceTests {

    private static let four = (0..<4).map { PlayerID(rawValue: "q\($0)") }
    private static let local = PlayerID(rawValue: "q1")

    /// Everything a four-player session needs driven from a test: messages onto
    /// the inbound stream, and connection states for any player on the roster.
    /// `FakeTransport` pairs exactly two endpoints and its disconnect finishes
    /// the inbound stream, so it cannot say "one of four went away".
    final class RosterWire: MatchTransport, @unchecked Sendable {
        let localPlayerID: PlayerID
        let inboundMessages: AsyncStream<MatchMessage>
        let peerConnectionStates: AsyncStream<PeerConnectionState>

        private let messages: AsyncStream<MatchMessage>.Continuation
        private let presence: AsyncStream<PeerConnectionState>.Continuation

        init(localPlayerID: PlayerID) {
            let m = AsyncStream.makeStream(of: MatchMessage.self, bufferingPolicy: .unbounded)
            let p = AsyncStream.makeStream(of: PeerConnectionState.self, bufferingPolicy: .unbounded)
            self.localPlayerID = localPlayerID
            self.inboundMessages = m.stream
            self.messages = m.continuation
            self.peerConnectionStates = p.stream
            self.presence = p.continuation
        }

        func deliver(_ message: MatchMessage) { messages.yield(message) }
        func drop(_ player: PlayerID) { presence.yield(.disconnected(player)) }
        func restore(_ player: PlayerID) { presence.yield(.connected(player)) }

        func send(_ message: MatchMessage, delivery: MatchDelivery) async throws {}
        func leave() { messages.finish(); presence.finish() }
    }

    struct AnyWordList: WordList {
        func contains(_ word: String) -> Bool { true }
    }

    private static func session(
        _ wire: RosterWire,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = { _ in }
    ) -> MatchSession {
        MatchSession(
            transport: wire, roster: four, dictionary: AnyWordList(), sleepFor: sleepFor
        )
    }

    /// Polls the main actor rather than sleeping a fixed amount: every path
    /// under test lands through a task the runtime schedules when it likes.
    static func waitUntil(_ label: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(label)")
    }

    /// Lets everything already enqueued run, for the assertions that something
    /// did *not* happen.
    static func settle() async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
    }

    @Test("A roster arrives sorted, without this device, and elects the lowest id host")
    func rosterShape() {
        let wire = RosterWire(localPlayerID: Self.local)
        let session = Self.session(wire)
        defer { session.leave() }
        #expect(session.roster == Self.four)
        #expect(session.peerPlayerIDs == [Self.four[0], Self.four[2], Self.four[3]])
        #expect(HostPool.host(of: session.roster) == Self.four[0])
    }

    @Test("One peer away freezes the match without ending it, and coming back thaws it")
    func oneAwayFreezesWithoutEnding() async throws {
        let wire = RosterWire(localPlayerID: Self.local)
        // A window that never expires: the default no-op clock would fire the
        // reconnect deadline the instant the peer dropped, and there would be
        // nothing left to come back to.
        let session = Self.session(wire, sleepFor: { _ in try await Task.sleep(for: .seconds(60)) })
        defer { session.leave() }

        wire.drop(Self.four[2])
        try await Self.waitUntil("the match to freeze") {
            if case .reconnecting = session.presence(of: Self.four[2]) { return true }
            return false
        }
        #expect(session.isMatchOver == false, "one away is not an ending with four on the roster")
        #expect(session.presence(of: Self.four[0]) == .present)

        wire.restore(Self.four[2])
        try await Self.waitUntil("the match to thaw") {
            session.presence(of: Self.four[2]) == .present
        }
        #expect(session.isMatchOver == false)
    }

    @Test("A connection state naming somebody off the roster is ignored")
    func aStrangerCannotFreezeTheMatch() async throws {
        let wire = RosterWire(localPlayerID: Self.local)
        let session = Self.session(wire)
        defer { session.leave() }

        wire.drop(PlayerID(rawValue: "gatecrasher"))
        try await Self.settle()
        #expect(session.peerPresence == .present)
        #expect(session.isMatchOver == false)
    }

    @Test("The match ends only when fewer than two players are left")
    func endsWhenOnlyOneRemains() async throws {
        let wire = RosterWire(localPlayerID: Self.local)
        let session = Self.session(wire)
        defer { session.leave() }

        wire.deliver(.resign(player: Self.four[0]))
        try await Self.waitUntil("the first resignation") {
            session.presence(of: Self.four[0]) == .gone
        }
        #expect(session.isMatchOver == false, "three left is still a match")
        #expect(session.winner == nil)

        wire.deliver(.resign(player: Self.four[2]))
        try await Self.waitUntil("the second resignation") {
            session.presence(of: Self.four[2]) == .gone
        }
        #expect(session.isMatchOver == false, "two left is still a match")
        #expect(session.winner == nil)

        wire.deliver(.resign(player: Self.four[3]))
        try await Self.waitUntil("the last opponent to go") { session.isMatchOver }
        #expect(session.winner == Self.local, "the last player standing wins")
    }

    @Test("A win from any peer on the roster ends the match and names that peer")
    func aPeerWinEndsIt() async throws {
        let wire = RosterWire(localPlayerID: Self.local)
        let session = Self.session(wire)
        defer { session.leave() }

        wire.deliver(.win(player: Self.four[3], placements: []))
        try await Self.waitUntil("the win to land") { session.isMatchOver }
        #expect(session.winner == Self.four[3])
    }

    @Test("A win or a resignation naming somebody off the roster is not a result")
    func aStrangerCannotWin() async throws {
        let wire = RosterWire(localPlayerID: Self.local)
        let session = Self.session(wire)
        defer { session.leave() }

        wire.deliver(.win(player: PlayerID(rawValue: "gatecrasher"), placements: []))
        wire.deliver(.resign(player: PlayerID(rawValue: "gatecrasher")))
        try await Self.settle()
        #expect(session.isMatchOver == false)
        #expect(session.winner == nil)
    }
}
