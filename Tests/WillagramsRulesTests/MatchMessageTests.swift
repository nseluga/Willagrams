import Foundation
import Testing
@testable import WillagramsRules

@Suite("Match wire contract")
struct MatchMessageTests {

    static let player = PlayerID(rawValue: "G:1234567890")
    static let peer = PlayerID(rawValue: "G:9876543210")
    static let roster = [player, peer]

    static var everyCase: [MatchMessage] {
        let tiles = [Tile(letter: "A"), Tile(letter: "B"), Tile(letter: "C")]
        return [
            .start(version: WireFormat.current, seed: 0xDEAD_BEEF, startingHandSize: 21, countdownSeconds: 3, options: .standard, roster: roster),
            .drawRequest(player: player),
            .grant(player: player, tiles: tiles),
            .swapRequest(player: player, returning: tiles[0]),
            .swapGrant(player: player, tiles: tiles, returned: tiles[0]),
            .poolExhausted,
            .win(player: player, placements: Self.placements(21)),
            .resign(player: player),
            .rejected(reason: .poolEmpty),
            .rejected(reason: .notEnoughTilesToSwap),
            .rejected(reason: .notYourTurn),
            .rejected(reason: .unknownPlayer),
        ]
    }

    static func placements(_ n: Int) -> [Placement] {
        (0..<n).map {
            Placement(tile: Tile(letter: "A"), coord: Coord(row: $0 / 12, col: $0 % 12))
        }
    }

    @Test("Every case round-trips through JSON unchanged")
    func everyCaseRoundTrips() throws {
        for message in Self.everyCase {
            let data = try JSONEncoder().encode(message)
            let decoded = try JSONDecoder().decode(MatchMessage.self, from: data)
            #expect(decoded == message, "\(message) did not survive the round trip")
        }
    }

    /// The round trip above only proves this build agrees with itself. This one
    /// decodes bytes written by hand and checked in, so renaming a case or an
    /// associated value fails here instead of in a shipped match.
    @Test("Every v3 case still decodes from the checked-in golden payload")
    func goldenPayloadStillDecodes() throws {
        let url = try #require(Bundle.module.url(forResource: "wire-v3", withExtension: "json"))
        let decoded = try JSONDecoder().decode([MatchMessage].self, from: Data(contentsOf: url))

        #expect(decoded.count == 13, "the golden file must cover every case")

        guard case let .start(version, _, handSize, countdown, options, roster) = decoded[0] else {
            Issue.record("first golden message should be .start, got \(decoded[0])")
            return
        }
        #expect(version == WireFormat.current, "bump WireFormat.current and add wire-v\(version + 1).json")
        #expect(handSize == 21)
        #expect(countdown == 3)
        // The roster is the only place the player set appears, so a rename or a
        // reordering here breaks the host election on every device at once.
        #expect(roster == Self.roster)
        // The options ride the start, so a rename inside `MatchOptions` breaks
        // here rather than in a shipped match.
        #expect(options == .standard)

        guard case let .win(_, placements) = decoded[6] else {
            Issue.record("seventh golden message should be .win, got \(decoded[6])")
            return
        }
        #expect(placements.map(\.tile.letter) == ["H", "I"], "a win must carry letters, not just ids")
        #expect(placements[1].coord == Coord(row: 0, col: 1))
    }

    /// 16KB was GameKit's reliable-send ceiling. Game Center is gone, but the
    /// number stays as a sane transport budget: a realtime channel frame that
    /// large is already the wrong shape, whoever is carrying it.
    @Test("A full 144-tile win message stays inside the 16KB transport budget")
    func winMessageFitsPayloadLimit() throws {
        let message = MatchMessage.win(player: Self.player, placements: Self.placements(144))

        let size = try JSONEncoder().encode(message).count
        #expect(size < 16_384, "a maximal win payload is \(size) bytes, over the 16KB budget")
    }

    @Test("A truncated payload fails to decode rather than decoding partially")
    func truncatedPayloadFailsLoudly() throws {
        let data = try JSONEncoder().encode(MatchMessage.grant(player: Self.player, tiles: [Tile(letter: "A")]))
        let truncated = data.prefix(data.count / 2)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MatchMessage.self, from: truncated)
        }
    }

    /// A build that receives a case it has never heard of must fail to decode
    /// rather than guess. The symptom is a dropped message, so whoever handles
    /// receives has to surface it — see the version check in `.start`.
    @Test("An unknown case is rejected, not silently absorbed")
    func unknownCaseIsRejected() {
        let payload = Data(#"{"tauntOpponent":{"player":{"rawValue":"G:1"}}}"#.utf8)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MatchMessage.self, from: payload)
        }
    }

    @Test("A board round-trips through placements in a stable order")
    func placementListIsStable() throws {
        var board = Board()
        try board.place(Tile(letter: "C"), at: Coord(row: 1, col: 0))
        try board.place(Tile(letter: "A"), at: Coord(row: 0, col: 0))
        try board.place(Tile(letter: "B"), at: Coord(row: 0, col: 1))

        #expect(board.placementList.map(\.tile.letter) == ["A", "B", "C"])
        #expect(board.placementList == board.placementList, "order must not vary between reads")
    }

    // MARK: - validatedStart

    /// Every field in a `start` crossed a network. These are the ones a
    /// well-behaved host would never send, and each is refused for a reason a
    /// silent acceptance would hide.

    static func start(
        version: Int = WireFormat.current,
        handSize: Int = 21,
        countdown: Int = 3,
        roster: [PlayerID]
    ) -> MatchMessage {
        .start(
            version: version,
            seed: 1,
            startingHandSize: handSize,
            countdownSeconds: countdown,
            options: .standard,
            roster: roster
        )
    }

    @Test("A well-formed start validates, and names the lowest id as host")
    func validStartIsAccepted() throws {
        let validated = try #require(
            Self.start(roster: Self.roster).validatedStart(for: Self.player)
        )
        #expect(validated.roster == Self.roster)
        #expect(validated.host == Self.player, "host is roster[0], the lowest rawValue")
        #expect(validated.startingHandSize == 21)
    }

    @Test("Both ends elect the same host from the same roster")
    func hostElectionAgrees() throws {
        let mine = try #require(Self.start(roster: Self.roster).validatedStart(for: Self.player))
        let theirs = try #require(Self.start(roster: Self.roster).validatedStart(for: Self.peer))
        #expect(mine.host == theirs.host)
    }

    @Test("An unsorted roster is refused — the two ends would elect different hosts")
    func unsortedRosterIsRefused() {
        let reversed = [Self.peer, Self.player]
        #expect(Self.start(roster: reversed).validatedStart(for: Self.player) == nil)
    }

    @Test("A roster holding the same player twice is refused")
    func duplicateInRosterIsRefused() {
        #expect(Self.start(roster: [Self.player, Self.player]).validatedStart(for: Self.player) == nil)
    }

    @Test("A roster of one is refused — one player has nobody to race")
    func rosterOfOneIsRefused() {
        #expect(Self.start(roster: [Self.player]).validatedStart(for: Self.player) == nil)
    }

    @Test("A roster of seven is refused")
    func rosterOfSevenIsRefused() {
        let seven = (0..<7).map { PlayerID(rawValue: "P:\($0)") }
        #expect(Self.start(roster: seven).validatedStart(for: seven[0]) == nil)
    }

    @Test("A start this device is not named in is refused")
    func rosterWithoutLocalIsRefused() {
        let strangers = [PlayerID(rawValue: "P:1"), PlayerID(rawValue: "P:2")]
        #expect(Self.start(roster: strangers).validatedStart(for: Self.player) == nil)
    }

    @Test("An opening deal the pool cannot cover is refused")
    func oversizedDealIsRefused() {
        // Six players at 21 tiles is 126 of 144 — legal, and the tightest
        // shipping case. Seven would be 147, but seven is refused for its size
        // first, so the capacity rule is exercised at six with a larger hand.
        let six = (0..<6).map { PlayerID(rawValue: "P:\($0)") }
        #expect(Self.start(handSize: 21, roster: six).validatedStart(for: six[0]) != nil)
        #expect(Self.start(handSize: 25, roster: six).validatedStart(for: six[0]) == nil,
                "25 x 6 is 150 tiles from a 144-tile pool")
    }

    @Test("A start from a build speaking another wire version is refused")
    func wrongVersionIsRefused() {
        #expect(Self.start(version: 2, roster: Self.roster).validatedStart(for: Self.player) == nil)
    }

    /// Zero is legal on both: a match may open with no opening deal, and a
    /// lobby that is already agreed starts with no countdown at all. Negative
    /// is not a setting, it is a modified peer.
    @Test("A negative hand size or countdown is refused, zero is not")
    func degenerateStartIsRefused() {
        #expect(Self.start(handSize: -1, roster: Self.roster).validatedStart(for: Self.player) == nil)
        #expect(Self.start(countdown: -1, roster: Self.roster).validatedStart(for: Self.player) == nil)
        #expect(Self.start(handSize: 0, roster: Self.roster).validatedStart(for: Self.player) != nil)
        #expect(Self.start(countdown: 0, roster: Self.roster).validatedStart(for: Self.player) != nil)
    }

    @Test("Anything that is not a start validates to nil")
    func nonStartValidatesToNil() {
        #expect(MatchMessage.poolExhausted.validatedStart(for: Self.player) == nil)
    }
}
