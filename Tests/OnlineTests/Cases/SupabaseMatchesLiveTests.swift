import Foundation
import Testing
import WillagramsRules
@testable import Online

/// Matches against the real project. Gated by `LiveProject.isEnabled` — with the
/// flag or the key missing every case reports as skipped, never as passed.
///
/// Every case signs in its own fresh anonymous users through `LiveProject.fresh()`,
/// so nothing here depends on a row another case left behind.
@Suite("Supabase matches, live project")
struct SupabaseMatchesLiveTests {

    /// Not `.standard`: a round trip that only proves the default survives
    /// proves nothing about the fields.
    static let options = MatchOptions(
        minimumWordLength: 7,
        swapEnabled: false,
        dictionaryID: "tourney-2026",
        dictionaryHash: String(repeating: "ab", count: 32)
    )

    /// `bigint` is signed and the column is `>= 0`, so this is the real range.
    static func drawSeed() -> Int64 { Int64.random(in: 0 ... Int64.max) }

    private static func signedIn() async throws -> (SupabaseBackend, UUID) {
        let backend = LiveProject.fresh()
        let profile = try await backend.signInAnonymously()
        return (backend, profile.id)
    }

    @Test("A new match seats its host, and nobody else", .enabled(if: LiveProject.isEnabled))
    func hostIsSeatedByCreateMatch() async throws {
        let (host, hostID) = try await Self.signedIn()
        let match = try await host.createMatchRow(options: Self.options, seed: Self.drawSeed())

        let roster = try await host.matchPlayerRows(inMatch: match.id)
        #expect(roster.count == 1)
        #expect(roster.first?.playerID == hostID)
        #expect(roster.first?.matchID == match.id)
        #expect(match.hostID == hostID)
        #expect(match.status == .lobby)
        #expect(match.wireVersion == WireFormat.current)
        #expect(match.inviteCode.count == 6)
    }

    @Test("A guest joining by code sees the same roster the host sees", .enabled(if: LiveProject.isEnabled))
    func guestJoinsAndBothSeeTwoRows() async throws {
        let (host, hostID) = try await Self.signedIn()
        let match = try await host.createMatchRow(options: Self.options, seed: Self.drawSeed())

        let (guest, guestID) = try await Self.signedIn()
        let joined = try await guest.joinMatchRow(inviteCode: match.inviteCode)
        #expect(joined.id == match.id)

        let asHost = try await host.matchPlayerRows(inMatch: match.id)
        let asGuest = try await guest.matchPlayerRows(inMatch: match.id)

        #expect(asHost == asGuest)
        #expect(asHost.map(\.playerID) == [hostID, guestID])
    }

    @Test("A code no lobby match carries is notFound", .enabled(if: LiveProject.isEnabled))
    func unknownCodeIsNotFound() async throws {
        let (backend, _) = try await Self.signedIn()

        // Six legal characters. The codes are random over 36^6 and nothing in
        // this run drew this one.
        await #expect(throws: BackendError.notFound) {
            _ = try await backend.joinMatchRow(inviteCode: "ZZZZZZ")
        }
    }

    @Test("The sixth player fills the lobby and the seventh is refused", .enabled(if: LiveProject.isEnabled))
    func seventhJoinIsMatchFull() async throws {
        let (host, hostID) = try await Self.signedIn()
        let match = try await host.createMatchRow(options: Self.options, seed: Self.drawSeed())

        var seated = [hostID]
        for _ in 1 ..< MatchLimits.players.upperBound {
            let (guest, guestID) = try await Self.signedIn()
            _ = try await guest.joinMatchRow(inviteCode: match.inviteCode)
            seated.append(guestID)
        }

        let full = try await host.matchPlayerRows(inMatch: match.id)
        #expect(full.count == MatchLimits.players.upperBound)
        #expect(full.map(\.playerID) == seated)

        let (seventh, _) = try await Self.signedIn()
        await #expect(throws: BackendError.matchFull) {
            _ = try await seventh.joinMatchRow(inviteCode: match.inviteCode)
        }

        // The refusal is a refusal, not a seat taken and then complained about.
        #expect(try await host.matchPlayerRows(inMatch: match.id).count
                == MatchLimits.players.upperBound)
    }

    @Test("Options and seed come back as the host drew them", .enabled(if: LiveProject.isEnabled))
    func optionsAndSeedRoundTrip() async throws {
        let seed = Self.drawSeed()
        let (host, _) = try await Self.signedIn()
        let match = try await host.createMatchRow(options: Self.options, seed: seed)

        #expect(match.options == Self.options)
        #expect(match.seed == seed)
        #expect(match.poolSeed == UInt64(seed))

        // Not the value the insert handed back — the row as a second client
        // resolves it through `join_match`.
        let (guest, _) = try await Self.signedIn()
        let joined = try await guest.joinMatchRow(inviteCode: match.inviteCode)
        #expect(joined.options == Self.options)
        #expect(joined.poolSeed == UInt64(seed))
    }
}
