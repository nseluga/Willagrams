import Foundation
import Testing
import WillagramsRules
@testable import Online

/// The rows are the seam between the schema and the app. A fixture here is the
/// only thing that catches a column renamed on one side of it: `snake_case` on
/// the wire, `camelCase` in Swift, and nothing in between to notice a typo.
///
/// The JSON in this file is written by hand to match
/// `supabase/migrations/0001_init.sql`, not dumped from the types — a fixture
/// generated from the type it validates proves nothing.
@Suite("Backend row coding")
struct BackendRowCodingTests {

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try BackendCoding.decoder.decode(type, from: Data(json.utf8))
    }

    @Test("A profile row decodes every snake_case column onto its Swift name")
    func profileDecodes() throws {
        let profile = try Self.decode(Profile.self, """
        {
          "id": "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
          "display_name": "Nate",
          "friend_code": "AB12CD34",
          "created_at": "2026-08-18T12:00:00.123456+00:00",
          "matches_played": 7,
          "matches_won": 3,
          "tiles_placed": 412,
          "fastest_win_seconds": 96
        }
        """)

        #expect(profile.displayName == "Nate")
        #expect(profile.friendCode == "AB12CD34")
        #expect(profile.matchesPlayed == 7)
        #expect(profile.matchesWon == 3)
        #expect(profile.tilesPlaced == 412)
        #expect(profile.fastestWinSeconds == 96)
        #expect(profile.playerID.rawValue == profile.id.uuidString)
    }

    /// `fastest_win_seconds` is the one nullable column on the row, and it is
    /// null for every player who has not won yet — the common case, not an edge.
    @Test("A profile that has never won decodes with a nil fastest win")
    func profileWithoutAWinDecodes() throws {
        let profile = try Self.decode(Profile.self, """
        {
          "id": "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
          "display_name": "Nate",
          "friend_code": "AB12CD34",
          "created_at": "2026-08-18T12:00:00+00:00",
          "matches_played": 0,
          "matches_won": 0,
          "tiles_placed": 0,
          "fastest_win_seconds": null
        }
        """)
        #expect(profile.fastestWinSeconds == nil)
    }

    /// Postgres emits fractional seconds when the stored value has them and
    /// omits them when it does not. Both forms come off the same column, so
    /// both have to decode or half the rows fail at runtime.
    @Test("Timestamps decode with and without fractional seconds")
    func bothTimestampFormsDecode() throws {
        let withFraction = try Self.decode(Profile.self, """
        {"id":"1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed","display_name":"a","friend_code":"AB12CD34",
         "created_at":"2026-08-18T12:00:00.500+00:00","matches_played":0,"matches_won":0,
         "tiles_placed":0,"fastest_win_seconds":null}
        """)
        let without = try Self.decode(Profile.self, """
        {"id":"1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed","display_name":"a","friend_code":"AB12CD34",
         "created_at":"2026-08-18T12:00:00+00:00","matches_played":0,"matches_won":0,
         "tiles_placed":0,"fastest_win_seconds":null}
        """)
        #expect(withFraction.createdAt.timeIntervalSince(without.createdAt) == 0.5)
    }

    @Test("A round trip through the encoder comes back unchanged")
    func profileRoundTrips() throws {
        let original = try Self.decode(Profile.self, """
        {"id":"1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed","display_name":"Nate","friend_code":"AB12CD34",
         "created_at":"2026-08-18T12:00:00.123+00:00","matches_played":1,"matches_won":1,
         "tiles_placed":21,"fastest_win_seconds":96}
        """)
        let data = try BackendCoding.encoder.encode(original)
        // The encoded form is what a write sends back, so the column names have
        // to survive the trip out as well as in.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("display_name"))
        #expect(text.contains("fastest_win_seconds"))
        #expect(try BackendCoding.decoder.decode(Profile.self, from: data) == original)
    }

    @Test("A friendship row decodes, and names the other party from either side")
    func friendshipDecodes() throws {
        let friendship = try Self.decode(Friendship.self, """
        {
          "requester_id": "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
          "addressee_id": "2b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
          "status": "accepted",
          "created_at": "2026-08-18T12:00:00+00:00",
          "responded_at": "2026-08-18T12:05:00+00:00"
        }
        """)
        #expect(friendship.status == .accepted)
        #expect(friendship.other(than: friendship.requesterID) == friendship.addresseeID)
        #expect(friendship.other(than: friendship.addresseeID) == friendship.requesterID)
        #expect(friendship.other(than: UUID()) == nil, "a row that is not yours names nobody")
    }

    /// `responded_at` is null exactly while the status is `pending` — the
    /// schema enforces the pair, and this is the Swift side of the same rule.
    @Test("A pending friendship decodes with no responded_at")
    func pendingFriendshipDecodes() throws {
        let friendship = try Self.decode(Friendship.self, """
        {"requester_id":"1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
         "addressee_id":"2b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
         "status":"pending","created_at":"2026-08-18T12:00:00+00:00","responded_at":null}
        """)
        #expect(friendship.status == .pending)
        #expect(friendship.respondedAt == nil)
    }

    /// The seed is `bigint` and signed in Postgres, `UInt64` in the engine.
    /// `poolSeed` is the one conversion, and it has to survive the top of the
    /// range the schema allows.
    @Test("A match row decodes and its signed seed reaches the engine unchanged")
    func matchDecodes() throws {
        let match = try Self.decode(MatchRecord.self, """
        {
          "id": "3b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
          "host_id": "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
          "invite_code": "AB12CD",
          "wire_version": 3,
          "seed": 9223372036854775807,
          "options": {"minimumWordLength": 3, "swapEnabled": true, "dictionaryID": "standard", "dictionaryHash": "abc123"},
          "status": "lobby",
          "created_at": "2026-08-18T12:00:00+00:00",
          "started_at": null,
          "finished_at": null,
          "winner_id": null
        }
        """)
        #expect(match.inviteCode == "AB12CD")
        #expect(match.wireVersion == WireFormat.current)
        #expect(match.status == .lobby)
        #expect(match.poolSeed == UInt64(Int64.max))
        #expect(match.winnerID == nil)
        // `options` is `jsonb not null`: it comes back as a nested object with
        // its own snake_case keys, not as a string and never as null.
        #expect(match.options.minimumWordLength == 3)
        #expect(match.options.swapEnabled)
        #expect(match.options.dictionaryID == "standard")
        // The row's own columns are snake_case; the keys *inside* `options` are
        // whatever `MatchOptions` encodes, which is camelCase. The jsonb blob is
        // written by the app, so it does not follow the column convention.
    }

    @Test("A finished match decodes with its winner and both timestamps")
    func finishedMatchDecodes() throws {
        let match = try Self.decode(MatchRecord.self, """
        {"id":"3b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
         "host_id":"1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed","invite_code":"AB12CD",
         "wire_version":3,"seed":0,"options": {"minimumWordLength": 3,"swapEnabled": true,"dictionaryID": "standard","dictionaryHash": "abc123"},"status":"finished",
         "created_at":"2026-08-18T12:00:00+00:00","started_at":"2026-08-18T12:01:00+00:00",
         "finished_at":"2026-08-18T12:09:00+00:00",
         "winner_id":"2b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"}
        """)
        #expect(match.status == .finished)
        #expect(match.winnerID != nil)
        #expect(match.startedAt != nil)
        #expect(match.finishedAt != nil)
    }

    @Test("A match_players row decodes")
    func matchPlayerDecodes() throws {
        let row = try Self.decode(MatchPlayerRow.self, """
        {"match_id":"3b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
         "player_id":"1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
         "joined_at":"2026-08-18T12:00:00+00:00"}
        """)
        #expect(row.playerID.uuidString.uppercased().hasPrefix("1B9D6BCD"))
    }

    @Test("A row missing a column fails to decode rather than defaulting")
    func aMissingColumnIsAnError() {
        #expect(throws: (any Error).self) {
            try Self.decode(Profile.self, """
            {"id":"1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed","display_name":"a",
             "created_at":"2026-08-18T12:00:00+00:00","matches_played":0,"matches_won":0,
             "tiles_placed":0,"fastest_win_seconds":null}
            """)
        }
    }
}
