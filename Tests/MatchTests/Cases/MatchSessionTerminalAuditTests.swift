import Foundation
import Testing
import WillagramsRules
@testable import Match

/// Independent cover for the terminal states, aimed at the four criteria's
/// *negative* halves — nothing sent, nothing moved, nobody named — and at the
/// paths the criteria tests do not walk: the host's pool submissions, the two
/// transport streams, forged terminal messages, and a settled match under every
/// message kind the wire can carry.
///
/// Everything drives the production entry points (`startMatch`, `draw`, `swap`,
/// `place`, `recall`, `claimWin`, `resign`) or the real inbound pump, and reads
/// what a caller can observe or what the transport was actually handed. Nothing
/// re-derives a property from an internal helper.
///
/// Time is the session's injected `sleepFor` seam in every test that needs any:
/// a real thirty-second window parked at process exit takes the test helper
/// down with it. Every cross-task wait races a deadline and throws, so a message
/// that never arrives fails in seconds rather than hanging an unattended run.
@MainActor
@Suite("Match session terminal audit")
struct MatchSessionTerminalAuditTests {

    /// The fixtures the criteria suite already owns. Reused rather than
    /// rebuilt — a second copy of a fake transport is a second thing to keep
    /// honest.
    typealias Terminal = MatchSessionTerminalTests

    static let alice = Terminal.alice
    static let bob = Terminal.bob

    // MARK: - Fixtures

    /// A transport that counts how many times each stream property is read.
    ///
    /// Both streams are single-subscription by contract: a second
    /// `makeAsyncIterator()` divides the elements between the two iterators
    /// rather than failing, and the symptom is a message that simply never
    /// arrives. Counting the reads is the only deterministic way to see that
    /// from outside.
    final class CountingTransport: MatchTransport, @unchecked Sendable {

        let localPlayerID: PlayerID

        private let lock = NSLock()
        private var inboundReadCount = 0
        private var stateReadCount = 0

        private let messages: AsyncStream<MatchMessage>
        private let connections: AsyncStream<PeerConnectionState>
        private let inbound: AsyncStream<MatchMessage>.Continuation
        private let states: AsyncStream<PeerConnectionState>.Continuation

        init(localPlayerID: PlayerID, peer: PlayerID) {
            let messageStream = AsyncStream.makeStream(of: MatchMessage.self, bufferingPolicy: .unbounded)
            let connectionStream = AsyncStream.makeStream(
                of: PeerConnectionState.self,
                bufferingPolicy: .unbounded
            )
            self.localPlayerID = localPlayerID
            self.messages = messageStream.stream
            self.connections = connectionStream.stream
            self.inbound = messageStream.continuation
            self.states = connectionStream.continuation
            connectionStream.continuation.yield(.connected(peer))
        }

        var inboundMessages: AsyncStream<MatchMessage> {
            lock.lock()
            inboundReadCount += 1
            lock.unlock()
            return messages
        }

        var peerConnectionStates: AsyncStream<PeerConnectionState> {
            lock.lock()
            stateReadCount += 1
            lock.unlock()
            return connections
        }

        func send(_ message: MatchMessage, delivery: MatchDelivery) async throws {}

        func leave() {
            inbound.finish()
            states.finish()
        }

        // MARK: Hooks

        func deliver(_ message: MatchMessage) { inbound.yield(message) }
        func drop(_ player: PlayerID) { states.yield(.disconnected(player)) }
        func restore(_ player: PlayerID) { states.yield(.connected(player)) }

        // MARK: Readings

        var inboundReads: Int {
            lock.lock()
            defer { lock.unlock() }
            return inboundReadCount
        }

        var stateReads: Int {
            lock.lock()
            defer { lock.unlock() }
            return stateReadCount
        }
    }

    /// A started host — `alice` holds the pool — on a transport the test drives,
    /// past its countdown, with the opening `.start` already on the wire.
    static func playingHost(
        clock: Terminal.HandCrankedClock
    ) async throws -> (host: MatchSession, wire: Terminal.PresenceTransport) {
        #expect(HostPool.host(of: alice, bob) == alice)
        let wire = Terminal.PresenceTransport(localPlayerID: alice, peer: bob)
        let host = MatchSession(
            transport: wire,
            peerPlayerID: bob,
            dictionary: Terminal.EveryWordIsReal(),
            sleepFor: { await clock.tick($0) }
        )
        host.startMatch(seed: 3, startingHandSize: 21, countdownSeconds: 0, options: .standard)
        #expect(host.state.status == .playing)
        // The gate below only means anything once the opening send is past it.
        try await Terminal.waitUntil("the opening start to reach the wire") { await wire.count == 1 }
        return (host, wire)
    }

    // MARK: - Criterion 3: the host's half of "a frozen session sends nothing"

    /// The guest's `send` chain is covered by the criteria suite. This is the
    /// other outbound path: a host's own request goes to the pool, never on the
    /// wire, and a pool submission that reaches `HostPool.handle` after the peer
    /// left both moves the pool and puts a grant on the wire.
    @Test("A pool submission enqueued before the peer left never reaches the pool or the wire")
    func aPoolSubmissionEnqueuedBeforeTheDropNeverRuns() async throws {
        let clock = Terminal.HandCrankedClock()
        let (host, wire) = try await Self.playingHost(clock: clock)

        // The gate parks the first submission *inside* `handle`'s send, so the
        // second is still sitting on the session's chain when the peer goes.
        // No sleep, and no race to lose.
        await wire.closeGate()
        #expect(host.draw())
        #expect(host.draw())
        try await Terminal.waitUntil("the first submission to reach the pool") {
            await wire.parkedCount == 1
        }

        wire.drop(Self.bob)
        try await Terminal.waitUntil("the session to freeze") { host.peerPresence != .present }
        await wire.releaseAll()
        try await Terminal.settle()

        // One round left the pool — the one already in the pool's hands. The
        // second never reached it: no second grant on the wire, and no second
        // tile in the host's own rack, which is where the host takes its half.
        #expect(await wire.count == 2)
        let landed = await wire.wire
        let grantsToPeer = landed.filter { message in
            if case let .grant(player, _) = message { return player == Self.bob }
            return false
        }
        #expect(grantsToPeer.count == 1)
        #expect(host.state.hand.count == 1)
        #expect(host.pendingDrawTiles.isEmpty)
        #expect(host.poolIsExhausted == false)
        #expect(host.isMatchOver == false)
        #expect(host.winner == nil)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - Stream consumption

    @Test("Each transport stream is read once and consumed by exactly one iterator")
    func eachStreamHasExactlyOneConsumer() async throws {
        let clock = Terminal.HandCrankedClock()
        let wire = CountingTransport(localPlayerID: Self.bob, peer: Self.alice)
        let guest = MatchSession(
            transport: wire,
            peerPlayerID: Self.alice,
            dictionary: Terminal.EveryWordIsReal(),
            sleepFor: { await clock.tick($0) }
        )
        wire.deliver(
            .start(version: WireFormat.current, seed: 1, startingHandSize: 21, countdownSeconds: 0, options: .standard)
        )
        try await Terminal.waitUntil("the guest to be playing") { guest.state.status == .playing }

        // Each stream property read exactly once. Reading either twice and
        // iterating both halves the stream rather than failing.
        #expect(wire.inboundReads == 1)
        #expect(wire.stateReads == 1)

        // And the elements are not divided: every one of six offers lands.
        let offered = (0..<6).map { Tile(letter: $0.isMultiple(of: 2) ? "A" : "B") }
        for tile in offered { wire.deliver(.grant(player: Self.bob, tiles: [tile])) }
        try await Terminal.waitUntil("all six offers to land") { guest.pendingDrawTiles.count == 6 }
        #expect(guest.pendingDrawTiles.map(\.id) == offered.map(\.id))

        // The connection stream is not divided either: a drop and a return both
        // reach the one consumer.
        wire.drop(Self.alice)
        try await Terminal.waitUntil("the session to freeze") { guest.peerPresence != .present }
        wire.restore(Self.alice)
        try await Terminal.waitUntil("the peer to return") { guest.peerPresence == .present }
        #expect(wire.inboundReads == 1)
        #expect(wire.stateReads == 1)

        guest.leave()
        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - Trust boundary

    /// A forged terminal message is the highest-value thing a modified peer can
    /// send: one `.win` naming *this* device, or one `.resign` naming it, hands
    /// the match to whoever the attacker chose. Both are refused live and
    /// frozen — frozen matters because the freeze deliberately lets `.win` and
    /// `.resign` through its filter.
    @Test("A win or a resignation naming this device off the wire is ignored, live and frozen")
    func aForgedTerminalMessageNamingThisDeviceIsIgnored() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        let tiles = try await Terminal.stock(guest, wire)

        let forgedBoard = [Placement(tile: Tile(letter: "Z"), coord: Coord(row: 9, col: 9))]
        wire.deliver(.win(player: Self.bob, placements: forgedBoard))
        wire.deliver(.resign(player: Self.bob))
        try await Terminal.settle()

        #expect(guest.isMatchOver == false)
        #expect(guest.winner == nil)
        #expect(guest.winningPlacements == nil)
        #expect(guest.state.status == .playing)

        // A marker whose effect can only follow the two above: the pump is FIFO
        // and `receive` is synchronous, so this landing proves they were read
        // rather than still queued behind the assertions.
        let marker = Tile(letter: "M")
        wire.deliver(.grant(player: Self.bob, tiles: [marker]))
        try await Terminal.waitUntil("the marker to land") { guest.hasPendingDraw }
        #expect(guest.pendingDrawTiles.map(\.id) == [marker.id])

        // Frozen, the same two forgeries pass the freeze filter — `.win` and
        // `.resign` are the two messages it still honours — and must still be
        // refused on who sent them.
        let before = Terminal.snapshot(guest)
        wire.drop(Self.alice)
        try await Terminal.waitUntil("the session to freeze") { guest.peerPresence != .present }
        wire.deliver(.win(player: Self.bob, placements: forgedBoard))
        wire.deliver(.resign(player: Self.bob))
        try await Terminal.settle()

        #expect(guest.isMatchOver == false)
        #expect(guest.winner == nil)
        #expect(guest.winningPlacements == nil)
        #expect(Terminal.snapshot(guest) == before)
        if case .reconnecting = guest.peerPresence {} else {
            Issue.record("expected a reconnecting deadline, got \(guest.peerPresence)")
        }
        #expect(await wire.count == 0)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - `.finished` is terminal

    /// Every message kind the wire can carry, delivered to a match that already
    /// has a winner. None of them may rename the winner, reopen the board, move
    /// the rack, or latch anything.
    @Test("No message of any kind moves a match that already has a winner")
    func nothingReopensAFinishedMatch() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)
        let tiles = try await Terminal.stock(guest, wire)

        let winnersBoard = [Placement(tile: Tile(letter: "Z"), coord: Coord(row: 9, col: 9))]
        wire.deliver(.win(player: Self.alice, placements: winnersBoard))
        try await Terminal.waitUntil("the win to land") { guest.isMatchOver }
        #expect(guest.state.status == .finished(winner: Self.alice))
        #expect(guest.winner == Self.alice)
        #expect(guest.winningPlacements == winnersBoard)
        let settled = Terminal.snapshot(guest)

        // A second start would restart the countdown; a grant or a swap grant
        // would move the rack; exhaustion would latch; a second win or a
        // resignation would rename the winner.
        wire.deliver(.start(version: WireFormat.current, seed: 42, startingHandSize: 5, countdownSeconds: 7, options: .standard))
        wire.deliver(.grant(player: Self.bob, tiles: [Tile(letter: "Q")]))
        wire.deliver(.swapGrant(player: Self.bob, tiles: [Tile(letter: "R")], returned: tiles[1]))
        wire.deliver(.poolExhausted)
        wire.deliver(.rejected(reason: .unknownPlayer))
        wire.deliver(.win(player: Self.alice, placements: []))
        wire.deliver(.resign(player: Self.alice))
        try await Terminal.settle()

        #expect(guest.state.status == .finished(winner: Self.alice))
        #expect(guest.winner == Self.alice)
        #expect(guest.winningPlacements == winnersBoard)
        #expect(guest.poolIsExhausted == false)
        #expect(guest.hasPendingDraw == false)
        #expect(Terminal.snapshot(guest) == settled)
        #expect(await wire.count == 0)

        // And the board stays shut to this device too.
        #expect(guest.draw() == false)
        #expect(guest.swap(tiles[1]) == false)
        #expect(guest.claimWin() == false)
        #expect(guest.resign() == false)
        #expect(throws: BoardActionError.drawPending) {
            try guest.place(tileID: tiles[1].id, at: Coord(row: 0, col: 1))
        }
        #expect(Terminal.snapshot(guest) == settled)
        #expect(await wire.count == 0)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    @Test("A countdown tick parked across the end of the match cannot put it back into play")
    func aParkedTickCannotReopenASettledMatch() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock, countdownSeconds: 2)
        try await Terminal.waitUntil("the first tick to be asked for") { clock.parkedCount == 1 }
        #expect(guest.state.status == .countdown(secondsRemaining: 2))

        wire.deliver(.resign(player: Self.alice))
        try await Terminal.waitUntil("the resignation to land") { guest.isMatchOver }
        #expect(guest.state.status == .finished(winner: Self.bob))

        // The tick was asked for before the match ended and is still parked. An
        // injected clock need not observe cancellation, so handing it out is
        // exactly the hazard: one more tick would set `.playing` on a match that
        // already has a winner.
        clock.release(.seconds(1))
        try await Terminal.settle()
        #expect(guest.state.status == .finished(winner: Self.bob))
        #expect(guest.winner == Self.bob)
        #expect(guest.isMatchOver)

        clock.releaseAll()
        try await Terminal.settle()
        #expect(guest.state.status == .finished(winner: Self.bob))
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - Criterion 4: the deadline passes during the countdown

    /// The criteria suite lets the deadline pass on a match already in play.
    /// This one drops during the countdown, where a tick is parked on the clock
    /// across the end of the match and `status` is the thing most likely to move.
    @Test("A deadline passing during the countdown ends the match without naming anyone")
    func theDeadlinePassingDuringTheCountdownNamesNobody() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock, countdownSeconds: 3)
        try await Terminal.waitUntil("the first tick to be asked for") { clock.parkedCount == 1 }

        wire.drop(Self.alice)
        try await Terminal.waitUntil("the session to freeze") { guest.peerPresence != .present }
        try await Terminal.waitUntil("the window to ask for its time") { clock.parkedCount == 2 }

        clock.release(.seconds(MatchSession.reconnectGraceSeconds))
        try await Terminal.waitUntil("the deadline to pass") { guest.peerPresence == .gone }

        // Over, and nobody is named anywhere: not in `winner`, not in `status`,
        // not in the winning board.
        #expect(guest.isMatchOver)
        #expect(guest.winner == nil)
        #expect(guest.winningPlacements == nil)
        #expect(guest.state.status == .countdown(secondsRemaining: 3))

        // The tick parked from before the drop, handed out onto a match that has
        // ended.
        clock.release(.seconds(1))
        try await Terminal.settle()
        #expect(guest.state.status == .countdown(secondsRemaining: 3))
        #expect(guest.winner == nil)

        // Nothing arriving afterwards names one either, and a peer that comes
        // back cannot restart a match that is already over.
        wire.deliver(.win(player: Self.alice, placements: [Placement(tile: Tile(letter: "Z"), coord: Coord(row: 1, col: 1))]))
        wire.deliver(.resign(player: Self.alice))
        wire.deliver(.win(player: Self.bob, placements: []))
        wire.restore(Self.alice)
        try await Terminal.settle()

        #expect(guest.peerPresence == .gone)
        #expect(guest.isMatchOver)
        #expect(guest.winner == nil)
        #expect(guest.winningPlacements == nil)
        #expect(guest.state.status == .countdown(secondsRemaining: 3))
        #expect(guest.claimWin() == false)
        #expect(guest.resign() == false)
        #expect(await wire.count == 0)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - Item 4 regression

    /// `.poolExhausted` is a latch, not an end state, and the freeze is a
    /// different state again. Conflating the two would end the match on an empty
    /// pool and regress the previous item's criterion.
    @Test("An exhausted pool still is not an end state, across a freeze and a return")
    func theExhaustionLatchSurvivesAFreeze() async throws {
        let clock = Terminal.HandCrankedClock()
        let (guest, wire) = try await Terminal.playingGuest(clock: clock)

        wire.deliver(.poolExhausted)
        try await Terminal.waitUntil("the latch to close") { guest.poolIsExhausted }
        #expect(guest.isMatchOver == false)
        #expect(guest.winner == nil)
        #expect(guest.state.status == .playing)
        #expect(guest.peerPresence == .present)

        wire.drop(Self.alice)
        try await Terminal.waitUntil("the session to freeze") { guest.peerPresence != .present }
        #expect(guest.isMatchOver == false)
        wire.restore(Self.alice)
        try await Terminal.waitUntil("the peer to return") { guest.peerPresence == .present }

        #expect(guest.poolIsExhausted)
        #expect(guest.isMatchOver == false)
        #expect(guest.winner == nil)
        #expect(guest.state.status == .playing)

        // A grant reordered behind the exhaustion notice is still applied: the
        // latch is not a gate on the rack.
        let late = Tile(letter: "Q")
        wire.deliver(.grant(player: Self.bob, tiles: [late]))
        try await Terminal.waitUntil("the reordered grant to land") { guest.hasPendingDraw }
        #expect(guest.draw())
        #expect(guest.state.hand.map(\.id) == [late.id])
        try guest.place(tileID: late.id, at: Coord(row: 0, col: 0))
        #expect(guest.state.board.tile(at: Coord(row: 0, col: 0))?.id == late.id)
        #expect(guest.poolIsExhausted)
        #expect(guest.isMatchOver == false)

        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

    // MARK: - Source guardrails

    /// Every value the match sources handle came off the wire. A trap on any of
    /// those paths turns a modified peer's message into a crash, and a crash is
    /// the one failure a state machine cannot recover from.
    @Test("No match source traps on a value that came off the wire")
    func noMatchSourceTraps() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Cases
            .deletingLastPathComponent()   // MatchTests
            .appendingPathComponent("MatchSrc")
            .resolvingSymlinksInPath()
        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        // A scan that finds nothing because it looked nowhere proves nothing.
        #expect(files.count >= 5, "expected the match sources at \(sources.path)")
        #expect(files.contains { $0.lastPathComponent == "MatchSession.swift" })

        // `)!` and `]!` cannot be anything but a force unwrap; `foo!.` cannot
        // either. `!=` and a leading `!` are untouched by all three.
        let traps = ["try!", "fatalError(", "preconditionFailure(", "as!", ")!", "]!"]
        let unwrapAfterName = try NSRegularExpression(pattern: "[A-Za-z0-9_]!\\.")

        var violations: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (offset, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("*") else { continue }
                let where_ = "\(file.lastPathComponent):\(offset + 1)"
                for trap in traps where code.contains(trap) {
                    violations.append("\(where_) \(trap)")
                }
                let range = NSRange(code.startIndex..., in: code)
                if unwrapAfterName.firstMatch(in: code, range: range) != nil {
                    violations.append("\(where_) force unwrap")
                }
            }
        }
        #expect(violations.isEmpty, "a match source traps on peer input:\n\(violations.joined(separator: "\n"))")

        // The state machine presents no UI, so it must not be able to reach for
        // one — and one of these two frameworks cannot even build on a test host.
        let session = try String(
            contentsOf: sources.appendingPathComponent("MatchSession.swift"),
            encoding: .utf8
        )
        for framework in ["SwiftUI", "UIKit", "AppKit"] {
            let imports = session.components(separatedBy: "\n").contains { line in
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { return false }
                guard code.hasPrefix("import ") || code.contains(" import ") else { return false }
                return code.contains(framework)
            }
            #expect(!imports, "MatchSession.swift imports \(framework)")
        }
    }

    // PROBE
    @Test("Nothing enqueued before the match ended reaches the pool or the wire after it")
    func probeFinishedBlocksEnqueuedWork() async throws {
        let clock = Terminal.HandCrankedClock()
        let (host, wire) = try await Self.playingHost(clock: clock)
        await wire.closeGate()
        #expect(host.draw())
        #expect(host.draw())
        try await Terminal.waitUntil("the first submission to reach the pool") {
            await wire.parkedCount == 1
        }
        wire.deliver(.resign(player: Self.bob))
        try await Terminal.waitUntil("the match to end") { host.isMatchOver }
        #expect(host.winner == Self.alice)
        await wire.releaseAll()
        try await Terminal.settle()
        #expect(await wire.count == 2)
        #expect(host.state.hand.count == 1)
        clock.releaseAll()
        try await Terminal.waitUntil("the clock to be idle") { clock.parkedCount == 0 }
    }

}
