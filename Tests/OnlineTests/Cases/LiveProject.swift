import Auth
import Foundation
import Testing
@testable import Online

/// The gate. Live cases talk to the real project, so they run only when both
/// halves are present: the opt-in flag and a key to open the door with. Unset
/// either and every case below reports as skipped — never as passed, which is
/// the failure mode that lets a broken client ship green.
///
///     WILLAGRAMS_LIVE_TESTS=1 SUPABASE_ANON_KEY=... swift test --package-path Tests/OnlineTests
enum LiveProject {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WILLAGRAMS_LIVE_TESTS"] == "1"
            && !SupabaseConfig.anonKey.isEmpty
    }

    /// A backend nobody else shares. Each case gets its own session store, so
    /// "a fresh anonymous user" really is fresh rather than whichever session
    /// the Keychain still holds from the last run.
    static func fresh() -> SupabaseBackend {
        SupabaseBackend(localStorage: EphemeralAuthStorage())
    }
}

/// Session storage that dies with the test. Not a mock of the Keychain — the
/// real thing would make two cases in the same run share one user.
final class EphemeralAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        lock.withLock { values[key] = value }
    }

    func retrieve(key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    func remove(key: String) throws {
        lock.withLock { values[key] = nil }
    }
}

@Suite("Supabase backend, live project")
struct SupabaseBackendLiveTests {

    @Test("A fresh anonymous sign-in leaves a real profile row behind", .enabled(if: LiveProject.isEnabled))
    func freshSignInCreatesProfile() async throws {
        let backend = LiveProject.fresh()
        let profile = try await backend.signInAnonymously()

        #expect(profile.friendCode.count == 8)
        #expect(profile.friendCode.allSatisfy(Set(SupabaseBackend.friendCodeAlphabet).contains))
        #expect(profile.matchesPlayed == 0)
        #expect(await backend.currentUserID == profile.id)

        // Not the value we were handed — the row as the database now holds it.
        let stored = try await backend.profile(id: profile.id)
        #expect(stored == profile)
    }

    @Test("The same user signing in twice gets one row, not two", .enabled(if: LiveProject.isEnabled))
    func secondSignInIsIdempotent() async throws {
        let backend = LiveProject.fresh()
        let first = try await backend.signInAnonymously()
        let second = try await backend.signInAnonymously()

        #expect(first == second)

        // `profile(friendCode:)` is a unique lookup, so agreeing with the id
        // lookup is what proves a single row carries that code.
        let byCode = try await backend.profile(friendCode: first.friendCode)
        #expect(byCode == first)
    }

    @Test("A second insert of the same id is alreadyExists", .enabled(if: LiveProject.isEnabled))
    func duplicateInsertIsAlreadyExists() async throws {
        let backend = LiveProject.fresh()
        let profile = try await backend.signInAnonymously()

        await #expect(throws: BackendError.alreadyExists) {
            _ = try await backend.insertProfile(id: profile.id)
        }
    }

    @Test("An unknown friend code is nil, not a throw", .enabled(if: LiveProject.isEnabled))
    func unknownFriendCodeIsNil() async throws {
        let backend = LiveProject.fresh()
        _ = try await backend.signInAnonymously()

        // Eight legal characters that no row can hold: the codes are random over
        // 36^8, and this run just made the only new one.
        #expect(try await backend.profile(friendCode: "ZZZZZZZZ") == nil)
    }

    @Test("Renaming writes through and comes back on the row", .enabled(if: LiveProject.isEnabled))
    func updateDisplayNameWritesThrough() async throws {
        let backend = LiveProject.fresh()
        let profile = try await backend.signInAnonymously()

        let renamed = try await backend.updateDisplayName("Renamed")
        #expect(renamed.displayName == "Renamed")
        #expect(renamed.id == profile.id)
        #expect(try await backend.profile(id: profile.id).displayName == "Renamed")
    }
}
