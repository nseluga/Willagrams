import Foundation
import Testing
@testable import Match
import WillagramsRules

@Suite("MatchCodec")
struct MatchCodecTests {

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
            .win(player: player, placements: [Placement(tile: tiles[0], coord: Coord(row: 0, col: 0))]),
            .resign(player: player),
            .rejected(reason: .poolEmpty),
            .rejected(reason: .notEnoughTilesToSwap),
            .rejected(reason: .notYourTurn),
            .rejected(reason: .unknownPlayer),
        ]
    }

    /// `Tests/MatchTests/Cases/` is 3 levels below the worktree root.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var goldenFixtureURL: URL {
        repoRoot.appendingPathComponent("Tests/WillagramsRulesTests/Fixtures/wire-v1.json")
    }

    @Test("Every case round-trips through the codec unchanged")
    func everyCaseRoundTrips() throws {
        for message in Self.everyCase {
            let data = try MatchCodec.encode(message)
            let decoded = try MatchCodec.decode(data)
            #expect(decoded == message, "\(message) did not survive the codec round trip")
        }
    }

    @Test("Every element of the golden fixture decodes through the codec")
    func goldenFixtureDecodes() throws {
        let json = try Data(contentsOf: Self.goldenFixtureURL)
        let elements = try #require(try JSONSerialization.jsonObject(with: json) as? [Any])
        #expect(elements.count == 12)

        for element in elements {
            let elementData = try JSONSerialization.data(withJSONObject: element)
            #expect(throws: Never.self) {
                try MatchCodec.decode(elementData)
            }
        }
    }

    @Test("A start with a foreign version is refused, not decoded")
    func foreignVersionIsRefused() throws {
        let foreign = MatchMessage.start(version: WireFormat.current + 1, seed: 1, startingHandSize: 21, countdownSeconds: 3)
        let data = try MatchCodec.encode(foreign)

        #expect {
            try MatchCodec.decode(data)
        } throws: { error in
            (error as? MatchCodecError) == .unsupportedVersion(received: WireFormat.current + 1, expected: WireFormat.current)
        }
    }

    @Test("A start at the current version is accepted")
    func currentVersionIsAccepted() throws {
        let data = try MatchCodec.encode(
            .start(version: WireFormat.current, seed: 1, startingHandSize: 21, countdownSeconds: 3)
        )
        let decoded = try MatchCodec.decode(data)
        guard case .start = decoded else {
            Issue.record("expected .start, got \(decoded)")
            return
        }
    }

    @Test("Truncated data fails to decode rather than trapping")
    func truncatedDataFailsToDecode() throws {
        let data = try MatchCodec.encode(.grant(player: Self.player, tiles: [Tile(letter: "A")]))
        let truncated = data.prefix(data.count / 2)

        #expect {
            try MatchCodec.decode(truncated)
        } throws: { error in
            guard case .malformedPayload = error as? MatchCodecError else { return false }
            return true
        }
    }

    @Test("Structurally invalid data fails to decode rather than trapping")
    func garbageDataFailsToDecode() {
        let garbage = Data([0xFF, 0x00, 0xDE, 0xAD, 0xBE, 0xEF])

        #expect {
            try MatchCodec.decode(garbage)
        } throws: { error in
            guard case .malformedPayload = error as? MatchCodecError else { return false }
            return true
        }
    }
}
