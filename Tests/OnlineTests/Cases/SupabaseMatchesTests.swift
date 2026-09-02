import Foundation
import PostgREST
import Testing
import WillagramsRules
@testable import Online

/// The parts of the match client that decide something on their own — the code
/// generator, the retry policy, the payload keys, the row decoders and the
/// invite-code guardrail. None of this needs a project, which is the point: the
/// live half is exactly the half that does not run on most machines.
@Suite("Supabase matches, offline")
struct SupabaseMatchesOfflineTests {

    /// Deliberately not `.standard` — a round trip that only proves the default
    /// survives proves nothing about the fields.
    static let options = MatchOptions(
        minimumWordLength: 7,
        swapEnabled: false,
        dictionaryID: "tourney-2026",
        dictionaryHash: String(repeating: "ab", count: 32)
    )

    /// Big enough that a 32-bit truncation or a signed/unsigned slip shows.
    static let seed: Int64 = 9_007_199_254_740_993

    // MARK: Invite codes

    @Test("An invite code is six characters from the alphabet the check constraint allows")
    func inviteCodeMatchesTheCheckConstraint() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        #expect(Set(SupabaseBackend.inviteCodeAlphabet) == allowed)

        for _ in 0 ..< 2000 {
            let code = SupabaseBackend.randomInviteCode()
            #expect(code.count == 6)
            #expect(code.allSatisfy(allowed.contains))
        }
    }

    @Test("The generator varies — a constant code would collide on every second match")
    func inviteCodesVary() {
        let codes = Set((0 ..< 200).map { _ in SupabaseBackend.randomInviteCode() })
        #expect(codes.count > 190)
    }

    // MARK: Retry policy

    @Test("Only a unique violation earns the one retry")
    func retryPolicyIsUniqueViolationOnly() {
        #expect(SupabaseBackend.shouldRetryInsert(after: BackendError.alreadyExists))

        #expect(!SupabaseBackend.shouldRetryInsert(after: BackendError.notFound))
        #expect(!SupabaseBackend.shouldRetryInsert(after: BackendError.matchFull))
        #expect(!SupabaseBackend.shouldRetryInsert(after: BackendError.permissionDenied))
        #expect(!SupabaseBackend.shouldRetryInsert(after: BackendError.notAuthenticated))
        #expect(!SupabaseBackend.shouldRetryInsert(after: URLError(.timedOut)))

        struct Nonsense: Error {}
        #expect(!SupabaseBackend.shouldRetryInsert(after: Nonsense()))
    }

    // MARK: The join path's error contract

    /// `join_match` is the whole interface — it returns a row or it raises — so
    /// these two codes are the only failures a join can report, and they are
    /// asserted apart so breaking one cannot hide behind the other.
    @Test("P0002 from join_match is notFound")
    func joinNoDataIsNotFound() {
        let mapped = SupabaseBackend.backendError(
            from: PostgrestError(code: "P0002", message: "no lobby match with that invite code"),
            hasSession: true
        )
        #expect(mapped as? BackendError == .notFound)
    }

    @Test("P0005 from join_match is matchFull")
    func joinFullIsMatchFull() {
        let mapped = SupabaseBackend.backendError(
            from: PostgrestError(code: "P0005", message: "match is full"),
            hasSession: true
        )
        #expect(mapped as? BackendError == .matchFull)
    }

    // MARK: Rows in, rows out

    static func matchRowJSON(
        id: String = "6f1c0a3e-0b4a-4d2f-9e1a-2c3d4e5f6a7b",
        hostID: String = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
        inviteCode: String = "AB12CD"
    ) throws -> Data {
        let optionsJSON = try String(
            data: BackendCoding.encoder.encode(options),
            encoding: .utf8
        )!
        return Data("""
        {
          "id": "\(id)",
          "host_id": "\(hostID)",
          "invite_code": "\(inviteCode)",
          "wire_version": \(WireFormat.current),
          "seed": \(seed),
          "options": \(optionsJSON),
          "status": "lobby",
          "created_at": "2026-08-18T12:00:00.123456+00:00",
          "started_at": null,
          "finished_at": null,
          "winner_id": null
        }
        """.utf8)
    }

    @Test("The rpc's single object decodes, options and seed intact")
    func rpcRowDecodes() throws {
        let record = try SupabaseBackend.matchRecord(fromRow: Self.matchRowJSON())

        #expect(record.options == Self.options)
        #expect(record.seed == Self.seed)
        #expect(record.poolSeed == UInt64(Self.seed))
        #expect(record.inviteCode == "AB12CD")
        #expect(record.wireVersion == WireFormat.current)
        #expect(record.status == .lobby)
        #expect(record.startedAt == nil)
    }

    @Test("The insert's array decodes, and zero rows is nil rather than a throw")
    func insertRowsDecode() throws {
        let rows = try Data("[".utf8) + Self.matchRowJSON() + Data("]".utf8)
        let record = try #require(try SupabaseBackend.matchRecord(fromRows: rows))
        #expect(record.options == Self.options)
        #expect(record.poolSeed == UInt64(Self.seed))

        #expect(try SupabaseBackend.matchRecord(fromRows: Data("[]".utf8)) == nil)
    }

    @Test("The insert payload carries the column names, and options survives the trip")
    func insertPayloadKeysAreColumnNames() throws {
        let hostID = UUID(uuidString: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed")!
        let payload = SupabaseBackend.matchInsert(
            hostID: hostID,
            inviteCode: "AB12CD",
            options: Self.options,
            seed: Self.seed
        )
        let data = try BackendCoding.encoder.encode(payload)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(Set(object.keys) == ["host_id", "invite_code", "wire_version", "seed", "options", "status"])
        #expect(object["host_id"] as? String == hostID.uuidString)
        #expect(object["invite_code"] as? String == "AB12CD")
        #expect(object["wire_version"] as? Int == WireFormat.current)
        #expect(object["seed"] as? Int64 == Self.seed)
        #expect(object["status"] as? String == "lobby")

        // The options sub-object is what `MatchRecord.options` reads back, so it
        // has to survive the encoder unchanged.
        let optionsData = try JSONSerialization.data(
            withJSONObject: try #require(object["options"])
        )
        #expect(try BackendCoding.decoder.decode(MatchOptions.self, from: optionsData) == Self.options)
    }

    @Test("The host's membership payload carries the composite key's column names")
    func playerInsertPayloadKeys() throws {
        let matchID = UUID(uuidString: "6f1c0a3e-0b4a-4d2f-9e1a-2c3d4e5f6a7b")!
        let playerID = UUID(uuidString: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed")!
        let data = try BackendCoding.encoder.encode(
            SupabaseBackend.matchPlayerInsert(matchID: matchID, playerID: playerID)
        )
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["match_id", "player_id"])
        #expect(object["match_id"] as? String == matchID.uuidString)
        #expect(object["player_id"] as? String == playerID.uuidString)
    }

    @Test("The roster keeps the server's joined_at order rather than re-sorting it")
    func rosterKeepsServerOrder() throws {
        // The array order is the server's `order by joined_at`; the timestamps
        // are deliberately not in that order, so anything that sorts locally —
        // or decodes into a set — reorders these three.
        let json = """
        [
          {"match_id": "6f1c0a3e-0b4a-4d2f-9e1a-2c3d4e5f6a7b",
           "player_id": "00000000-0000-0000-0000-00000000000a",
           "joined_at": "2026-08-18T12:00:02.500000+00:00"},
          {"match_id": "6f1c0a3e-0b4a-4d2f-9e1a-2c3d4e5f6a7b",
           "player_id": "00000000-0000-0000-0000-00000000000b",
           "joined_at": "2026-08-18T12:00:00+00:00"},
          {"match_id": "6f1c0a3e-0b4a-4d2f-9e1a-2c3d4e5f6a7b",
           "player_id": "00000000-0000-0000-0000-00000000000c",
           "joined_at": "2026-08-18T12:00:01.750000+00:00"}
        ]
        """
        let rows = try SupabaseBackend.matchPlayerRows(fromRows: Data(json.utf8))

        #expect(rows.count == 3)
        #expect(rows.map(\.playerID.uuidString.last) == ["A", "B", "C"])
        // Both timestamp shapes the column can carry decoded, not just one.
        #expect(rows[1].joinedAt < rows[2].joinedAt)
    }

    // MARK: The guardrail

    /// `join_match` is the only read of `matches` by `invite_code` anywhere, and
    /// the reason is in `0003_join_match.sql`: a policy that resolves a code
    /// turns the table into an oracle over a six-character space, with the anon
    /// key shipped in the binary. A client-side `select` reintroduces it.
    @Test("No client source resolves a match by its invite code")
    func inviteCodeIsNeverQueriedFromTheClient() throws {
        // From `#filePath`, not the process cwd: `swift test` runs from
        // wherever it likes, and the scan has to find the real sources.
        let root = URL(fileURLWithPath: #filePath)     // .../Tests/OnlineTests/Cases/<this>
            .deletingLastPathComponent()               // Cases
            .deletingLastPathComponent()               // OnlineTests
            .deletingLastPathComponent()               // Tests
            .deletingLastPathComponent()               // repo root
            .appendingPathComponent("Willagrams/Online")

        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            // Nested dev-team worktrees are full checkouts of this same repo;
            // a self-scan that walks into them passes here and fails in main.
            .filter { !$0.path.contains("/.claude/") }

        #expect(files.count >= 4, "the scan found no sources — the root is wrong, not the code")

        // A line that names the column *and* a query operator is a lookup. The
        // column name alone is fine: `MatchRecord` has to decode it.
        let queryish = [".eq(", ".from(\"matches\")", ".select(", ".filter(", ".match("]
        for file in files {
            for (number, line) in try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("invite_code") {
                let offender = queryish.first(where: line.contains)
                #expect(
                    offender == nil,
                    "\(file.lastPathComponent):\(number + 1) resolves a match by invite code — join_match is the only path"
                )
            }
        }
    }

    /// The three protocol methods forward to the real queries. Nothing else in
    /// the suite covers them — a live call is the only other witness — so a
    /// silent revert to the placeholder bodies would surface first in
    /// production, as `notAuthenticated` on every host and join.
    @Test("createMatch, joinMatch and players are wired, not still stubbed")
    func theProtocolMethodsAreWired() throws {
        let online = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()               // Cases
            .deletingLastPathComponent()               // OnlineTests
            .deletingLastPathComponent()               // Tests
            .deletingLastPathComponent()               // repo root
            .appendingPathComponent("Willagrams/Online")

        let backend = try String(
            contentsOf: online.appendingPathComponent("SupabaseBackend.swift"), encoding: .utf8)
        #expect(
            !backend.contains("notAuthenticated // item 5"),
            "SupabaseBackend still carries the placeholder match bodies")
        for call in ["createMatchRow(options:", "joinMatchRow(inviteCode:", "matchPlayerRows(inMatch:"] {
            let forward = String(call.prefix(while: { $0 != "(" }))
            #expect(backend.contains(forward), "SupabaseBackend never calls \(forward)")
        }

        let matches = try String(
            contentsOf: online.appendingPathComponent("SupabaseBackend+Matches.swift"), encoding: .utf8)
        #expect(
            !matches.contains("throw SupabaseMatchesUnwired()"),
            "matchQueries() still throws instead of building the real queries")
    }
}
