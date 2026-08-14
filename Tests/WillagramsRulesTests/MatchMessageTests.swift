import Foundation
import Testing
@testable import WillagramsRules

@Suite("Match wire contract")
struct MatchMessageTests {

    static let player = PlayerID(rawValue: "G:1234567890")

    static var everyCase: [MatchMessage] {
        let tiles = [Tile(letter: "A"), Tile(letter: "B"), Tile(letter: "C")]
        return [
            .start(version: WireFormat.current, seed: 0xDEAD_BEEF, startingHandSize: 21, countdownSeconds: 3),
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
    @Test("Every v1 case still decodes from the checked-in golden payload")
    func goldenPayloadStillDecodes() throws {
        let url = try #require(Bundle.module.url(forResource: "wire-v1", withExtension: "json"))
        let decoded = try JSONDecoder().decode([MatchMessage].self, from: Data(contentsOf: url))

        #expect(decoded.count == 12, "the golden file must cover every case")

        guard case let .start(version, _, handSize, countdown) = decoded[0] else {
            Issue.record("first golden message should be .start, got \(decoded[0])")
            return
        }
        #expect(version == WireFormat.current, "bump WireFormat.current and add wire-v\(version + 1).json")
        #expect(handSize == 21)
        #expect(countdown == 3)

        guard case let .win(_, placements) = decoded[6] else {
            Issue.record("seventh golden message should be .win, got \(decoded[6])")
            return
        }
        #expect(placements.map(\.tile.letter) == ["H", "I"], "a win must carry letters, not just ids")
        #expect(placements[1].coord == Coord(row: 0, col: 1))
    }

    @Test("A full 144-tile win message fits GameKit's 16KB reliable-send limit")
    func winMessageFitsPayloadLimit() throws {
        let message = MatchMessage.win(player: Self.player, placements: Self.placements(144))

        let size = try JSONEncoder().encode(message).count
        #expect(size < 16_384, "a maximal win payload is \(size) bytes, over GameKit's 16KB ceiling")
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
}
