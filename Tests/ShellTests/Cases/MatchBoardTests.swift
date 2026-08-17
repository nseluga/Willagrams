import BoardKit
import CoreGraphics
import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell

/// One test per acceptance criterion for wiring the match to the board, each
/// driving the real session and the real layout — `draw()` is pressed, never
/// reached past, and no coordinate is chosen here except to move a tile the way
/// a player's finger would.
@MainActor
@Suite("Match board wiring")
struct MatchBoardTests {

    /// Accepts every word, so the letters the pool deals never decide whether a
    /// board is complete.
    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal

    /// A real landscape frame. Never used to place anything — it is handed to
    /// `BoardLayout` through `MatchBoard`, which is the whole point.
    static let viewport = CGRect(x: 0, y: 0, width: 1024, height: 768)

    static let setup = MatchSetup(
        seed: 20260817,
        startingHandSize: ShellModel.soloHandSize,
        countdownSeconds: ShellModel.soloCountdownSeconds
    )

    /// Every tile id the device holds anywhere, and a check that it holds none
    /// of them twice. The board is asserted to BE the session's board, which is
    /// the whole of "delivering to the board removes it from wherever it was
    /// held" — there is no third copy to count.
    static func custody(
        _ board: MatchBoard, _ session: MatchSession, _ label: String
    ) -> Set<UUID> {
        #expect(board.board == session.state.board, "\(label): the two boards diverged")
        let hand = Set(session.state.hand.map(\.id))
        let pending = Set(session.pendingDrawTiles.map(\.id))
        let placed = Set(board.board.placementList.map(\.tile.id))
        #expect(hand.isDisjoint(with: pending), "\(label): a tile is in hand and pending")
        #expect(hand.isDisjoint(with: placed), "\(label): a tile is in hand and on the board")
        #expect(pending.isDisjoint(with: placed), "\(label): a tile is pending and on the board")
        #expect(
            hand.count + pending.count + placed.count == hand.union(pending).union(placed).count,
            "\(label): a tile id was counted twice"
        )
        return hand.union(pending).union(placed)
    }

    /// A started solo match with the board wired to it before the match opened,
    /// so the deal is delivered by the observation path and not by a call the
    /// test made at the right moment.
    static func wired() async throws -> (SoloMatch, MatchBoard) {
        let solo = SoloMatch(setup: setup, dictionary: EveryWordIsReal(), sleepFor: { _ in })
        let wiring = MatchBoard(session: solo.session, dictionary: EveryWordIsReal())
        wiring.viewport = viewport
        solo.start()
        try await SoloMatchTests.waitUntil("the opening on the board") {
            wiring.board.placementList.count == setup.startingHandSize
        }
        return (solo, wiring)
    }

    /// A guest session — it is not host, so every tile it holds arrives as a
    /// `.grant` off the wire, which is the only way a test can choose the
    /// letters and the only way to produce a tile held behind the Draw button.
    static func guest(
        handSize: Int, dictionary: some WordList
    ) async throws -> (host: FakeTransport, session: MatchSession) {
        let hostID = PlayerID(rawValue: "aaa")
        let guestID = PlayerID(rawValue: "zzz")
        #expect(HostPool.host(of: hostID, guestID) == hostID)
        let (hostWire, guestWire) = FakeTransport.pair(hostID, guestID)
        let session = MatchSession(
            transport: guestWire,
            peerPlayerID: hostID,
            dictionary: dictionary,
            sleepFor: { _ in }
        )
        try await hostWire.send(
            .start(
                version: WireFormat.current,
                seed: 7,
                startingHandSize: handSize,
                countdownSeconds: 0
            ),
            delivery: .reliable
        )
        try await SoloMatchTests.waitUntil("play to begin") { session.state.status == .playing }
        return (hostWire, session)
    }

    static func grant(_ tiles: [Tile], from host: FakeTransport) async throws {
        try await host.send(.grant(player: PlayerID(rawValue: "zzz"), tiles: tiles), delivery: .reliable)
    }

    // MARK: - Criterion 1

    @Test("Tiles dealt at countdown end reach the board, spaced, with none left in hand")
    func dealtTilesLandInASpacedOpening() async throws {
        let (solo, wiring) = try await Self.wired()

        #expect(wiring.board.placementList.count == Self.setup.startingHandSize)
        // The opening block: no tile touches another, so nothing the player did
        // not build can read as a word.
        for placement in wiring.board.placementList {
            for neighbor in placement.coord.neighbors {
                #expect(
                    wiring.board.tile(at: neighbor) == nil,
                    "two dealt tiles are adjacent at \(placement.coord)"
                )
            }
        }
        // On the board is the ONLY place they are.
        #expect(solo.session.state.hand.isEmpty)
        let held = Self.custody(wiring, solo.session, "after the deal")
        #expect(held.count == Self.setup.startingHandSize)
        #expect(held.isDisjoint(with: solo.peerTileIDs))

        solo.leave()
    }

    // MARK: - Criterion 2

    @Test("A mid-match draw lands inside the current viewport")
    func drawnTilesLandInTheVisibleRegion() async throws {
        let (solo, wiring) = try await Self.wired()
        let before = Set(wiring.board.placementList.map(\.coord))

        // The production entry point. Nothing here reaches past it.
        #expect(solo.session.draw())
        try await SoloMatchTests.waitUntil("the drawn tile on the board") {
            wiring.board.placementList.count == Self.setup.startingHandSize + 1
        }

        let arrived = wiring.board.placementList.filter { !before.contains($0.coord) }
        #expect(arrived.count == 1)
        let visible = Set(wiring.camera.visibleCoords(in: wiring.viewport))
        // The viewport the wiring was given, read back through the same camera
        // the delivery was handed — not a point count named here.
        #expect(visible.contains(arrived[0].coord), "the drawn tile landed off screen")
        #expect(solo.session.state.hand.isEmpty)
        #expect(Self.custody(wiring, solo.session, "after a draw").count
                == Self.setup.startingHandSize + 1)

        solo.leave()
    }

    // MARK: - Criterion 3

    @Test("Draw eligibility follows BoardModel as words are made and broken")
    func drawEligibilityFollowsTheBoardModel() async throws {
        let dictionary = EnableWordList(words: ["GO"])
        let (host, session) = try await Self.guest(handSize: 2, dictionary: dictionary)
        let wiring = MatchBoard(session: session, dictionary: dictionary)
        wiring.viewport = Self.viewport

        try await Self.grant([Tile(letter: "G"), Tile(letter: "O")], from: host)
        try await SoloMatchTests.waitUntil("the opening on the board") {
            wiring.board.placementList.count == 2
        }

        // Two loose letters: a spaced opening is two clusters, and two clusters
        // are not drawable.
        #expect(wiring.canDraw == false)
        #expect(wiring.canDraw == wiring.model.canDraw)

        // The player makes a word — a tile moved next to another, exactly what a
        // committed drag leaves behind on the two values the view binds to.
        let loose = try #require(wiring.board.placementList.first { $0.tile.letter == "O" })
        let home = loose.coord
        let joined = try #require(wiring.board.placementList.first { $0.tile.letter == "G" }).coord
        _ = wiring.board.remove(at: home)
        try wiring.board.place(loose.tile, at: Coord(row: joined.row, col: joined.col + 1))
        wiring.model.seed(wiring.board, against: dictionary)
        #expect(wiring.canDraw)
        #expect(wiring.canDraw == wiring.model.canDraw)

        // And breaks it again.
        _ = wiring.board.remove(at: Coord(row: joined.row, col: joined.col + 1))
        try wiring.board.place(loose.tile, at: home)
        wiring.model.seed(wiring.board, against: dictionary)
        #expect(wiring.canDraw == false)
        #expect(wiring.canDraw == wiring.model.canDraw)

        session.leave()
    }

    // MARK: - The interrupted path

    @Test("A delivery interrupted by a pending draw loses no tile and re-arms")
    func interruptedDeliveryLosesNoTileAndReArms() async throws {
        let dictionary = EveryWordIsReal()
        let (host, session) = try await Self.guest(handSize: 2, dictionary: dictionary)
        let wiring = MatchBoard(session: session, dictionary: dictionary)
        wiring.viewport = Self.viewport

        let opening = [Tile(letter: "G"), Tile(letter: "O")]
        try await Self.grant(opening, from: host)
        try await SoloMatchTests.waitUntil("the opening on the board") {
            wiring.board.placementList.count == 2
        }
        let dealt = Self.custody(wiring, session, "after the deal")

        // The opponent drew, so this device owes a press: the tile is held, the
        // board is frozen, and the session refuses every placement until the
        // player takes it. A delivery attempted here must do nothing at all.
        let owed = Tile(letter: "X")
        try await Self.grant([owed], from: host)
        try await SoloMatchTests.waitUntil("the obligation") { session.hasPendingDraw }
        wiring.sync()
        wiring.sync()
        #expect(wiring.board.placementList.count == 2, "a frozen board took a delivery")
        #expect(wiring.board.placementList.allSatisfy { $0.tile.id != owed.id })
        let interrupted = Self.custody(wiring, session, "while interrupted")
        #expect(interrupted == dealt.union([owed.id]), "a tile went missing under the interruption")

        // The press is the resuming path, and the wiring re-arms on it with no
        // second call from anywhere: the tile that was held is delivered.
        #expect(session.draw())
        try await SoloMatchTests.waitUntil("the held tile on the board") {
            wiring.board.placementList.count == 3
        }
        #expect(session.state.hand.isEmpty)
        #expect(session.hasPendingDraw == false)
        let resumed = Self.custody(wiring, session, "after resuming")
        #expect(resumed == dealt.union([owed.id]))

        session.leave()
    }

    @Test("A delivery the rules refuse publishes nothing and leaves the tile in hand")
    func refusedDeliveryPublishesNothing() async throws {
        let dictionary = EveryWordIsReal()
        let (host, session) = try await Self.guest(handSize: 1, dictionary: dictionary)
        let laid = MatchBoard(session: session, dictionary: dictionary)
        laid.viewport = Self.viewport

        try await Self.grant([Tile(letter: "G")], from: host)
        try await SoloMatchTests.waitUntil("the opening on the board") {
            laid.board.placementList.count == 1
        }

        // A second tile in hand, taken through the Draw button.
        try await Self.grant([Tile(letter: "O")], from: host)
        try await SoloMatchTests.waitUntil("the obligation") { session.hasPendingDraw }
        #expect(session.draw())
        #expect(session.state.hand.count == 1)

        // A second wiring over the same session opens onto an empty board, so
        // the cell it picks is one the session already holds and the rules
        // refuse the mirror. Nothing may be published from a refused delivery.
        let fresh = MatchBoard(session: session, dictionary: dictionary)
        fresh.viewport = Self.viewport
        #expect(fresh.board.placementList.isEmpty)
        #expect(session.state.hand.count == 1, "a refused delivery ate the tile")
        #expect(session.state.board.placementList.count == 1)

        session.leave()
    }
}
