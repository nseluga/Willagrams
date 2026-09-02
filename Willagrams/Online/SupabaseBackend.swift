//
//  SupabaseBackend.swift
//  Willagrams
//
//  The concrete `BackendClient`. This is the only file in the app that knows
//  Supabase exists — `BackendContracts.swift` and `FakeBackend.swift` stay
//  SDK-free so three lanes keep compiling without a project.
//
//  There is no `SupabaseClient` here: the umbrella product is not linked, only
//  `Auth`, `PostgREST` and `Realtime`. The three sub-clients are composed by
//  hand over one token source, which is all `SupabaseClient` does anyway.
//

import Auth
import Foundation
import PostgREST
import Realtime
import WillagramsRules

public actor SupabaseBackend: BackendClient {

    let auth: AuthClient
    let rest: PostgrestClient

    /// Built here rather than in item 8, so the whole client has one token
    /// source and one place to configure it.
    let realtime: RealtimeClientV2

    /// - Parameter localStorage: where the session is persisted. The Keychain in
    ///   the app; a test passes an in-memory store so each live case is a fresh
    ///   user rather than whichever session the last one left behind.
    public init(
        url: URL = SupabaseConfig.url,
        anonKey: String = SupabaseConfig.anonKey,
        localStorage: any AuthLocalStorage = AuthClient.Configuration.defaultLocalStorage
    ) {
        let headers = ["apikey": anonKey, "Authorization": "Bearer \(anonKey)"]

        let auth = AuthClient(
            configuration: .init(
                url: url.appendingPathComponent("/auth/v1"),
                headers: headers,
                localStorage: localStorage,
                logger: nil
            )
        )
        self.auth = auth

        // The anon key rides in `headers`; this closure overwrites the
        // `Authorization` header with the live access token whenever there is
        // one, which is what makes `auth.uid()` non-null for RLS.
        let authorized: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            var request = request
            if let token = try? await auth.session.accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            return try await URLSession.shared.data(for: request)
        }

        rest = PostgrestClient(
            url: url.appendingPathComponent("/rest/v1"),
            headers: headers,
            logger: nil,
            fetch: authorized,
            encoder: BackendCoding.encoder,
            decoder: BackendCoding.decoder
        )

        realtime = RealtimeClientV2(
            url: url.appendingPathComponent("/realtime/v1"),
            options: RealtimeClientOptions(
                headers: headers,
                accessToken: { try? await auth.session.accessToken }
            )
        )
    }

    // MARK: - Session

    public var currentUserID: UUID? { auth.currentUser?.id }

    /// Item 8. Sign in with Apple needs the entitlement and the nonce plumbing
    /// that the `account` lane owns; until then this route is closed.
    public func signInWithApple(idToken: String, nonce: String) async throws -> Profile {
        throw BackendError.notAuthenticated // item 8
    }

    public func signOut() async throws {
        try await mapping { try await auth.signOut() }
    }

    #if DEBUG
    /// Anonymous sign-in, for live tests and for trying the app without an
    /// Apple ID. Debug-only: a shipped build must never hand out a session that
    /// no one can ever sign back into.
    ///
    /// Idempotent — called with a session already in hand it reuses it, so the
    /// same user signing in twice gets the same profile row rather than a
    /// second anonymous account.
    public func signInAnonymously() async throws -> Profile {
        if let existing = auth.currentSession?.user.id {
            return try await ensureProfile(id: existing)
        }
        let session = try await mapping { try await auth.signInAnonymously() }
        return try await ensureProfile(id: session.user.id)
    }
    #endif

    // MARK: - Profiles

    public func profile(id: UUID) async throws -> Profile {
        guard let profile = try await selectProfile(column: "id", value: id.uuidString) else {
            throw BackendError.notFound
        }
        return profile
    }

    public func profile(friendCode: String) async throws -> Profile? {
        try await selectProfile(column: "friend_code", value: friendCode)
    }

    public func updateDisplayName(_ name: String) async throws -> Profile {
        guard let id = auth.currentUser?.id else { throw BackendError.notAuthenticated }
        let rows = try await mapping {
            try await rest.from("profiles")
                .update(["display_name": name])
                .eq("id", value: id.uuidString)
                .execute()
                .data
        }
        guard let profile = try Self.firstProfile(fromRows: rows) else { throw BackendError.notFound }
        return profile
    }

    /// The one place a profile row is created. Both sign-in routes go through
    /// it, so "first sign-in" and "signed in again on a new device" are the
    /// same code path.
    private func ensureProfile(id: UUID) async throws -> Profile {
        if let existing = try await selectProfile(column: "id", value: id.uuidString) {
            return existing
        }
        do {
            return try await insertProfile(id: id)
        } catch BackendError.alreadyExists {
            // Either another device inserted the row between the select and the
            // insert, or the random friend code collided. One retry settles
            // both: the row now exists, or a fresh code is drawn.
            if let existing = try await selectProfile(column: "id", value: id.uuidString) {
                return existing
            }
            return try await insertProfile(id: id)
        }
    }

    /// `internal` so a live test can call it twice and watch the unique
    /// violation come back as `BackendError.alreadyExists`.
    func insertProfile(id: UUID) async throws -> Profile {
        let code = Self.randomFriendCode()
        let rows = try await mapping {
            try await rest.from("profiles")
                .insert(
                    ["id": id.uuidString, "friend_code": code, "display_name": "Player \(code.prefix(4))"],
                    returning: .representation
                )
                .execute()
                .data
        }
        guard let profile = try Self.firstProfile(fromRows: rows) else { throw BackendError.notFound }
        return profile
    }

    private func selectProfile(column: String, value: String) async throws -> Profile? {
        let rows = try await mapping {
            try await rest.from("profiles")
                .select()
                .eq(column, value: value)
                .limit(1)
                .execute()
                .data
        }
        return try Self.firstProfile(fromRows: rows)
    }

    /// Zero rows is `nil`, not a throw. Factored out so the empty-array case is
    /// provable without a project: PostgREST answers a filter that matches
    /// nobody with `[]`, not with a 404.
    static func firstProfile(fromRows data: Data) throws -> Profile? {
        try BackendCoding.decoder.decode([Profile].self, from: data).first
    }

    // MARK: - Friend codes

    /// Exactly the set `profiles.friend_code`'s check constraint allows. A draw
    /// outside it is a bug here, not a collision to retry.
    static let friendCodeAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    static func randomFriendCode() -> String {
        String((0 ..< 8).map { _ in friendCodeAlphabet.randomElement()! })
    }

    // MARK: - Errors

    /// Every Postgres and Auth failure the app can provoke, in the closed enum
    /// the screens speak. Pure and static so it is testable with no network.
    ///
    /// - Parameter hasSession: an RLS refusal means two different things. With
    ///   a session the row exists and is not yours; without one `auth.uid()` was
    ///   null and the real problem is that nobody is signed in.
    static func backendError(from error: any Error, hasSession: Bool) -> any Error {
        if let postgrest = error as? PostgrestError {
            switch postgrest.code {
            case "23505": return BackendError.alreadyExists
            case "42501": return hasSession ? BackendError.permissionDenied : BackendError.notAuthenticated
            case "P0002": return BackendError.notFound
            case "P0005": return BackendError.matchFull
            default: return error
            }
        }
        if let auth = error as? AuthError, auth == .sessionMissing { return BackendError.notAuthenticated }
        if error is URLError { return BackendError.offline }
        return error
    }

    func mapping<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw Self.backendError(from: error, hasSession: auth.currentSession != nil)
        }
    }

    // MARK: - Not yet

    public func createMatch(options: MatchOptions, seed: Int64) async throws -> MatchRecord {
        try await createMatchRow(options: options, seed: seed)
    }

    public func joinMatch(inviteCode: String) async throws -> MatchRecord {
        try await joinMatchRow(inviteCode: inviteCode)
    }

    public func players(inMatch matchID: UUID) async throws -> [MatchPlayerRow] {
        try await matchPlayerRows(inMatch: matchID)
    }

    /// One channel, one subscription, and it is subscribed before this returns
    /// — a caller that has the transport in hand can send straight away.
    public func transport(for match: MatchRecord, as player: PlayerID) async throws -> any MatchTransport {
        // A previous transport on this same match may still be tearing its
        // channel down; the client would otherwise hand back that dying
        // instance.
        await SupabaseMatchChannel.awaitPendingRemoval(matchID: match.id)
        return try await mapping {
            try await RealtimeMatchTransport.connect(
                localPlayerID: player,
                channel: SupabaseMatchChannel(
                    realtime: realtime, matchID: match.id, localPlayerID: player))
        }
    }
}
