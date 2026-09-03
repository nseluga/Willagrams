//
//  SupabaseBackend+Matches.swift
//  Willagrams
//
//  Matches on the real client: create a lobby, join one by code, read the
//  roster.
//
//  ## Why the odd names
//
//  `SupabaseBackend.swift` already declares the three protocol methods with
//  placeholder bodies, and Swift forbids redeclaring them in an extension. A
//  parallel item owns that file this round, so this file does NOT apply the
//  wiring. A human applies exactly this three-line patch to
//  `Willagrams/Online/SupabaseBackend.swift`, replacing each
//  `throw BackendError.notAuthenticated // item 5` body:
//
//      public func createMatch(options: MatchOptions, seed: Int64) async throws -> MatchRecord {
//          try await createMatchRow(options: options, seed: seed)
//      }
//      public func joinMatch(inviteCode: String) async throws -> MatchRecord {
//          try await joinMatchRow(inviteCode: inviteCode)
//      }
//      public func players(inMatch matchID: UUID) async throws -> [MatchPlayerRow] {
//          try await matchPlayerRows(inMatch: matchID)
//      }
//
//  ## The seam that is not wired, and why
//
//  `SupabaseBackend` declares `private let auth` and `private let rest`. In
//  Swift `private` is scoped to the declaring file, so an extension in THIS file
//  cannot see either one — the compiler says so:
//
//      error: 'rest' is inaccessible due to 'private' protection level
//
//  So `matchQueries()` below is the one unwired line in this file, and every
//  query it would have carried is written out in full in `SupabaseMatchQueries`,
//  which takes the `PostgrestClient` as a parameter. The amendment a human
//  applies alongside the patch above is two words wide — drop `private` from
//  `SupabaseBackend.swift` lines 22–23:
//
//      let auth: AuthClient
//      let rest: PostgrestClient
//
//  and then `matchQueries()` becomes:
//
//      func matchQueries() throws -> SupabaseMatchQueries {
//          SupabaseMatchQueries(rest: rest, hasSession: auth.currentSession != nil)
//      }
//
//  Until that lands, a live call throws `SupabaseMatchesUnwired` — loudly, and
//  never quietly succeeding.
//
//  ## The one rule this file obeys above all others
//
//  `matches` is never selected by its invite code from the client. `join_match`
//  (0003) is the only code-to-row path in the whole system, and widening that is
//  widening an oracle over a six-character space whose anon key ships in the
//  binary. `SupabaseMatchesTests.inviteCodeIsNeverQueriedFromTheClient` scans
//  this directory and fails if anyone adds one.
//

import Auth
import Foundation
import PostgREST
import WillagramsRules

/// Thrown only while the amendment described at the top of this file is
/// outstanding. Distinct from every `BackendError` on purpose: a live run that
/// hits this must not be mistakable for "nobody is signed in".
struct SupabaseMatchesUnwired: Error, Sendable {
    let detail = "SupabaseBackend.rest is private; see SupabaseBackend+Matches.swift header"
}

// MARK: - The queries

/// Every match query, over an injected `PostgrestClient`.
///
/// A separate value rather than methods on the actor because the actor's client
/// is `private` to another file (see the header). It is also the shape that
/// makes each query readable on its own.
struct SupabaseMatchQueries: Sendable {

    let rest: PostgrestClient

    /// An RLS refusal means two different things depending on this; the single
    /// mapper in `SupabaseBackend` is what decides which.
    let hasSession: Bool

    private func mapping<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw SupabaseBackend.backendError(from: error, hasSession: hasSession)
        }
    }

    /// Creates the lobby and seats the host in it.
    ///
    /// The `match_players` insert is part of this call, never left to the
    /// caller: a host who is not in their own roster is a match that can never
    /// read itself back, and `match_players_insert_self` (0003) admits the host
    /// into their own lobby precisely so this can happen here.
    func createMatch(hostID: UUID, options: MatchOptions, seed: Int64) async throws -> MatchRecord {
        let record: MatchRecord
        do {
            record = try await insertMatch(hostID: hostID, options: options, seed: seed)
        } catch {
            // Exactly once. A unique violation can only be the six-character
            // code — the id is a fresh `gen_random_uuid()` — and a second
            // collision over 36^6 is not luck running out, it is something else
            // wrong.
            guard SupabaseBackend.shouldRetryInsert(after: error) else { throw error }
            record = try await insertMatch(hostID: hostID, options: options, seed: seed)
        }

        _ = try await mapping {
            try await rest.from("match_players")
                .insert(SupabaseBackend.matchPlayerInsert(matchID: record.id, playerID: hostID))
                .execute()
        }
        return record
    }

    private func insertMatch(
        hostID: UUID,
        options: MatchOptions,
        seed: Int64
    ) async throws -> MatchRecord {
        let rows = try await mapping {
            try await rest.from("matches")
                .insert(
                    SupabaseBackend.matchInsert(
                        hostID: hostID,
                        inviteCode: SupabaseBackend.randomInviteCode(),
                        options: options,
                        seed: seed
                    ),
                    returning: .representation
                )
                .execute()
                .data
        }
        guard let record = try SupabaseBackend.matchRecord(fromRows: rows) else {
            throw BackendError.notFound
        }
        return record
    }

    /// The only code-to-row path. `join_match` upper-cases the code, seats the
    /// caller, and hands back the row that seat earns — P0002 when no lobby
    /// carries the code, P0005 when it is full.
    func joinMatch(inviteCode: String) async throws -> MatchRecord {
        let row = try await mapping {
            try await rest
                .rpc("join_match", params: ["code": inviteCode])
                .execute()
                .data
        }
        return try SupabaseBackend.matchRecord(fromRow: row)
    }

    func players(inMatch matchID: UUID) async throws -> [MatchPlayerRow] {
        let rows = try await mapping {
            try await rest.from("match_players")
                .select()
                .eq("match_id", value: matchID.uuidString)
                .order("joined_at", ascending: true)
                .execute()
                .data
        }
        return try SupabaseBackend.matchPlayerRows(fromRows: rows)
    }
}

// MARK: - Pure statics and the actor's entry points

extension SupabaseBackend {

    // MARK: Invite codes

    /// Exactly the set `matches.invite_code`'s check constraint allows
    /// (`^[A-Z0-9]{6}$`). A draw outside it is a bug here, not a collision.
    static let inviteCodeAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    static func randomInviteCode() -> String {
        String((0 ..< 6).map { _ in inviteCodeAlphabet.randomElement()! })
    }

    /// The retry-once policy, as a value the production loop actually asks.
    ///
    /// Only a unique violation is worth a second round trip: a full lobby stays
    /// full, a missing row stays missing, and an RLS refusal is not luck.
    static func shouldRetryInsert(after error: any Error) -> Bool {
        (error as? BackendError) == .alreadyExists
    }

    // MARK: Payloads

    /// The `matches` insert, as a value so the encoded keys are assertable with
    /// no project. These key names are the column names; getting one wrong is a
    /// runtime 400 that only a live run would ever see.
    struct MatchInsertPayload: Encodable, Sendable {
        let hostID: UUID
        let inviteCode: String
        let wireVersion: Int
        let seed: Int64
        let options: MatchOptions
        let status: String

        enum CodingKeys: String, CodingKey {
            case hostID = "host_id"
            case inviteCode = "invite_code"
            case wireVersion = "wire_version"
            case seed
            case options
            case status
        }
    }

    struct MatchPlayerInsertPayload: Encodable, Sendable {
        let matchID: UUID
        let playerID: UUID

        enum CodingKeys: String, CodingKey {
            case matchID = "match_id"
            case playerID = "player_id"
        }
    }

    static func matchInsert(
        hostID: UUID,
        inviteCode: String,
        options: MatchOptions,
        seed: Int64
    ) -> MatchInsertPayload {
        MatchInsertPayload(
            hostID: hostID,
            inviteCode: inviteCode,
            wireVersion: WireFormat.current,
            seed: seed,
            options: options,
            status: MatchRecordStatus.lobby.rawValue
        )
    }

    static func matchPlayerInsert(matchID: UUID, playerID: UUID) -> MatchPlayerInsertPayload {
        MatchPlayerInsertPayload(matchID: matchID, playerID: playerID)
    }

    // MARK: Decoding

    /// `join_match` returns one `matches` composite, so PostgREST answers with a
    /// single object rather than an array.
    static func matchRecord(fromRow data: Data) throws -> MatchRecord {
        try BackendCoding.decoder.decode(MatchRecord.self, from: data)
    }

    /// An insert with `returning: .representation` answers with an array, and
    /// zero rows is `nil` rather than a throw — same shape as
    /// `firstProfile(fromRows:)`.
    static func matchRecord(fromRows data: Data) throws -> MatchRecord? {
        try BackendCoding.decoder.decode([MatchRecord].self, from: data).first
    }

    /// The roster in the order the server sent it. The decoder must not sort:
    /// `joined_at` order is the server's answer, not something to re-derive.
    static func matchPlayerRows(fromRows data: Data) throws -> [MatchPlayerRow] {
        try BackendCoding.decoder.decode([MatchPlayerRow].self, from: data)
    }

    // MARK: Entry points

    /// The one unwired line in this file. See the header: `rest` and `auth` are
    /// `private` to `SupabaseBackend.swift`, which a parallel item owns.
    func matchQueries() throws -> SupabaseMatchQueries {
        SupabaseMatchQueries(rest: rest, hasSession: auth.currentSession != nil)
    }

    func createMatchRow(options: MatchOptions, seed: Int64) async throws -> MatchRecord {
        guard let hostID = currentUserID else { throw BackendError.notAuthenticated }
        return try await matchQueries().createMatch(hostID: hostID, options: options, seed: seed)
    }

    func joinMatchRow(inviteCode: String) async throws -> MatchRecord {
        try await matchQueries().joinMatch(inviteCode: inviteCode)
    }

    func matchPlayerRows(inMatch matchID: UUID) async throws -> [MatchPlayerRow] {
        try await matchQueries().players(inMatch: matchID)
    }
}
