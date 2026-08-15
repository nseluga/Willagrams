import Foundation
import Testing
import WillagramsRules
@testable import Match

/// Ordering coverage for the session: what reaches the wire, in what order, and
/// what happens when the wire hands messages back in the wrong one.
///
/// `HostPool.handle(_:)` suspends while it sends and carries a precondition that
/// it is called from one place at a time. Two concurrent callers interleave on
/// the wire, and a later request's answer can overtake an earlier one. Nothing
/// in the pool fails when that happens — the only observable is the order the
/// messages land in.
///
/// `FakeTransport.send` is a single actor hop with no real suspension, so a
/// green run against it proves nothing about this hazard. The transport below
/// suspends for tens of milliseconds on every send, and its latency varies the
/// way a real link's does: serialised that changes nothing, because each send
/// finishes before the next begins, but overlapping it puts a later send on the
/// wire first, which is exactly the inversion being hunted.
@MainActor
@Suite("Match session ordering")
struct MatchSessionOrderingTests {

    // MARK: - Fixtures

    struct EveryWordIsReal: WordList {
        func contains(_ word: String) -> Bool { true }
    }

    struct WaitExpired: Error, CustomStringConvertible {
        let label: String
        var description: String { "timed out waiting for \(label)" }
    }

    /// A transport that records the order messages actually reach the wire.
    ///
    /// A message is recorded *after* its suspension, which is the moment it
    /// lands. Two sends running at once therefore record in completion order,
    /// not in call order.
    actor OrderRecordingTransport: MatchTransport {

        nonisolated let localPlayerID: PlayerID
        nonisolated let inboundMessages: AsyncStream<MatchMessage>
        nonisolated let peerConnectionStates = AsyncStream<PeerConnectionState> { $0.finish() }

        private nonisolated let inbound: AsyncStream<MatchMessage>.Continuation

        /// What landed, in landing order.
        private(set) var wire: [MatchMessage] = []
        /// The most sends ever suspended at the same time. One, if the session
        /// serialises; more if two callers reached the pool together.
        private(set) var mostInFlight = 0

        private var inFlight = 0
        private var started = 0

        init(localPlayerID: PlayerID) {
            let stream = AsyncStream.makeStream(of: MatchMessage.self, bufferingPolicy: .unbounded)
            self.localPlayerID = localPlayerID
            self.inboundMessages = stream.stream
            self.inbound = stream.continuation
        }

        /// Puts a message on this endpoint's inbound stream, as the peer would.
        nonisolated func deliver(_ message: MatchMessage) { inbound.yield(message) }

        func send(_ message: MatchMessage, delivery: MatchDelivery) async throws {
            inFlight += 1
            mostInFlight = max(mostInFlight, inFlight)
            started += 1
            // Between 20ms and 60ms, shrinking as the match goes on.
            try? await Task.sleep(for: .milliseconds(max(20, 60 - started * 2)))
            wire.append(message)
            inFlight -= 1
        }

        nonisolated func leave() { inbound.finish() }

        /// The tiles handed back by swap answers, in the order those answers
        /// reached the wire. Each request carried a distinct tile, so this is a
        /// direct read of which request was answered when.
        func swapAnswerOrder() -> [UUID] {
            wire.compactMap { message in
                guard case let .swapGrant(_, _, returned) = message else { return nil }
                return returned.id
            }
        }

        func grantCount() -> Int {
            wire.filter { if case .grant = $0 { return true } else { return false } }.count
        }
    }

    static func waitUntil(
        _ label: String,
        within deadline: Duration = .seconds(10),
        _ condition: () async -> Bool
    ) async throws {
        let limit = ContinuousClock.now + deadline
        while await !condition() {
            guard ContinuousClock.now < limit else { throw WaitExpired(label: label) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Pairs out of order between what landed and what was asked for.
    static func inversions(in landed: [UUID], against requested: [UUID]) -> Int {
        let rank = Dictionary(uniqueKeysWithValues: requested.enumerated().map { ($0.element, $0.offset) })
        let ranks = landed.compactMap { rank[$0] }
        var count = 0
        for i in ranks.indices {
            for j in ranks.indices where j > i && ranks[i] > ranks[j] { count += 1 }
        }
        return count
    }

    // MARK: - Wire order

    @Test("Answers reach the wire in request order when two callers submit at once")
    func answersReachTheWireInRequestOrder() async throws {
        let alice = PlayerID(rawValue: "alice")
        let bob = PlayerID(rawValue: "bob")
        // This device must be the one holding the pool, or nothing is submitted.
        #expect(HostPool.host(of: alice, bob) == alice)

        let wire = OrderRecordingTransport(localPlayerID: alice)
        let host = MatchSession(transport: wire, peerPlayerID: bob, dictionary: EveryWordIsReal())
        host.startMatch(seed: 11, startingHandSize: 21, countdownSeconds: 0)
        #expect(host.state.status == .playing)

        // Each swap request carries a tile no other request carries, so the
        // answer on the wire names the request that produced it. Draw answers
        // are indistinguishable from each other, so they ride along as traffic.
        let tagged = (0..<12).map { _ in Tile(letter: "S") }
        for (index, tile) in tagged.enumerated() {
            wire.deliver(.swapRequest(player: bob, returning: tile))
            wire.deliver(.drawRequest(player: bob))
            // The second call site: this device's own presses, racing the pump.
            if index.isMultiple(of: 3) { host.draw() }
            await Task.yield()
        }

        let requested = tagged.map(\.id)
        try await Self.waitUntil("every swap to be answered") {
            await wire.swapAnswerOrder().count == requested.count
        }

        let landed = await wire.swapAnswerOrder()
        #expect(landed == requested)
        #expect(Self.inversions(in: landed, against: requested) == 0)

        // The mechanism behind the order: one submission in flight at a time.
        let mostInFlight = await wire.mostInFlight
        #expect(mostInFlight == 1)

        // 12 peer draws plus 4 of this device's own, each answered to the peer.
        try await Self.waitUntil("every draw to be answered") {
            await wire.grantCount() == 16
        }
    }

    @Test("The pool has exactly one caller in the whole app source tree")
    func thePoolHasOneCaller() throws {
        // `MatchSrc` is the committed symlink to `Willagrams/Match`; its parent
        // is every app source. `HostPool.handle` is public, so a caller added in
        // `Willagrams/App` or in a subdirectory that does not exist yet would
        // reinstate the wire inversion — a scan of one flat directory would
        // stay green through it, which is the one way this guard can lie.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Cases
            .deletingLastPathComponent()   // MatchTests
            .appendingPathComponent("MatchSrc")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()   // Willagrams — all of it, recursively
        let walker = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil),
            "expected the app sources at \(sources.path)"
        )
        let files = walker
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        // A scan that finds nothing because it looked nowhere proves nothing.
        // The match directory alone holds five, and the tree holds more.
        #expect(files.count > 5, "expected the app sources at \(sources.path)")
        #expect(files.contains { $0.lastPathComponent == "MatchSession.swift" })
        #expect(files.contains { $0.lastPathComponent == "WillagramsApp.swift" })
        // Proof the walk descended: that last file is a directory deeper than
        // the one the old scan looked in.
        #expect(files.contains { $0.deletingLastPathComponent().lastPathComponent == "App" })

        var callSites: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (offset, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), code.contains(".handle(") else { continue }
                callSites.append("\(file.lastPathComponent):\(offset + 1)")
            }
        }
        #expect(
            callSites.count == 1,
            "the pool must have exactly one caller, or answers interleave on the wire; found \(callSites)"
        )
    }

    // MARK: - Arrival order

    @Test("An exhausted pool arriving ahead of a grant leaves the grant applied and the match alive")
    func exhaustionAheadOfAGrantIsNotTerminal() async throws {
        let alice = PlayerID(rawValue: "alice")
        let bob = PlayerID(rawValue: "bob")
        // This device is not the host, so nothing local answers anything.
        let wire = OrderRecordingTransport(localPlayerID: bob)
        let guest = MatchSession(transport: wire, peerPlayerID: alice, dictionary: EveryWordIsReal())

        wire.deliver(.start(version: WireFormat.current, seed: 1, startingHandSize: 21, countdownSeconds: 0))
        try await Self.waitUntil("the guest to be playing") { guest.state.status == .playing }

        // Reordered in flight: the exhaustion notice overtook the grant.
        let late = Tile(letter: "Q")
        wire.deliver(.poolExhausted)
        wire.deliver(.grant(player: bob, tiles: [late]))
        try await Self.waitUntil("the reordered grant to land") { guest.hasPendingDraw }

        #expect(guest.poolIsExhausted)
        #expect(guest.state.status == .playing)
        #expect(guest.pendingDrawTiles.map(\.id) == [late.id])

        // Still a live match: the tile can be taken and played.
        #expect(guest.draw())
        #expect(guest.state.hand.map(\.id) == [late.id])
        try guest.place(tileID: late.id, at: Coord(row: 0, col: 0))
        #expect(guest.state.board.tile(at: Coord(row: 0, col: 0))?.id == late.id)
        // The latch does not lift.
        #expect(guest.poolIsExhausted)

        // Only a resignation or a win ends it.
        wire.deliver(.resign(player: alice))
        try await Self.waitUntil("the match to end") {
            guest.state.status == .finished(winner: bob)
        }
    }

    // MARK: - A device never receives its own sends

    @Test("This device applies its own start and its own tile without hearing them on the wire")
    func aDeviceNeverReceivesItsOwnSends() async throws {
        let alice = PlayerID(rawValue: "alice")
        let bob = PlayerID(rawValue: "bob")
        #expect(HostPool.host(of: alice, bob) == alice)

        let wire = OrderRecordingTransport(localPlayerID: alice)
        let host = MatchSession(transport: wire, peerPlayerID: bob, dictionary: EveryWordIsReal())

        // Nothing is ever delivered to this endpoint except the peer's traffic —
        // one draw request, below. The start is never heard back.
        host.startMatch(seed: 5, startingHandSize: 21, countdownSeconds: 0)
        #expect(host.state.status == .playing)

        host.draw()
        try await Self.waitUntil("this device to hold its own tile") {
            host.state.hand.count == 1
        }
        #expect(host.hasPendingDraw == false)

        // The peer's half of the traffic, and the only thing that ever arrives.
        wire.deliver(.drawRequest(player: bob))
        try await Self.waitUntil("this device to owe a tile") { host.hasPendingDraw }
        #expect(host.draw())

        #expect(host.state.hand.count == 2)
        #expect(Set(host.state.hand.map(\.id)).count == 2)
        #expect(host.state.status == .playing)
        #expect(host.pendingDrawTiles.isEmpty)

        let landed = await wire.wire
        #expect(landed.first == .start(version: WireFormat.current, seed: 5, startingHandSize: 21, countdownSeconds: 0))
        // Two rounds, two answers to the peer, none of them addressed here.
        let grantCount = await wire.grantCount()
        #expect(grantCount == 2)
        let addressedHere = landed.contains { message in
            if case let .grant(player, _) = message { return player == alice }
            return false
        }
        #expect(addressedHere == false)

        // And the tiles this device holds are its own: not one of them was ever
        // put on the wire. Counting the hand is not enough — a device that took
        // the peer's tile out of the pool's answer would still hold two, and both
        // devices would then be holding the same tile.
        let travelled = Set(landed.flatMap { message -> [UUID] in
            switch message {
            case let .grant(_, tiles), let .swapGrant(_, tiles, _): return tiles.map(\.id)
            default: return []
            }
        })
        #expect(travelled.count == 2)
        #expect(Set(host.state.hand.map(\.id)).isDisjoint(with: travelled))
    }

    // MARK: - Concurrency contract

    @Test("Everything crossing the transport boundary stays Sendable")
    func boundaryTypesStaySendable() {
        // A compile-time gate: an `any Error` stored anywhere in these types
        // blocks the synthesis and this stops building under strict concurrency.
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(BoardActionError.self)
        requireSendable(MatchMessage.self)
        requireSendable(GameState.self)
        requireSendable(MatchSession.self)
        requireSendable(MatchTransportError.self)
    }
}
