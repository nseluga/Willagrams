import Foundation
import Testing
import WillagramsRules
@testable import Match

/// Independent gate cover for the terminal states, aimed at the paths neither
/// the criteria suite nor the audit suite walks.
///
/// The engineer's fix exempts `.win`/`.resign` from the lock when the session is
/// not frozen, so a finished session still emits its own terminal message while a
/// frozen one emits nothing. That exemption is unconditional on the chain, so the
/// only thing keeping a *second* terminal message off the wire is the entry
/// guard in ``MatchSession/claimWin()``/``MatchSession/resign()``. Nothing proved
/// that, and nothing proved the exemption cannot fire while frozen. Both are
/// proved here against what the transport was actually handed.
///
/// The rest covers the orderings the other suites do not reach: a drop that
/// arrives *after* the match ended, a win that arrives *while* frozen, a peer
/// that leaves a second time, and the true before/after A-B that "the match is
/// exactly where it was" asks for — snapshot taken before the drop and compared
/// after the peer is back, not while it is still away.
///
/// Time is the injected `sleepFor` seam throughout: a real thirty-second window
/// parked at process exit takes the test helper down with it.
@MainActor
@Suite("Match session terminal gate")
struct MatchSessionTerminalGateTests {

    typealias Terminal = MatchSessionTerminalTests

    static let alice = Terminal.alice
    static let bob = Terminal.bob

    /// Every `.win` and `.resign` the endpoint was actually handed.
    static func terminalsOnTheWire(
        _ wire: Terminal.PresenceTransport
    ) async -> (wins: Int, resignations: Int) {
        let sent = await wire.wire
        var wins = 0
        var resignations = 0
        for message in sent {
            switch message {
            case .win: wins += 1
            case .resign: resignations += 1
            default: break
            }
        }
        return (wins, resignations)
    }

    // MARK: - The exemption cannot be widened: a second terminal message

    /// `blockedByLock` lets any `.win` or `.resign` past whenever the session is
    /// not frozen, so a finished session would emit a second one if anything
    /// could enqueue it. Only the entry guard stops that, and this is the check
    /// that the entry guard is load-bearing rather than decorative.
    @Test("A finished session emits exactly one terminal message however often the shell presses")
    func aSecondTerminalMessageNeverReachesTheWire() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        try await Terminal.stock(guest, wire)

        #expect(guest.claimWin())
        try await Terminal.waitUntil("the win to reach the wire") { await wire.count == 1 }
        #expect(guest.state.status == .finished(winner: Self.bob))

        // Every further press the shell could make on an end screen.
        #expect(guest.claimWin() == false)
        #expect(guest.claimWin() == false)
        #expect(guest.resign() == false)
        guest.startMatch(seed: 7, startingHandSize: 3, countdownSeconds: 2)
        try await Terminal.settle()

        // Not "one more did not change the winner" — nothing more was ever
        // handed to the transport.
        let terminals = await Self.terminalsOnTheWire(wire)
        #expect(terminals.wins == 1)
        #expect(terminals.resignations == 0)
        #expect(await wire.count == 1)
        #expect(guest.winner == Self.bob)
        #expect(guest.state.status == .finished(winner: Self.bob))

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - The exemption cannot fire while frozen

    /// A win claimed while the peer was still there, still sitting on the chain
    /// when the peer goes. The exemption is gated on `!isFrozen`, so this one has
    /// to be swallowed — a frozen session sends nothing, terminal message or not.
    ///
    /// The same drop also arrives at a session that has already finished, which
    /// is the branch that must report `.gone` rather than open a reconnecting
    /// banner over an end screen, and must not disturb the winner it already has.
    @Test("A win still on the chain when the peer leaves is swallowed, and the drop keeps the winner")
    func aTerminalMessageQueuedWhenThePeerLeavesNeverReachesTheWire() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        try await Terminal.stock(guest, wire)

        // The gate parks the draw request inside the transport, so the win that
        // follows it is genuinely still on the session's chain. No sleep, no race.
        await wire.closeGate()
        #expect(guest.draw())
        try await Terminal.waitUntil("the request to be handed over") { await wire.parkedCount == 1 }
        #expect(guest.claimWin())
        #expect(guest.state.status == .finished(winner: Self.bob))

        wire.drop(Self.alice)
        try await Terminal.waitUntil("the session to freeze") { guest.peerPresence != .present }

        // A drop onto a match that already has a winner is not a reconnection to
        // wait for: no banner, no countdown, and the winner stands.
        #expect(guest.peerPresence == .gone)
        #expect(guest.winner == Self.bob)
        #expect(guest.state.status == .finished(winner: Self.bob))
        #expect(guest.isMatchOver)

        await wire.releaseAll()
        try await Terminal.settle()

        // The request that was already in the transport's hands lands. The win
        // behind it does not: the exemption is off while frozen.
        let terminals = await Self.terminalsOnTheWire(wire)
        #expect(terminals.wins == 0)
        #expect(terminals.resignations == 0)
        #expect(await wire.drawRequests == 1)
        #expect(await wire.count == 1)
        #expect(guest.winner == Self.bob)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - A win that arrives while frozen

    /// The freeze deliberately lets `.win` and `.resign` through, so a peer that
    /// won before it dropped is honoured. The window it opened is still parked on
    /// the clock; letting it expire must not overwrite the winner with the
    /// no-winner ending, and must not put the board back in play.
    @Test("A win landing while frozen names the peer, and the deadline expiring cannot rename it")
    func aWinWhileFrozenSurvivesTheDeadlinePassing() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        let tiles = try await Terminal.stock(guest, wire)

        wire.drop(Self.alice)
        try await Terminal.waitUntil("the session to freeze") { guest.peerPresence != .present }
        try await Terminal.waitUntil("the window to ask for its time") { clock.parkedCount == 1 }

        let winnersBoard = [
            Placement(tile: Tile(letter: "Z"), coord: Coord(row: 4, col: 4)),
            Placement(tile: Tile(letter: "Y"), coord: Coord(row: 4, col: 5)),
        ]
        wire.deliver(.win(player: Self.alice, placements: winnersBoard))
        try await Terminal.waitUntil("the win to land") { guest.isMatchOver }

        #expect(guest.state.status == .finished(winner: Self.alice))
        #expect(guest.winner == Self.alice)
        // Board identity, not a count: the letters at the coordinates the peer
        // sent, rebuilt into the board the peer had.
        let received = try #require(guest.winningPlacements)
        let rebuilt = Board(
            placements: Dictionary(received.map { ($0.coord, $0.tile) }, uniquingKeysWith: { first, _ in first })
        )
        #expect(rebuilt.tile(at: Coord(row: 4, col: 4))?.letter == "Z")
        #expect(rebuilt.tile(at: Coord(row: 4, col: 5))?.letter == "Y")
        #expect(rebuilt.placementList.count == 2)
        let settled = Terminal.snapshot(guest)

        // The reconnect window was already running when the win landed. Expiring
        // it is the hazard: the no-winner ending must not take the match back.
        clock.release(.seconds(MatchSession.reconnectGraceSeconds))
        try await Terminal.settle()

        #expect(guest.state.status == .finished(winner: Self.alice))
        #expect(guest.winner == Self.alice)
        #expect(guest.isMatchOver)
        #expect(Terminal.snapshot(guest) == settled)
        #expect(await wire.count == 0)

        // And the board stays shut.
        #expect(guest.draw() == false)
        #expect(throws: BoardActionError.drawPending) {
            try guest.place(tileID: tiles[1].id, at: Coord(row: 0, col: 1))
        }
        #expect(await wire.count == 0)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - A peer that leaves a second time

    /// The first window is cancelled by the return. A second drop has to open a
    /// fresh one — a session that reused the cancelled task would freeze with no
    /// deadline that ever expires, and the match would hang there for good.
    @Test("A peer that leaves a second time gets a fresh deadline that still ends the match")
    func aSecondDropOpensAFreshDeadline() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        let tiles = try await Terminal.stock(guest, wire)
        let before = Terminal.snapshot(guest)

        wire.drop(Self.alice)
        try await Terminal.waitUntil("the first freeze") { guest.peerPresence != .present }
        try await Terminal.waitUntil("the first window") { clock.parkedCount == 1 }
        wire.restore(Self.alice)
        try await Terminal.waitUntil("the peer to return") { guest.peerPresence == .present }

        wire.drop(Self.alice)
        try await Terminal.waitUntil("the second freeze") { guest.peerPresence != .present }
        try await Terminal.waitUntil("the second window") { clock.parkedCount == 2 }

        // A fresh window, asked for in full, with a deadline still ahead.
        #expect(clock.requested == [
            .seconds(MatchSession.reconnectGraceSeconds),
            .seconds(MatchSession.reconnectGraceSeconds),
        ])
        let deadline = try #require({ () -> Date? in
            guard case let .reconnecting(deadline) = guest.peerPresence else { return nil }
            return deadline
        }())
        #expect(deadline > Date())
        #expect(guest.isMatchOver == false)
        #expect(guest.winner == nil)

        // Letting it pass ends the match, with nobody named and nothing moved.
        clock.release(.seconds(MatchSession.reconnectGraceSeconds))
        try await Terminal.waitUntil("the second deadline to pass") { guest.peerPresence == .gone }

        #expect(guest.isMatchOver)
        #expect(guest.winner == nil)
        #expect(guest.winningPlacements == nil)
        #expect(guest.state.status == .playing)
        #expect(Terminal.snapshot(guest) == before)
        #expect(guest.draw() == false)
        #expect(throws: BoardActionError.drawPending) {
            try guest.place(tileID: tiles[1].id, at: Coord(row: 0, col: 1))
        }
        #expect(await wire.count == 0)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - Guardrail 1: exactly where it was, read after the peer is back

    /// The criteria suite reads the frozen state while the peer is still away.
    /// The guardrail is about the state the returning peer finds, so this one
    /// takes the snapshot before the drop and compares it *after* the return,
    /// with every message kind the wire can carry and every press the shell has
    /// aimed at the session in between.
    @Test("A peer that comes back finds the match byte-for-byte where it left it, and play resumes")
    func aReturningPeerFindsTheMatchExactlyWhereItWas() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        let tiles = try await Terminal.stock(guest, wire)
        let before = Terminal.snapshot(guest)
        let sentBefore = await wire.count

        wire.drop(Self.alice)
        try await Terminal.waitUntil("the session to freeze") { guest.peerPresence != .present }

        // Everything the wire can carry, and everything the shell can press.
        wire.deliver(.start(version: WireFormat.current, seed: 42, startingHandSize: 5, countdownSeconds: 7))
        wire.deliver(.grant(player: Self.bob, tiles: [Tile(letter: "Q")]))
        wire.deliver(.swapGrant(player: Self.bob, tiles: [Tile(letter: "R")], returned: tiles[1]))
        wire.deliver(.poolExhausted)
        wire.deliver(.rejected(reason: .unknownPlayer))
        #expect(guest.draw() == false)
        #expect(guest.swap(tiles[1]) == false)
        #expect(guest.claimWin() == false)
        #expect(guest.resign() == false)
        guest.startMatch(seed: 9, startingHandSize: 4, countdownSeconds: 3)
        #expect(throws: BoardActionError.drawPending) {
            try guest.place(tileID: tiles[1].id, at: Coord(row: 0, col: 1))
        }
        #expect(throws: BoardActionError.drawPending) {
            try guest.recall(from: Coord(row: 0, col: 0))
        }
        try await Terminal.settle()

        wire.restore(Self.alice)
        try await Terminal.waitUntil("the peer to return") { guest.peerPresence == .present }
        try await Terminal.settle()

        // The A-B the guardrail asks for: what the peer comes back to is what it
        // left, and nothing was queued up to be replayed on the way back in.
        #expect(Terminal.snapshot(guest) == before)
        #expect(guest.state.hand.map(\.id) == [tiles[1].id, tiles[2].id])
        #expect(guest.state.board.tile(at: Coord(row: 0, col: 0))?.id == tiles[0].id)
        #expect(guest.pendingDrawTiles.isEmpty)
        #expect(guest.poolIsExhausted == false)
        #expect(guest.isMatchOver == false)
        #expect(guest.winner == nil)
        #expect(await wire.count == sentBefore)

        // And the session is live again rather than merely unfrozen: a press now
        // does reach the wire.
        #expect(guest.draw())
        try await Terminal.waitUntil("the request to reach the wire") { await wire.count == sentBefore + 1 }
        #expect(await wire.drawRequests == 1)
        try guest.place(tileID: tiles[1].id, at: Coord(row: 0, col: 1))
        #expect(guest.state.board.placementList.count == 2)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }
}
