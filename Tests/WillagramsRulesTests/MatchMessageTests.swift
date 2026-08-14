import Foundation
import Testing
@testable import WillagramsRules

@Suite("Match wire contract")
struct MatchMessageTests {

    static let player = PlayerID(rawValue: "G:1234567890")

    static var everyCase: [MatchMessage] {
        let tiles = [Tile(letter: "A"), Tile(letter: "B"), Tile(letter: "C")]
        return [
            .start(seed: 0xDEAD_BEEF, startingHandSize: 21, countdownSeconds: 3),
            .drawRequest(player: player),
            .grant(player: player, tiles: tiles),
            .swapRequest(player: player, returning: tiles[0]),
            .swapGrant(player: player, tiles: tiles, returned: tiles[0]),
            .poolExhausted,
            .win(player: player, placements: Self.placements(21), tiles: tiles),
            .resign(player: player),
            .rejected(reason: .poolEmpty),
            .rejected(reason: .notEnoughTilesToSwap),
            .rejected(reason: .notYourTurn),
            .rejected(reason: .unknownPlayer),
        ]
    }

    static func placements(_ n: Int) -> [Placement] {
        (0..<n).map { Placement(tileID: UUID(), coord: Coord(row: $0 / 12, col: $0 % 12)) }
    }

    @Test("Every case round-trips through JSON unchanged")
    func everyCaseRoundTrips() throws {
        for message in Self.everyCase {
            let data = try JSONEncoder().encode(message)
            let decoded = try JSONDecoder().decode(MatchMessage.self, from: data)
            #expect(decoded == message, "\(message) did not survive the round trip")
        }
    }

    @Test("A full 144-tile win message fits GameKit's 16KB reliable-send limit")
    func winMessageFitsPayloadLimit() throws {
        let message = MatchMessage.win(
            player: Self.player,
            placements: Self.placements(144),
            tiles: []
        )

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
}
