import Foundation
import Testing
import WillagramsRules
@testable import Match

/// The draw button handing out a burst of tiles.
///
/// `outstandingDrawRequests` was incremented and decremented but never
/// compared, and nothing else could stand in for it: the board stays complete
/// and the hand stays empty for the whole round trip, so `canDraw` — the HUD's
/// gate — is still true while a request is in flight. N fast presses therefore
/// sent N `.drawRequest`s, each draining a full round from the pool
/// all-or-nothing, each handing the opponent another obligation, and the N
/// grants landed together: nothing appeared, and then everything did.
///
/// Driven through the real `draw()` entry point, reading back what the
/// transport was actually handed.
@MainActor
@Suite("Draw refuses a second request")
struct MatchSessionDrawBurstTests {

    typealias Terminal = MatchSessionTerminalTests

    @Test("Pressing draw five times fast puts exactly one request on the wire")
    func aBurstOfPressesSendsOneRequest() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)

        #expect(guest.draw())
        // Refused, not merely deduplicated on the wire: the press returns false
        // so `MatchHUDModel.draw()` routes it to `refuse()` and the player gets
        // the invalid flash instead of silence.
        for _ in 0..<4 { #expect(guest.draw() == false) }
        try await Terminal.settle()

        #expect(await wire.drawRequests == 1)
        #expect(await wire.count == 1)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    @Test("The press after the answer lands sends the next request")
    func theNextPressAfterTheAnswerIsAllowed() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)

        #expect(guest.draw())
        #expect(guest.draw() == false)

        // The answer clears the credit, and the latch opens again. Without this
        // the guard would not be a guard, it would be a one-shot.
        wire.deliver(.grant(player: Terminal.bob, tiles: [Tile(letter: "A")]))
        try await Terminal.waitUntil("the answer to land") { guest.state.hand.count == 1 }

        #expect(guest.draw())
        try await Terminal.settle()
        #expect(await wire.drawRequests == 2)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    @Test("A request the host never answered does not latch draw shut for the rest of the match")
    func aStrandedCreditIsRetiredWhenThePeerReturns() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)

        // The request leaves, and is then dropped on the host by its own frozen
        // -session guard: it is never answered and never times out.
        #expect(guest.draw())
        try await Terminal.settle()
        #expect(await wire.drawRequests == 1)

        wire.drop(Terminal.alice)
        try await Terminal.waitUntil("the session to freeze") { guest.peerPresence != .present }
        wire.restore(Terminal.alice)
        try await Terminal.waitUntil("the peer to return") { guest.peerPresence == .present }

        // Nothing can legitimately be in flight across a freeze, so the credit
        // standing here is one nobody will ever clear. Left at 1 it would refuse
        // every press for the rest of the match — the one-at-a-time rule turning
        // a dropped message into a permanently dead button.
        #expect(guest.draw())

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    /// The other half of the burst, and the half the guard alone did not fix:
    /// two draws crossing on the wire.
    ///
    /// Both players get a tile from every round, so this device receives tiles
    /// for two reasons, and they used to be the same message. The receiver told
    /// them apart by its own count of unanswered requests, which is wrong
    /// exactly when the two cross — the opponent's round was taken as the answer
    /// to this device's request, spent the credit, landed in the rack instead of
    /// behind the Draw gate, and reopened the gate with a real request still in
    /// flight. That is the burst, and the reason it only showed up late in a
    /// match: a full rack and a low bag is when both players draw at once.
    @Test("A peer's round crossing this device's request is held, and the answer still lands")
    func aPeersRoundDoesNotAnswerThisDevicesRequest() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)

        #expect(guest.draw())
        try await Terminal.settle()
        #expect(await wire.drawRequests == 1)

        // The opponent's round, arriving first. The wire says whose it is.
        wire.deliver(.obligation(player: Terminal.bob, tiles: [Tile(letter: "A")]))
        try await Terminal.waitUntil("the peer's round to be held") { guest.hasPendingDraw }
        #expect(guest.state.hand.isEmpty, "a peer's round was taken into the rack")

        // And then the real answer, which is the one that goes to the rack.
        wire.deliver(.grant(player: Terminal.bob, tiles: [Tile(letter: "B")]))
        try await Terminal.waitUntil("the answer to land") { guest.state.hand.count == 1 }
        #expect(guest.state.hand.first?.letter == "B")
        #expect(guest.pendingDrawTiles.count == 1, "the obligation was swallowed by the answer")

        // The credit was spent by the answer and by nothing else, so the press
        // after it is offered — it takes the tile owed rather than asking again.
        #expect(guest.draw())
        #expect(guest.hasPendingDraw == false)
        #expect(guest.state.hand.count == 2)
        try await Terminal.settle()
        #expect(await wire.drawRequests == 1, "accepting an obligation asked for a second round")

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }
}
