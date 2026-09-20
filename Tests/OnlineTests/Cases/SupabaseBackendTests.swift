import Auth
import Foundation
import Testing
@testable import Online

/// The parts of `SupabaseBackend` that decide something on their own, tested
/// with no project and no network. Everything here would still be a guess if it
/// only ran under the live gate, which is exactly the half that never runs.
@Suite("Supabase backend, offline")
struct SupabaseBackendOfflineTests {

    // MARK: Friend codes

    @Test("A friend code is eight characters from the alphabet the check constraint allows")
    func friendCodeMatchesTheCheckConstraint() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        #expect(Set(SupabaseBackend.friendCodeAlphabet) == allowed)

        for _ in 0 ..< 2000 {
            let code = SupabaseBackend.randomFriendCode()
            #expect(code.count == 8)
            #expect(code.allSatisfy(allowed.contains))
        }
    }

    @Test("The generator actually varies — a constant code would collide on every insert")
    func friendCodesVary() {
        let codes = Set((0 ..< 200).map { _ in SupabaseBackend.randomFriendCode() })
        #expect(codes.count > 190)
    }

    // MARK: Zero rows

    @Test("An empty PostgREST array is nil, not a throw — this is `profile(friendCode:)`'s nil path")
    func zeroRowsIsNil() throws {
        #expect(try SupabaseBackend.firstProfile(fromRows: Data("[]".utf8)) == nil)
    }

    @Test("One row decodes through BackendCoding, not a second decoder")
    func oneRowDecodes() throws {
        let json = """
        [{
          "id": "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
          "display_name": "Player AB12",
          "friend_code": "AB12CD34",
          "created_at": "2026-08-18T12:00:00.123456+00:00",
          "matches_played": 0,
          "matches_won": 0,
          "tiles_placed": 0,
          "fastest_win_seconds": null
        }]
        """
        let profile = try #require(try SupabaseBackend.firstProfile(fromRows: Data(json.utf8)))
        #expect(profile.friendCode == "AB12CD34")
        #expect(profile.matchesPlayed == 0)
    }

    // MARK: Error mapping

    private func mapped(_ code: String, hasSession: Bool = true) -> (any Error) {
        SupabaseBackend.backendError(
            from: PostgrestError(code: code, message: "test"),
            hasSession: hasSession
        )
    }

    @Test("A unique violation is alreadyExists")
    func uniqueViolation() {
        #expect(mapped("23505") as? BackendError == .alreadyExists)
    }

    @Test("An RLS refusal is permissionDenied with a session and notAuthenticated without one")
    func rlsRefusal() {
        #expect(mapped("42501", hasSession: true) as? BackendError == .permissionDenied)
        #expect(mapped("42501", hasSession: false) as? BackendError == .notAuthenticated)
    }

    @Test("The schema's raised codes map onto the closed enum")
    func raisedCodes() {
        #expect(mapped("P0002") as? BackendError == .notFound)
        #expect(mapped("P0005") as? BackendError == .matchFull)
    }

    @Test("A missing session is notAuthenticated")
    func missingSession() {
        let mapped = SupabaseBackend.backendError(from: AuthError.sessionMissing, hasSession: false)
        #expect(mapped as? BackendError == .notAuthenticated)
    }

    @Test("A transport failure is offline")
    func transportFailure() {
        let mapped = SupabaseBackend.backendError(
            from: URLError(.notConnectedToInternet),
            hasSession: true
        )
        #expect(mapped as? BackendError == .offline)
    }

    @Test("Anything unrecognised is rethrown unchanged rather than guessed at")
    func unmappedRethrows() {
        #expect(mapped("42P01") is PostgrestError)

        let other = AuthError.implicitGrantRedirect(message: "nope")
        #expect(SupabaseBackend.backendError(from: other, hasSession: true) as? AuthError == other)

        struct Nonsense: Error {}
        #expect(SupabaseBackend.backendError(from: Nonsense(), hasSession: true) is Nonsense)
    }
}
