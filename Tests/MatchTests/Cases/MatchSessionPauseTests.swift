import Foundation
import Testing
import WillagramsRules
@testable import Match

/// Pause by agreement.
///
/// A vote is a wish and never the state. The device that runs the pool turns
/// the pause on when everyone wants it and off when nobody does, and every
/// other device takes its word. So a pause needs both players, a resume needs
/// both players, and two devices cannot end up disagreeing.
///
/// A pause shuts a player's own moves and nothing else: a tile the host has
/// already taken out of the pool still lands.
@MainActor
@Suite("Match session pause: both agree, both resume, nobody disagrees")
struct MatchSessionPauseTests {

    typealias Terminal = MatchSessionTerminalTests
    typealias Flow = MatchSessionMatchFlowTests
    typealias Table = MatchSessionMatchFlowTests.Table

    static let alice = Terminal.alice
    static let bob = Terminal.bob

    static func isPauseState(_ message: MatchMessage) -> Bool {
        if case .pauseState = message { return true }
        return false
    }

    static func isPauseVote(_ message: MatchMessage) -> Bool {
        if case .pauseVote = message { return true }
        return false
    }

    /// The host has decided `count` times. It decides once per vote it handles,
    /// its own or the guest's, so this is "the host has handled `count` votes".
    static func hostDecided(_ count: Int, _ table: Table) async throws {
        try await Terminal.waitUntil("the host's decision number \(count)") {
            await table.hostWire.wire.filter(Self.isPauseState).count == count
        }
    }

    static func guestVoted(_ count: Int, _ table: Table) async throws {
        try await Terminal.waitUntil("the guest's vote number \(count)") {
            await table.guestWire.wire.filter(Self.isPauseVote).count == count
        }
    }

    /// One vote, carried all the way: to the host, which decides, and back.
    /// `decisions` and `guestVotes` count what has been said so far.
    static func vote(
        _ player: PlayerID, _ wanted: Bool, at table: inout Table,
        decisions: inout Int, guestVotes: inout Int
    ) async throws {
        if player == alice {
            table.host.votePause(wanted)
        } else {
            table.guest.votePause(wanted)
            guestVotes += 1
            try await guestVoted(guestVotes, table)
            await table.guestToHost()
        }
        decisions += 1
        try await hostDecided(decisions, table)
        await table.hostToGuest()
        let host = table.host
        let guest = table.guest
        try await Terminal.waitUntil("the guest to hold the host's answer") {
            guest.isPaused == host.isPaused
                && Set(guest.playersWantingPause) == Set(host.playersWantingPause)
        }
    }

    /// Both players agreed, and both devices say so.
    static func pausedTable() async throws -> Table {
        var table = try await Flow.dealtTable()
        var decisions = 0
        var guestVotes = 0
        try await vote(bob, true, at: &table, decisions: &decisions, guestVotes: &guestVotes)
        try await vote(alice, true, at: &table, decisions: &decisions, guestVotes: &guestVotes)
        #expect(table.host.isPaused)
        #expect(table.guest.isPaused)
        return table
    }

    // MARK: - Both players, both ways

    @Test("One vote asks, two votes pause, and resuming takes both again")
    func pausingAndResumingBothNeedBothPlayers() async throws {
        var table = try await Flow.dealtTable()
        var decisions = 0
        var guestVotes = 0

        try await Self.vote(Self.bob, true, at: &table, decisions: &decisions, guestVotes: &guestVotes)
        #expect(table.host.isPaused == false)
        #expect(table.guest.isPaused == false)
        // The other side can see it has been asked.
        #expect(table.host.playersWantingPause == [Self.bob])
        #expect(table.host.wasPaused == false)

        try await Self.vote(Self.alice, true, at: &table, decisions: &decisions, guestVotes: &guestVotes)
        #expect(table.host.isPaused)
        #expect(table.guest.isPaused)

        try await Self.vote(Self.alice, false, at: &table, decisions: &decisions, guestVotes: &guestVotes)
        #expect(table.host.isPaused)
        #expect(table.guest.isPaused)
        #expect(table.guest.playersWantingPause == [Self.bob])

        try await Self.vote(Self.bob, false, at: &table, decisions: &decisions, guestVotes: &guestVotes)
        #expect(table.host.isPaused == false)
        #expect(table.guest.isPaused == false)
        #expect(table.host.wasPaused)
        #expect(table.guest.wasPaused)
        await table.leave()
    }

    @Test("A paused match refuses a player's own moves, and takes them again once resumed")
    func aPauseShutsMovesAndAResumeOpensThem() async throws {
        var table = try await Self.pausedTable()
        let guest = table.guest
        let tile = guest.state.hand[0]

        #expect(guest.draw() == false)
        #expect(guest.swap(tile) == false)
        #expect(guest.claimWin() == false)
        #expect(throws: BoardActionError.self) {
            try guest.place(tileID: tile.id, at: Coord(row: 0, col: 0))
        }
        #expect(guest.state.hand.count == 3)

        var decisions = 2
        var guestVotes = 1
        try await Self.vote(Self.bob, false, at: &table, decisions: &decisions, guestVotes: &guestVotes)
        try await Self.vote(Self.alice, false, at: &table, decisions: &decisions, guestVotes: &guestVotes)
        try guest.place(tileID: tile.id, at: Coord(row: 0, col: 0))
        #expect(guest.draw())
        await table.leave()
    }

    @Test("A pause state that reaches the device running the pool is dropped")
    func theHostTakesThePauseFromNobody() async throws {
        let table = try await Flow.dealtTable()
        table.hostWire.deliver(.pauseState(paused: true))
        // A vote in somebody else's name, or in the receiver's own, counts for nothing.
        table.hostWire.deliver(.pauseVote(player: Self.alice, wanted: true))
        table.hostWire.deliver(.pauseVote(player: PlayerID(rawValue: "zed"), wanted: true))
        try await Terminal.settle()
        #expect(table.host.isPaused == false)
        #expect(table.host.playersWantingPause.isEmpty)
        await table.leave()
    }

    // MARK: - The two devices never disagree

    static let votes: [(player: PlayerID, wanted: Bool)] = [
        (alice, true), (bob, true), (alice, false), (bob, false),
    ]

    /// Every order of four items, as index lists.
    static let orders: [[Int]] = {
        func arrange(_ rest: [Int]) -> [[Int]] {
            guard rest.count > 1 else { return [rest] }
            return rest.indices.flatMap { index -> [[Int]] in
                var others = rest
                let first = others.remove(at: index)
                return arrange(others).map { [first] + $0 }
            }
        }
        return arrange([0, 1, 2, 3])
    }()

    /// The same four votes in all 24 orders, each order delivered two ways:
    /// every vote carried before the next is cast, and all four cast before
    /// anything is carried. The answer may differ from order to order. The two
    /// devices may not differ from each other.
    @Test("Both devices hold the same pause state after every order of a set of votes")
    func everyOrderOfTheVotesEndsInAgreement() async throws {
        #expect(Self.orders.count == 24)
        for order in Self.orders {
            for carriedAtOnce in [true, false] {
                var table = try await Flow.dealtTable()
                var decisions = 0
                var guestVotes = 0
                for index in order {
                    let (player, wanted) = Self.votes[index]
                    if carriedAtOnce {
                        try await Self.vote(
                            player, wanted, at: &table, decisions: &decisions, guestVotes: &guestVotes
                        )
                    } else if player == Self.alice {
                        table.host.votePause(wanted)
                    } else {
                        table.guest.votePause(wanted)
                    }
                }
                if !carriedAtOnce {
                    try await Self.guestVoted(2, table)
                    await table.guestToHost()
                    try await Self.hostDecided(4, table)
                    await table.hostToGuest()
                }
                try await Terminal.settle()

                let label = "order \(order), carried at once: \(carriedAtOnce)"
                #expect(table.guest.isPaused == table.host.isPaused, "\(label)")
                // What each player last said is what both devices have on record.
                let lastWish = Set([Self.alice, Self.bob].filter { player in
                    Self.votes[order.last { Self.votes[$0].player == player }!].wanted
                })
                #expect(Set(table.host.playersWantingPause) == lastWish, "\(label)")
                #expect(Set(table.guest.playersWantingPause) == lastWish, "\(label)")
                await table.leave()
            }
        }
    }

    // MARK: - A peer that never answers

    /// A 1.0 build drops both pause kinds, so it never votes and never hears a
    /// pause. Whichever side it is on, the newer build must play on.
    @Test("A request nobody answers leaves the match playable and can be taken back")
    func anUnansweredRequestPausesNothing() async throws {
        let table = try await Flow.dealtTable()

        // The newer build runs the pool; the guest says nothing.
        table.host.votePause(true)
        try await Self.hostDecided(1, table)
        #expect(table.host.isPaused == false)
        #expect(table.host.playersWantingPause == [Self.alice])
        #expect(table.host.draw())
        try await Terminal.waitUntil("the host's tile") { Flow.held(table.host) == 4 }
        table.host.votePause(false)
        #expect(table.host.playersWantingPause.isEmpty)

        // The newer build is the guest; the host never decides anything.
        table.guest.votePause(true)
        try await Self.guestVoted(1, table)
        try await Terminal.settle()
        #expect(table.guest.isPaused == false)
        try table.guest.place(tileID: table.guest.state.hand[0].id, at: Coord(row: 0, col: 0))
        #expect(table.guest.draw())
        table.guest.votePause(false)
        #expect(table.guest.playersWantingPause.isEmpty)
        #expect(table.guest.isPaused == false)
        await table.leave()
    }

    // MARK: - No tile is lost to a pause

    @Test("A draw already asked for is answered during a pause, and its tiles land")
    func aRoundInFlightLandsDuringAPause() async throws {
        var table = try await Self.pausedTable()
        let starting = table.everyTile

        // The guest's request was on its way when the pause took hold.
        table.hostWire.deliver(.drawRequest(player: Self.bob))
        try await Terminal.waitUntil("the host's tile for the round") { Flow.held(table.host) == 4 }
        await table.hostToGuest()
        try await Terminal.waitUntil("the guest's tile for the round") { Flow.held(table.guest) == 4 }

        #expect(table.guest.state.hand.count == 4)
        #expect(table.everyTile == starting)
        #expect(table.host.isPaused)
        #expect(table.guest.isPaused)
        await table.leave()
    }

    /// The guest loses sight of the host during a pause, and both players
    /// choose to resume while it cannot be heard. What the guest said in that
    /// gap never left its device, so it says it again on the way back.
    @Test("Both devices hold the same pause state after the guest reconnects")
    func theGuestReconnectsIntoTheSameState() async throws {
        var table = try await Self.pausedTable()

        table.guestWire.drop(Self.alice)
        try await Terminal.waitUntil("the guest to freeze") { table.guest.peerPresence != .present }
        table.guest.votePause(false)
        table.host.votePause(false)
        try await Self.hostDecided(3, table)
        await table.hostToGuest()
        try await Terminal.settle()
        // The host has not heard the guest, so the pause holds on both.
        #expect(table.host.isPaused)
        #expect(table.guest.isPaused)

        table.guestWire.restore(Self.alice)
        try await Terminal.crank(
            table.guestClock, releasing: .seconds(1), until: "the guest to say its vote again"
        ) { table.guest.peerPresence == .present }
        try await Self.guestVoted(2, table)
        await table.guestToHost()
        try await Self.hostDecided(4, table)
        await table.hostToGuest()
        try await Terminal.waitUntil("the guest to resume") { !table.guest.isPaused }

        #expect(table.host.isPaused == false)
        #expect(table.host.playersWantingPause.isEmpty)
        #expect(table.guest.playersWantingPause.isEmpty)
        await table.leave()
    }

    /// The same gap from the other side. The host decides while it cannot be
    /// heard, so on the way back it says both its vote and its decision again.
    @Test("Both devices hold the same pause state after the host reconnects")
    func theHostReconnectsIntoTheSameState() async throws {
        var table = try await Self.pausedTable()

        table.hostWire.drop(Self.bob)
        try await Terminal.waitUntil("the host to freeze") { table.host.peerPresence != .present }
        table.guest.votePause(false)
        try await Self.guestVoted(2, table)
        await table.guestToHost()
        try await Terminal.waitUntil("the host to hear the guest") {
            table.host.playersWantingPause == [Self.alice]
        }
        table.host.votePause(false)
        // Decided on the host, and said to nobody yet.
        #expect(table.host.isPaused == false)
        await table.hostToGuest()
        try await Terminal.settle()
        #expect(table.guest.isPaused)

        table.hostWire.restore(Self.bob)
        try await Terminal.crank(
            table.hostClock, releasing: .seconds(1), until: "the host to say its decision again"
        ) { table.host.peerPresence == .present }
        try await Terminal.waitUntil("the decision to reach the wire") {
            await table.hostWire.wire.contains(.pauseState(paused: false))
        }
        await table.hostToGuest()
        try await Terminal.waitUntil("the guest to resume") { !table.guest.isPaused }
        #expect(table.guest.playersWantingPause.isEmpty)
        await table.leave()
    }

    // MARK: - One device, nobody to ask

    @Test("A local pause shuts moves at once and a local resume opens them")
    func aLocalPauseNeedsNobody() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        let before = await wire.wire.count

        guest.setPausedLocally(true)
        #expect(guest.isPaused)
        #expect(guest.draw() == false)
        guest.setPausedLocally(false)
        #expect(guest.isPaused == false)
        #expect(guest.wasPaused)
        #expect(guest.draw())

        try await Terminal.waitUntil("the draw request") { await wire.drawRequests == 1 }
        // Nothing about the pause went anywhere.
        #expect(await wire.wire.count == before + 1)
        guest.leave()
        clock.releaseAll()
    }
}
