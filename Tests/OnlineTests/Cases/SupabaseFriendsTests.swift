import Foundation
import Testing
@testable import Online

/// The parts of the friendships client that decide something on their own —
/// filters, payloads, decoding. These run with no project and no network, so
/// the half of the item that can be proved without a key actually is.
@Suite("Supabase friendships, offline")
struct SupabaseFriendsOfflineTests {

    private let alice = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let bob = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let carol = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    // MARK: The unordered pair

    @Test("The pair filter is the same string in either argument order")
    func pairFilterIsOrderStable() {
        #expect(SupabaseBackend.pairFilter(alice, bob) == SupabaseBackend.pairFilter(bob, alice))
        #expect(SupabaseBackend.pairFilter(bob, carol) == SupabaseBackend.pairFilter(carol, bob))
    }

    @Test("The pair filter names both directions of exactly that pair")
    func pairFilterCoversBothDirections() {
        let filter = SupabaseBackend.pairFilter(alice, bob)
        #expect(filter.contains("and(requester_id.eq.\(alice.uuidString),addressee_id.eq.\(bob.uuidString))"))
        #expect(filter.contains("and(requester_id.eq.\(bob.uuidString),addressee_id.eq.\(alice.uuidString))"))
        #expect(!filter.contains(carol.uuidString))
    }

    @Test("Different pairs get different filters — order stability is not collapse")
    func differentPairsDiffer() {
        #expect(SupabaseBackend.pairFilter(alice, bob) != SupabaseBackend.pairFilter(alice, carol))
    }

    // MARK: Rows that concern me

    @Test("`friendships()` asks for rows on either end, and only mine")
    func rowsConcerningMe() {
        let filter = SupabaseBackend.rowsConcerning(alice)
        #expect(filter == "requester_id.eq.\(alice.uuidString),addressee_id.eq.\(alice.uuidString)")
        #expect(!filter.contains(bob.uuidString))
        #expect(SupabaseBackend.rowsConcerning(alice) != SupabaseBackend.rowsConcerning(bob))
    }

    // MARK: Answering

    @Test("Accepting is `accepted`; declining is `blocked`, not a deletion")
    func answeredStatusMapping() {
        #expect(SupabaseBackend.answeredStatus(accept: true) == .accepted)
        #expect(SupabaseBackend.answeredStatus(accept: false) == .blocked)
    }

    @Test("status and responded_at move together, and responded_at is set on both answers")
    func answerPayloadMovesBothColumns() throws {
        let when = Date(timeIntervalSince1970: 1_756_000_000)

        for accept in [true, false] {
            let payload = SupabaseBackend.answerPayload(accept: accept, at: when)
            #expect(Set(payload.keys) == ["status", "responded_at"])

            let status = try #require(payload["status"] ?? nil)
            #expect(status == SupabaseBackend.answeredStatus(accept: accept).rawValue)
            #expect(status != FriendshipStatus.pending.rawValue)

            // The DB's `friendships_responded_iff_answered`, client side: not
            // pending, therefore a timestamp, and one Postgres can read back.
            let stamp = try #require(payload["responded_at"] ?? nil)
            let parsed = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp)
            #expect(abs(parsed.timeIntervalSince(when)) < 0.01)
        }
    }

    @Test("A block insert carries the pair plus the same answered pair of columns")
    func blockInsertPayloadIsBlockedWithAStamp() throws {
        let when = Date(timeIntervalSince1970: 1_756_000_000)
        let payload = SupabaseBackend.blockInsertPayload(requester: alice, addressee: bob, at: when)

        #expect(Set(payload.keys) == ["requester_id", "addressee_id", "status", "responded_at"])
        #expect(payload["requester_id"] == alice.uuidString)
        #expect(payload["addressee_id"] == bob.uuidString)
        #expect(payload["status"] == FriendshipStatus.blocked.rawValue)
        #expect(try #require(payload["responded_at"] ?? nil).isEmpty == false)
    }

    @Test("The payload is JSON PostgREST can take: a string status and a string or null stamp")
    func answerPayloadEncodes() throws {
        let data = try BackendCoding.encoder.encode(
            SupabaseBackend.answerPayload(accept: true, at: Date(timeIntervalSince1970: 0))
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["status"] as? String == "accepted")
        #expect(object["responded_at"] is String)
    }

    // MARK: Decoding rows

    @Test("Zero rows is an empty list — a refused read is not an error")
    func zeroRowsIsEmpty() throws {
        #expect(try SupabaseBackend.friendships(fromRows: Data("[]".utf8)).isEmpty)
    }

    @Test("Zero rows through the single-row path is notFound, not a crash")
    func zeroRowsIsNotFound() {
        #expect(throws: BackendError.notFound) {
            _ = try SupabaseBackend.firstFriendship(fromRows: Data("[]".utf8))
        }
    }

    @Test("A pending row decodes with a null responded_at")
    func pendingRowDecodes() throws {
        let json = """
        [{
          "requester_id": "11111111-1111-4111-8111-111111111111",
          "addressee_id": "22222222-2222-4222-8222-222222222222",
          "status": "pending",
          "created_at": "2026-08-18T12:00:00.123456+00:00",
          "responded_at": null
        }]
        """
        let row = try SupabaseBackend.firstFriendship(fromRows: Data(json.utf8))
        #expect(row.requesterID == alice)
        #expect(row.addresseeID == bob)
        #expect(row.status == .pending)
        #expect(row.respondedAt == nil)
    }

    @Test("Both timestamp forms decode — `now()` is fractional, a whole second is not")
    func bothTimestampFormsDecode() throws {
        let json = """
        [{
          "requester_id": "11111111-1111-4111-8111-111111111111",
          "addressee_id": "22222222-2222-4222-8222-222222222222",
          "status": "accepted",
          "created_at": "2026-08-18T12:00:00Z",
          "responded_at": "2026-08-18T12:00:05.500000+00:00"
        },
        {
          "requester_id": "33333333-3333-4333-8333-333333333333",
          "addressee_id": "22222222-2222-4222-8222-222222222222",
          "status": "blocked",
          "created_at": "2026-08-18T12:00:00.250000+00:00",
          "responded_at": "2026-08-18T12:00:06Z"
        }]
        """
        let rows = try SupabaseBackend.friendships(fromRows: Data(json.utf8))
        #expect(rows.count == 2)
        #expect(rows[0].status == .accepted)
        #expect(try #require(rows[0].respondedAt).timeIntervalSince(rows[0].createdAt) == 5.5)
        #expect(rows[1].status == .blocked)
        #expect(try #require(rows[1].respondedAt).timeIntervalSince(rows[1].createdAt) == 5.75)
    }

    @Test("`other(than:)` reads the row from either end — the friends list's whole job")
    func otherEndOfTheRow() throws {
        let json = """
        [{
          "requester_id": "11111111-1111-4111-8111-111111111111",
          "addressee_id": "22222222-2222-4222-8222-222222222222",
          "status": "accepted",
          "created_at": "2026-08-18T12:00:00Z",
          "responded_at": "2026-08-18T12:00:05Z"
        }]
        """
        let row = try SupabaseBackend.firstFriendship(fromRows: Data(json.utf8))
        #expect(row.other(than: alice) == bob)
        #expect(row.other(than: bob) == alice)
        #expect(row.other(than: carol) == nil)
    }
}

/// The four criteria that only the real project can answer. They run against
/// the live database under `LiveProject`'s gate and are skipped — never
/// passed — without it.
@Suite("Supabase friendships, live project")
struct SupabaseFriendsLiveTests {

    @Test("Two users request and accept, and both sides see one accepted row",
          .enabled(if: LiveProject.isEnabled))
    func requestAndAcceptIsOneAcceptedRowOnBothSides() async throws {
        let requester = LiveProject.fresh()
        let addressee = LiveProject.fresh()
        let a = try await requester.signInAnonymously()
        let b = try await addressee.signInAnonymously()

        let pending = try await requester.requestFriend(addresseeID: b.id)
        #expect(pending.status == .pending)
        #expect(pending.respondedAt == nil)

        let accepted = try await addressee.respondToFriendRequest(requesterID: a.id, accept: true)
        #expect(accepted.status == .accepted)
        #expect(accepted.respondedAt != nil)

        for (reader, name) in [(requester, "requester"), (addressee, "addressee")] {
            let rows = try await reader.friendships()
            let pair = rows.filter { Set([$0.requesterID, $0.addresseeID]) == Set([a.id, b.id]) }
            #expect(pair.count == 1, "\(name) should see exactly one row for the pair")
            #expect(pair.first?.status == .accepted, "\(name) should see it accepted")
            #expect(pair.first?.respondedAt != nil, "\(name) should see responded_at stamped")
        }
    }

    @Test("A third user's friendships() contains nothing about that pair",
          .enabled(if: LiveProject.isEnabled))
    func aStrangerSeesNoneOfIt() async throws {
        let requester = LiveProject.fresh()
        let addressee = LiveProject.fresh()
        let stranger = LiveProject.fresh()
        let a = try await requester.signInAnonymously()
        let b = try await addressee.signInAnonymously()
        _ = try await stranger.signInAnonymously()

        _ = try await requester.requestFriend(addresseeID: b.id)
        _ = try await addressee.respondToFriendRequest(requesterID: a.id, accept: true)

        // A refused read is zero rows, not an error: the stranger's call
        // succeeds and simply says nothing about someone else's pair.
        let rows = try await stranger.friendships()
        #expect(rows.allSatisfy { Set([$0.requesterID, $0.addresseeID]) != Set([a.id, b.id]) },
                "stranger must see zero rows for that pair")
    }

    @Test("A second request for the same pair is alreadyExists, from either direction",
          .enabled(if: LiveProject.isEnabled))
    func aDuplicateRequestIsAlreadyExists() async throws {
        let requester = LiveProject.fresh()
        let addressee = LiveProject.fresh()
        let a = try await requester.signInAnonymously()
        let b = try await addressee.signInAnonymously()

        _ = try await requester.requestFriend(addresseeID: b.id)

        await #expect(throws: BackendError.alreadyExists, "same direction") {
            _ = try await requester.requestFriend(addresseeID: b.id)
        }
        await #expect(throws: BackendError.alreadyExists, "reversed direction") {
            _ = try await addressee.requestFriend(addresseeID: a.id)
        }
        #expect(try await requester.friendships()
            .filter { Set([$0.requesterID, $0.addresseeID]) == Set([a.id, b.id]) }.count == 1)
    }

    @Test("Responding to a request that does not exist is notFound",
          .enabled(if: LiveProject.isEnabled))
    func respondingToNothingIsNotFound() async throws {
        let addressee = LiveProject.fresh()
        let stranger = LiveProject.fresh()
        _ = try await addressee.signInAnonymously()
        let other = try await stranger.signInAnonymously()

        await #expect(throws: BackendError.notFound, "no row at all") {
            _ = try await addressee.respondToFriendRequest(requesterID: other.id, accept: true)
        }
    }
}
