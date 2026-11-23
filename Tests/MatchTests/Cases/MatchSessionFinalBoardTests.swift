import Foundation
import Testing
import WillagramsRules
@testable import Match

/// The board each player sends once the match is over, for the other player's
/// end screen.
///
/// Two things are pinned. A board is never on the wire while the match is still
/// being played, and never taken from it either: read early it would show the
/// other player's letters. And once the match is over, however it ended, each
/// device holds the other's board exactly as it stood.
@MainActor
@Suite("Match session final boards")
struct MatchSessionFinalBoardTests {

    typealias Terminal = MatchSessionTerminalTests
    typealias Flow = MatchSessionMatchFlowTests

    static let alice = Terminal.alice
    static let bob = Terminal.bob

    static func finalBoards(in sent: [MatchMessage]) -> [MatchMessage] {
        sent.filter { if case .finalBoard = $0 { return true } else { return false } }
    }

    /// A send is queued, so the test waits for it before carrying the wire across.
    static func boardOnTheWire(_ wire: Flow.Wire) async throws {
        try await Terminal.waitUntil("a final board to reach the wire") {
            await !finalBoards(in: wire.wire).isEmpty
        }
    }

    /// A dealt table with one tile laid on each board and one whole draw round
    /// played, so both boards have something on them and the match has moved.
    static func tableInPlay() async throws -> Flow.Table {
        var table = try await Flow.dealtTable()
        try table.host.place(tileID: table.host.state.hand[0].id, at: Coord(row: 2, col: 2))
        try table.guest.place(tileID: table.guest.state.hand[0].id, at: Coord(row: 0, col: 0))
        #expect(table.host.draw())
        try await Terminal.waitUntil("the host's tile for the round") { Flow.held(table.host) == 4 }
        await table.hostToGuest()
        try await Terminal.waitUntil("the guest's tile for the round") { Flow.held(table.guest) == 4 }
        return table
    }

    @Test("No final board is sent before the match is over, and after a win each side holds the other's")
    func boardsCrossOnlyAfterAWin() async throws {
        var table = try await Self.tableInPlay()

        // A whole round has been played and nothing has ended.
        try await Terminal.settle()
        #expect(Self.finalBoards(in: await table.hostWire.wire).isEmpty)
        #expect(Self.finalBoards(in: await table.guestWire.wire).isEmpty)

        #expect(table.guest.claimWin())
        try await Self.boardOnTheWire(table.guestWire)
        await table.guestToHost()
        try await Terminal.waitUntil("the host to hear the win") { table.host.isMatchOver }
        try await Self.boardOnTheWire(table.hostWire)
        await table.hostToGuest()
        try await Terminal.waitUntil("both boards to arrive") {
            table.host.peerFinalBoards[Self.bob] != nil && table.guest.peerFinalBoards[Self.alice] != nil
        }

        // The winner's board follows its win, never the other way round.
        let fromGuest = await table.guestWire.wire
        let win = try #require(fromGuest.firstIndex { if case .win = $0 { return true } else { return false } })
        let board = try #require(fromGuest.firstIndex { if case .finalBoard = $0 { return true } else { return false } })
        #expect(win < board)

        // Identity, not presence: the letters at the coordinates the other
        // device really has.
        #expect(table.host.peerFinalBoards == [Self.bob: table.guest.state.board.placementList])
        #expect(table.guest.peerFinalBoards == [Self.alice: table.host.state.board.placementList])
        #expect(table.guest.state.board.placementList.count == 1)
        #expect(table.host.state.board.placementList.count == 1)
        // One each. A board is a fact, sent once.
        #expect(Self.finalBoards(in: await table.hostWire.wire).count == 1)
        #expect(Self.finalBoards(in: fromGuest).count == 1)
        await table.leave()
    }

    @Test("After a resignation the winner holds the board of the player who gave up, and that player the winner's")
    func boardsCrossAfterAResignation() async throws {
        var table = try await Self.tableInPlay()

        #expect(table.host.resign())
        try await Self.boardOnTheWire(table.hostWire)
        await table.hostToGuest()
        try await Terminal.waitUntil("the guest to hear the resignation") { table.guest.isMatchOver }
        try await Self.boardOnTheWire(table.guestWire)
        await table.guestToHost()
        try await Terminal.waitUntil("both boards to arrive") {
            table.host.peerFinalBoards[Self.bob] != nil && table.guest.peerFinalBoards[Self.alice] != nil
        }

        #expect(table.guest.winner == Self.bob)
        #expect(table.guest.peerFinalBoards == [Self.alice: table.host.state.board.placementList])
        #expect(table.host.peerFinalBoards == [Self.bob: table.guest.state.board.placementList])
        await table.leave()
    }

    @Test("A final board heard while the match is still being played is thrown away")
    func aBoardHeardEarlyIsIgnored() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        let early = [Placement(tile: Tile(letter: "Z"), coord: Coord(row: 1, col: 1))]

        wire.deliver(.finalBoard(player: Self.alice, placements: early))
        try await Terminal.settle()
        #expect(guest.peerFinalBoards.isEmpty)
        #expect(guest.isMatchOver == false)

        // Still thrown away once the match ends: it was dropped, not parked.
        wire.deliver(.win(player: Self.alice, placements: []))
        try await Terminal.waitUntil("the win to land") { guest.isMatchOver }
        #expect(guest.peerFinalBoards.isEmpty)
        guest.leave()
        clock.releaseAll()
    }

    @Test("A final board naming this device is not taken for the opponent's")
    func aBoardInThisDevicesNameIsIgnored() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        wire.deliver(.win(player: Self.alice, placements: []))
        try await Terminal.waitUntil("the win to land") { guest.isMatchOver }

        let forged = [Placement(tile: Tile(letter: "Q"), coord: Coord(row: 3, col: 3))]
        wire.deliver(.finalBoard(player: Self.bob, placements: forged))
        wire.deliver(.finalBoard(player: PlayerID(rawValue: "nobody"), placements: forged))
        try await Terminal.settle()
        #expect(guest.peerFinalBoards.isEmpty)

        // The real one still lands afterwards, and the settled match is not moved by it.
        let settled = Terminal.snapshot(guest)
        wire.deliver(.finalBoard(player: Self.alice, placements: forged))
        try await Terminal.waitUntil("the opponent's board") { guest.peerFinalBoards[Self.alice] == forged }
        #expect(Terminal.snapshot(guest) == settled)
        #expect(guest.winner == Self.alice)
        guest.leave()
        clock.releaseAll()
    }
}
