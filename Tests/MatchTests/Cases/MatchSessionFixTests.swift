import Foundation
import Testing
import WillagramsRules
@testable import Match

/// Cover for the three review findings the fix pass closed, each pinned by the
/// failure mode it fixes rather than by the shape of the fix.
///
/// All three are negative or absence-shaped — work that must *not* reach the
/// wire, a presence that must *not* stay `.reconnecting`, a `.gone` that must
/// *not* be undone — so each drives the real entry points the shell and the
/// transport drive and reads back what the transport was actually handed.
///
/// Time is the injected clock throughout; a real reconnect window parked at
/// process exit takes the test helper down with it.
@MainActor
@Suite("Match session fix pass")
struct MatchSessionFixTests {

    typealias Terminal = MatchSessionTerminalTests

    static let alice = Terminal.alice
    static let bob = Terminal.bob

    // MARK: - leave() stops the whole chain, not only its tail

    /// `leave()` cancels `tail`, which is the *last* task enqueued. A task
    /// already in the chain behind a send parked inside the transport is not
    /// reached by that cancel, and would go on to hand the wire a request from a
    /// session the player has walked out of.
    ///
    /// Three requests, so there is a genuine predecessor: the first parks inside
    /// the transport, the third is `tail`, and the second is the one only the
    /// lock can stop.
    @Test("Leaving stops work already sitting behind a parked send, not only the last task enqueued")
    func leavingStopsChainPredecessorsFromReachingTheWire() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        try await Terminal.stock(guest, wire)
        #expect(await wire.count == 0)

        await wire.closeGate()
        #expect(guest.draw())
        try await Terminal.waitUntil("the first request to be handed over") {
            await wire.parkedCount == 1
        }
        // Behind the parked one: neither has reached the transport yet.
        #expect(guest.draw())
        #expect(guest.draw())

        guest.leave()
        await wire.releaseAll()
        try await Terminal.settle()

        // Only the request that was already in the transport's hands lands.
        #expect(await wire.drawRequests == 1)
        #expect(await wire.count == 1)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - A terminal message honoured while frozen closes the window

    /// The freeze lets a peer's `.win` through, and `finish()` cancels the
    /// reconnect window it opened. Leaving the presence at `.reconnecting` after
    /// that is a banner and a countdown to a deadline nothing will ever reach,
    /// over an end screen — the shell has no way to tell it is dead.
    @Test("A win honoured while frozen collapses the reconnecting presence rather than leaving a dead countdown")
    func aWinWhileFrozenCollapsesTheReconnectingPresence() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        try await Terminal.stock(guest, wire)

        wire.drop(Self.alice)
        try await Terminal.waitUntil("the session to freeze") { guest.peerPresence != .present }
        try await Terminal.waitUntil("the window to ask for its time") { clock.parkedCount == 1 }
        #expect(guest.peerPresence != .gone)

        wire.deliver(.win(player: Self.alice, placements: []))
        try await Terminal.waitUntil("the win to land") { guest.isMatchOver }
        try await Terminal.settle()

        // No banner, no countdown — and the winner the message named stands.
        #expect(guest.peerPresence == .gone)
        #expect(guest.winner == Self.alice)
        #expect(guest.state.status == .finished(winner: Self.alice))

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - `.gone` on a live match stays terminal

    /// The flush path acts on a peer coming back, so the guard that keeps it off
    /// a match that merely ran out of window is load-bearing: a session whose
    /// deadline passed is over with nobody named, and a late `.connected` must
    /// not thaw it back into play.
    @Test("A peer returning after the deadline passed cannot put a match with no winner back into play")
    func aReturnAfterTheDeadlineCannotThawTheMatch() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        let tiles = try await Terminal.stock(guest, wire)
        let before = Terminal.snapshot(guest)

        wire.drop(Self.alice)
        try await Terminal.waitUntil("the session to freeze") { guest.peerPresence != .present }
        try await Terminal.waitUntil("the window to ask for its time") { clock.parkedCount == 1 }
        clock.release(.seconds(MatchSession.reconnectGraceSeconds))
        try await Terminal.waitUntil("the deadline to pass") { guest.peerPresence == .gone }

        wire.restore(Self.alice)
        try await Terminal.settle()

        #expect(guest.peerPresence == .gone)
        #expect(guest.isMatchOver)
        #expect(guest.winner == nil)
        #expect(Terminal.snapshot(guest) == before)
        #expect(guest.draw() == false)
        #expect(guest.claimWin() == false)
        #expect(throws: BoardActionError.drawPending) {
            try guest.place(tileID: tiles[1].id, at: Coord(row: 0, col: 1))
        }
        try await Terminal.settle()
        #expect(await wire.count == 0)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }
}
