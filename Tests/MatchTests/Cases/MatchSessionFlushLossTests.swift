import Foundation
import Testing
import WillagramsRules
@testable import Match

/// The two loss windows of the terminal-message flush: a flush whose send
/// throws, and a flush fired by a device that has already left.
///
/// Both are absence-shaped, so each drives the real entry points — `resign()`,
/// the connection-state stream, `leave()` — and reads back what the transport
/// was actually handed, never a field on the session alone.
///
/// Time is the injected clock; a real reconnect window parked at process exit
/// takes the test helper down with it.
@MainActor
@Suite("Match session flush loss windows")
struct MatchSessionFlushLossTests {

    typealias Terminal = MatchSessionTerminalTests

    static let alice = Terminal.alice
    static let bob = Terminal.bob

    /// A resignation left owed: enqueued behind a send parked inside the
    /// transport, so the peer is gone by the time the chain reaches it and the
    /// message is remembered rather than sent.
    private static func guestOwingAResignation(
        clock: Terminal.HandCrankedClock
    ) async throws -> (guest: MatchSession, wire: Terminal.PresenceTransport) {
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        await wire.closeGate()
        #expect(guest.draw())
        try await Terminal.waitUntil("the request to be handed over") { await wire.parkedCount == 1 }

        #expect(guest.resign())
        wire.drop(Self.alice)
        // Already finished, so the drop is `.gone` outright — no window, no clock.
        try await Terminal.waitUntil("the peer to be gone") { guest.peerPresence == .gone }

        await wire.releaseAll()
        try await Terminal.settle()
        // The request that was in the transport's hands landed; the resignation
        // never reached it and is owed.
        #expect(await wire.count == 1)
        #expect(guest.winner == Self.alice)
        return (guest, wire)
    }

    // MARK: - Fix 1: a flush whose send throws is still owed

    /// The flush clears the debt synchronously and sends later on the chain. A
    /// peer that flaps again in that window makes `transport.send` throw, and
    /// without re-arming, the rebuilt terminal is gone with the flag already
    /// false — the peer never learns the match ended.
    @Test("A flush whose send throws re-arms, and the next return delivers the terminal message")
    func aFlushThatThrowsIsStillOwedAndDeliveredOnTheNextReturn() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Self.guestOwingAResignation(clock: clock)

        // The peer comes back, and the wire refuses the rebuilt resignation.
        await wire.failSends { if case .resign = $0 { return true } else { return false } }
        wire.restore(Self.alice)
        try await Terminal.waitUntil("the flush to unfreeze") { guest.peerPresence == .present }
        try await Terminal.settle()
        #expect(await wire.count == 1)  // nothing landed

        // It flaps once more, and this time the wire carries it.
        await wire.failSends(nil)
        wire.drop(Self.alice)
        try await Terminal.waitUntil("the peer to be gone again") { guest.peerPresence == .gone }
        wire.restore(Self.alice)
        try await Terminal.waitUntil("the resignation to reach the wire") { await wire.count == 2 }

        // Identity, not a count: the message the peer is owed, naming this device.
        #expect(await wire.wire.last == .resign(player: Self.bob))
        // And the outcome never moved.
        #expect(guest.winner == Self.alice)
        #expect(guest.state.status == .finished(winner: Self.alice))
        #expect(guest.isMatchOver)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - Fix 2: a device that left sends nothing

    /// `leave()` cancels the presence pump, but a `.connected` already buffered
    /// when it does can still be delivered. The flush would then hand the wire a
    /// message from a session the player has walked out of.
    @Test("A device that has left sends nothing, even when a buffered reconnect lands after leave()")
    func aDeviceThatLeftSendsNothingOnALateReconnect() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Self.guestOwingAResignation(clock: clock)

        // Buffered first, then the player leaves: both on the main actor with no
        // suspension between, so the pump cannot have consumed it yet.
        wire.restore(Self.alice)
        guest.leave()
        try await Terminal.settle()

        #expect(await wire.count == 1)
        #expect(await wire.wire.contains(.resign(player: Self.bob)) == false)
        #expect(guest.peerPresence == .gone)
        #expect(guest.winner == Self.alice)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }
}
