//
//  SupabaseBackend+Outcome.swift
//  Willagrams
//
//  ``MatchOutcomeStore`` over PostgREST. The only half of the outcome recorder
//  that needs a project to prove; every rule it obeys is decided next door in
//  `MatchOutcomeRecorder.swift`.
//
//  Same shape as `SupabaseMatchQueries`: an injected `PostgrestClient` plus
//  `hasSession`, and one `mapping { }` so an RLS refusal comes back as
//  `BackendError.permissionDenied` rather than `.notAuthenticated`.
//
//  ## Why `returning: .minimal`
//
//  `PostgrestQueryBuilder.update` defaults to `.representation`, which asks the
//  server to send the updated row back — and that read is a *second* policy
//  check. The `matches` writes here do not want the row, so they do not pay for
//  it. The stats bump is not an update at all: it is `record_outcome`, which
//  returns its row from inside the same statement that wrote it.
//
//  ## What an RLS refusal looks like on an update
//
//  Nothing. PostgREST turns a row the policy hides into a row the `PATCH` did
//  not match: 200, empty body, no error. That is precisely why
//  ``MatchOutcomeRecorder/isCreator`` gates the `matches` write on the client
//  instead of leaning on `matches_update_host` to say no.
//

import Foundation
import PostgREST
import WillagramsRules

struct SupabaseOutcomeQueries: MatchOutcomeStore {

    let rest: PostgrestClient
    let hasSession: Bool

    private func mapping<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw SupabaseBackend.backendError(from: error, hasSession: hasSession)
        }
    }

    // MARK: matches

    /// The `playing` half. `started_at` is written with the status because the
    /// row's check constraint pairs them.
    private struct PlayingPayload: Encodable {
        let status = MatchRecordStatus.playing.rawValue
        let startedAt: Date

        enum CodingKeys: String, CodingKey {
            case status
            case startedAt = "started_at"
        }
    }

    /// The `finished` half. All three columns move together for the same
    /// reason.
    private struct FinishedPayload: Encodable {
        let status = MatchRecordStatus.finished.rawValue
        let finishedAt: Date
        let winnerID: UUID

        enum CodingKeys: String, CodingKey {
            case status
            case finishedAt = "finished_at"
            case winnerID = "winner_id"
        }
    }

    func updateMatch(_ id: UUID, _ update: MatchOutcomeUpdate) async throws {
        _ = try await mapping {
            let query = rest.from("matches")
            let filtered = switch update {
            case let .playing(startedAt):
                try query.update(PlayingPayload(startedAt: startedAt), returning: .minimal)
            case let .finished(finishedAt, winnerID):
                try query.update(
                    FinishedPayload(finishedAt: finishedAt, winnerID: winnerID), returning: .minimal
                )
            }
            return try await filtered.eq("id", value: id.uuidString).execute().data
        }
    }

    // MARK: profiles

    func profile(_ id: UUID) async throws -> Profile {
        let rows = try await mapping {
            try await rest.from("profiles")
                .select()
                .eq("id", value: id.uuidString)
                .limit(1)
                .execute()
                .data
        }
        guard let profile = try SupabaseBackend.firstProfile(fromRows: rows) else {
            throw BackendError.notFound
        }
        return profile
    }

    /// The three deltas `record_outcome` takes. `id` is deliberately not among
    /// them: the function reads the caller from `auth.uid()`, so there is no
    /// row for a client to name and therefore no wrong one it can name.
    private struct OutcomeParams: Encodable {
        let won: Bool
        let tiles: Int
        let elapsedSeconds: Int

        enum CodingKeys: String, CodingKey {
            case won
            case tiles
            case elapsedSeconds = "elapsed_seconds"
        }
    }

    /// One statement on the server, so the counters cannot be computed from a
    /// row a concurrent match has already moved. `42501` with no session and
    /// `P0002` with no profile row; `SupabaseBackend.backendError` maps both.
    ///
    /// `id` is the caller's own and is not sent — see ``OutcomeParams``. It
    /// stays in the signature because the offline doubles hold more than one
    /// row and have to be told which.
    @discardableResult
    func recordOutcome(
        _ id: UUID, won: Bool, tilesPlaced: Int, elapsedSeconds: Int
    ) async throws -> Profile {
        let row = try await mapping {
            try await rest
                .rpc(
                    "record_outcome",
                    params: OutcomeParams(
                        won: won, tiles: tilesPlaced, elapsedSeconds: elapsedSeconds)
                )
                .execute()
                .data
        }
        // A composite return is one object, not the array `firstProfile` reads.
        return try BackendCoding.decoder.decode(Profile.self, from: row)
    }
}

extension SupabaseBackend {

    /// The store an outcome recorder runs on.
    ///
    /// `nonisolated` is not available here — `rest` is actor state — so this is
    /// `async`, which every call site already is.
    public func outcomeStore() -> any MatchOutcomeStore {
        SupabaseOutcomeQueries(rest: rest, hasSession: auth.currentSession != nil)
    }
}
