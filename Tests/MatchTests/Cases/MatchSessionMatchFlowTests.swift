import Foundation
import Testing
import WillagramsRules
@testable import Match

/// The opponent's draw, and the tile nobody may lose.
///
/// Two things are pinned here. A tile owed for the opponent's draw goes
/// straight into the rack, so nothing waits behind the Draw button and swap and
/// placement stay open. And a tile the host has taken out of the pool always
/// reaches a rack: the host's pool never moves back, so a message that says
/// "this tile is yours" may be late but may never be thrown away.
@MainActor
@Suite("Match session match flow: auto-take and no lost tile")
struct MatchSessionMatchFlowTests {

    typealias Terminal = MatchSessionTerminalTests
    typealias Wire = MatchSessionTerminalTests.PresenceTransport

    static let alice = Terminal.alice
    static let bob = Terminal.bob

    /// Carries everything `from` put on the wire since the last call across to
    /// `to`. Two `PresenceTransport`s are not joined, which is the point: the
    /// test decides when a message arrives, so it can arrive mid-freeze.
    static func carry(_ from: Wire, to: Wire, after seen: inout Int) async {
        let sent = await from.wire
        for message in sent[seen...] { to.deliver(message) }
        seen = sent.count
    }

    /// Every tile a device is holding, wherever it holds it.
    static func held(_ session: MatchSession) -> Int {
        session.state.hand.count + session.pendingDrawTiles.count + session.state.board.placementList.count
    }

    /// A host (`alice`, who runs the pool) and a guest (`bob`), dealt and
    /// playing, each on a transport and a clock the test drives.
    @MainActor
    struct Table {
        let host: MatchSession
        let guest: MatchSession
        let hostWire: Wire
        let guestWire: Wire
        let hostClock: Terminal.HandCrankedClock
        let guestClock: Terminal.HandCrankedClock
        var fromHost = 0
        var fromGuest = 0

        mutating func hostToGuest() async {
            await MatchSessionMatchFlowTests.carry(hostWire, to: guestWire, after: &fromHost)
        }
        mutating func guestToHost() async {
            await MatchSessionMatchFlowTests.carry(guestWire, to: hostWire, after: &fromGuest)
        }

        /// Pool plus both racks, both boards and anything waiting.
        var everyTile: Int {
            (host.poolRemaining ?? 0)
                + MatchSessionMatchFlowTests.held(host)
                + MatchSessionMatchFlowTests.held(guest)
        }

        func leave() async {
            host.leave()
            guest.leave()
            hostClock.releaseAll()
            guestClock.releaseAll()
        }
    }

    static func dealtTable(handSize: Int = 3) async throws -> Table {
        let hostWire = Wire(localPlayerID: alice, peer: bob)
        let guestWire = Wire(localPlayerID: bob, peer: alice)
        let hostClock = Terminal.HandCrankedClock()
        let guestClock = Terminal.HandCrankedClock()
        let host = MatchSession(
            transport: hostWire, peerPlayerID: bob, dictionary: Terminal.EveryWordIsReal(),
            sleepFor: { await hostClock.tick($0) }
        )
        let guest = MatchSession(
            transport: guestWire, peerPlayerID: alice, dictionary: Terminal.EveryWordIsReal(),
            sleepFor: { await guestClock.tick($0) }
        )
        var table = Table(
            host: host, guest: guest, hostWire: hostWire, guestWire: guestWire,
            hostClock: hostClock, guestClock: guestClock
        )
        host.startMatch(seed: 5, startingHandSize: handSize, countdownSeconds: 0)
        try await Terminal.waitUntil("the host's hand") { host.state.hand.count == handSize }
        await table.hostToGuest()
        try await Terminal.waitUntil("the guest's hand") { guest.state.hand.count == handSize }
        return table
    }

    // MARK: - The opponent's draw gives the tile at once

    @Test("A tile owed for the opponent's draw is in the hand with no Draw press")
    func theOpponentsDrawLandsInTheHand() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        let tile = Tile(letter: "W")

        wire.deliver(.obligation(player: Self.bob, tiles: [tile]))
        try await Terminal.waitUntil("the tile to reach the hand") {
            guest.state.hand.map(\.id) == [tile.id]
        }

        #expect(guest.hasPendingDraw == false)
        #expect(guest.pendingDrawTiles.isEmpty)
        // Taking it asked the host for nothing.
        try await Terminal.settle()
        #expect(await wire.drawRequests == 0)
        guest.leave()
    }

    @Test("Swap and placement both work right after the opponent's draw")
    func swapAndPlacementStayOpenAfterTheOpponentsDraw() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        let first = Tile(letter: "W")
        let second = Tile(letter: "I")

        wire.deliver(.obligation(player: Self.bob, tiles: [first]))
        wire.deliver(.obligation(player: Self.bob, tiles: [second]))
        try await Terminal.waitUntil("both tiles to reach the hand") { guest.state.hand.count == 2 }

        try guest.place(tileID: first.id, at: Coord(row: 0, col: 0))
        #expect(guest.swap(second))
        try await Terminal.waitUntil("the swap request to reach the wire") {
            await wire.wire.contains(.swapRequest(player: Self.bob, returning: second))
        }
        guest.leave()
    }

    // MARK: - No tile is lost

    /// The reported bug, in its plainest shape. The player presses Draw, the
    /// host takes a tile out of the pool for them, and the answer arrives while
    /// this device believes its opponent is away. That is what a short trip out
    /// of the app does: coming back, the device reports the peer as gone until
    /// it has re-joined, and whatever the socket was holding is delivered into
    /// that gap.
    @Test("A grant that lands while this device is frozen still reaches the hand")
    func aGrantDeliveredDuringAFreezeIsKept() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        #expect(guest.draw())
        try await Terminal.waitUntil("the request to reach the wire") { await wire.drawRequests == 1 }

        wire.drop(Self.alice)
        try await Terminal.waitUntil("the guest to freeze") { guest.peerPresence != .present }
        let tile = Tile(letter: "W")
        wire.deliver(.grant(player: Self.bob, tiles: [tile]))
        try await Terminal.settle()

        wire.restore(Self.alice)
        try await Terminal.resume(guest, on: clock)
        #expect(guest.state.hand.map(\.id) == [tile.id])
        guest.leave()
        clock.releaseAll()
    }

    @Test("Pool, racks and boards still add up after a draw round is cut by a disconnect")
    func everyTileIsAccountedForAcrossAMidRoundDisconnect() async throws {
        var table = try await Self.dealtTable()
        let starting = table.everyTile
        #expect(starting == table.host.poolRemaining! + 6)

        // One whole round, so the count is known to hold when nothing goes wrong.
        try table.guest.place(tileID: table.guest.state.hand[0].id, at: Coord(row: 0, col: 0))
        #expect(table.host.draw())
        try await Terminal.waitUntil("the host's own tile") { Self.held(table.host) == 4 }
        await table.hostToGuest()
        try await Terminal.waitUntil("the guest's tile for that round") { Self.held(table.guest) == 4 }
        #expect(table.everyTile == starting)

        // The round that is cut. The guest asks, and its device loses sight of
        // the host before the answer arrives.
        // A 1.0 build holds the tile for the round above behind Draw; take it
        // first so the next press is a request on every build.
        while table.guest.hasPendingDraw { table.guest.draw() }
        #expect(table.guest.draw())
        try await Terminal.waitUntil("the request to reach the wire") {
            await table.guestWire.drawRequests == 1
        }
        table.guestWire.drop(Self.alice)
        try await Terminal.waitUntil("the guest to freeze") { table.guest.peerPresence != .present }

        // The host never froze, so it answers: the pool moves for both players.
        await table.guestToHost()
        try await Terminal.waitUntil("the host's tile for the cut round") { Self.held(table.host) == 5 }
        await table.hostToGuest()
        try await Terminal.settle()

        table.guestWire.restore(Self.alice)
        try await Terminal.resume(table.guest, on: table.guestClock)
        try await Terminal.settle()

        #expect(table.everyTile == starting)
        #expect(Self.held(table.guest) == 5)
        await table.leave()
    }

    /// The same gap from the other side. The host is the one that stepped away,
    /// so the guest never froze and its Draw button is live while the host is
    /// still counting back in. A request the host throws away is never
    /// answered, and the guest's Draw then refuses every later press.
    @Test("A draw request that reaches a host still counting back in is answered when play resumes")
    func aRequestDuringTheHostsResumeIsAnswered() async throws {
        var table = try await Self.dealtTable()
        let starting = table.everyTile

        table.hostWire.drop(Self.bob)
        try await Terminal.waitUntil("the host to freeze") { table.host.peerPresence != .present }

        #expect(table.guest.draw())
        try await Terminal.waitUntil("the request to reach the wire") {
            await table.guestWire.drawRequests == 1
        }
        await table.guestToHost()
        try await Terminal.settle()

        table.hostWire.restore(Self.bob)
        try await Terminal.resume(table.host, on: table.hostClock)

        // The answer is on its way as soon as the host is playing again.
        try await Terminal.waitUntil("the host's tile for the round", within: .seconds(2)) {
            Self.held(table.host) == 4
        }
        await table.hostToGuest()
        try await Terminal.waitUntil("the guest's answer", within: .seconds(2)) {
            Self.held(table.guest) == 4
        }
        #expect(table.everyTile == starting)

        // And Draw is not latched shut behind the request.
        #expect(table.guest.draw())
        await table.leave()
    }
}
