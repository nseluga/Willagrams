import Foundation
import Testing
@testable import Match
import WillagramsRules

/// Closes gaps in the engineer's coverage: exact-value fixture assertions,
/// the version gate driven only through the real `decode(_:)` entry point,
/// and confirmation that `MatchCodecError` is exhaustively switchable.
@Suite("MatchCodec golden fixture and version gate")
struct MatchCodecTrustBoundaryTests {

    /// Every element of `wire-v2.json`, hand-built from the literals in the
    /// spec — never re-encoded through this build's own encoder, since that
    /// would launder the golden bytes through the code under test.
    static var expectedFixtureMessages: [MatchMessage] {
        let player = MatchCodecTests.player

        let tileA = Tile(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, letter: "A")
        let tileB = Tile(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, letter: "B")
        let tileQ = Tile(id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!, letter: "Q")
        let tileE = Tile(id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!, letter: "E")
        let tileT = Tile(id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!, letter: "T")
        let tileO = Tile(id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!, letter: "O")
        let tileH = Tile(id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!, letter: "H")
        let tileI = Tile(id: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!, letter: "I")

        return [
            .start(version: 2, seed: 3735928559, startingHandSize: 21, countdownSeconds: 3, options: .standard),
            .drawRequest(player: player),
            .grant(player: player, tiles: [tileA, tileB]),
            .swapRequest(player: player, returning: tileQ),
            .swapGrant(player: player, tiles: [tileE, tileT, tileO], returned: tileQ),
            .poolExhausted,
            .win(player: player, placements: [
                Placement(tile: tileH, coord: Coord(row: 0, col: 0)),
                Placement(tile: tileI, coord: Coord(row: 0, col: 1)),
            ]),
            .resign(player: player),
            .rejected(reason: .poolEmpty),
            .rejected(reason: .notEnoughTilesToSwap),
            .rejected(reason: .notYourTurn),
            .rejected(reason: .unknownPlayer),
            .rejected(reason: .swapDisabled),
        ]
    }

    @Test("Every element of the golden fixture decodes to the exact expected MatchMessage value")
    func goldenFixtureDecodesToExpectedValues() throws {
        let json = try Data(contentsOf: MatchCodecTests.goldenFixtureURL)
        let elements = try #require(try JSONSerialization.jsonObject(with: json) as? [Any])
        let expected = Self.expectedFixtureMessages
        #expect(elements.count == expected.count)

        for (element, expectedMessage) in zip(elements, expected) {
            let elementData = try JSONSerialization.data(withJSONObject: element)
            let decoded = try MatchCodec.decode(elementData)
            #expect(decoded == expectedMessage)
        }
    }

    @Test(
        "A start whose version differs from current is refused through the real decode entry point, with no MatchMessage returned",
        arguments: [0, -1, Int.max, WireFormat.current + 1, WireFormat.current + 1000]
    )
    func foreignVersionsAreRefused(version: Int) throws {
        let data = try MatchCodec.encode(
            .start(version: version, seed: 1, startingHandSize: 21, countdownSeconds: 3, options: .standard)
        )

        #expect {
            try MatchCodec.decode(data)
        } throws: { error in
            (error as? MatchCodecError) == .unsupportedVersion(received: version, expected: WireFormat.current)
        }
    }

    @Test("Non-start cases carry no version and still decode at any time")
    func nonStartCasesIgnoreTheVersionGate() throws {
        for message in MatchCodecTests.everyCase where !isStart(message) {
            let data = try MatchCodec.encode(message)
            let decoded = try MatchCodec.decode(data)
            #expect(decoded == message)
        }
    }

    private func isStart(_ message: MatchMessage) -> Bool {
        if case .start = message { return true }
        return false
    }

    @Test("MatchCodecError can be exhaustively switched over without a default case")
    func errorIsExhaustivelySwitchable() {
        func describe(_ error: MatchCodecError) -> String {
            switch error {
            case .unsupportedVersion: return "unsupportedVersion"
            case .malformedPayload: return "malformedPayload"
            }
        }

        #expect(describe(.unsupportedVersion(received: 2, expected: 1)) == "unsupportedVersion")
        #expect(describe(.malformedPayload(description: "not JSON")) == "malformedPayload")
    }

    /// The transport surfaces decode failures from an async stream and the
    /// session is observed on the main actor, so this error crosses an
    /// isolation boundary. Capturing it in a `Task` only compiles while
    /// `MatchCodecError` stays `Sendable` — that is the whole point of the test.
    @Test("A decode error crosses an isolation boundary")
    func errorCrossesIsolationBoundary() async {
        for error: MatchCodecError in [
            .unsupportedVersion(received: 2, expected: WireFormat.current),
            .malformedPayload(description: "truncated"),
        ] {
            #expect(await Task { error }.value == error)
        }
    }
}
