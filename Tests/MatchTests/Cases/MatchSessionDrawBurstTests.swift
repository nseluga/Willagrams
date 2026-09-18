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
}
