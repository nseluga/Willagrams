import Foundation
import Testing
@testable import Online

/// Unfriend against the real project. `friendships_delete_own` allows deleting a
/// row of any status, so this is the one place that proves the Swift-side
/// `status = accepted` filter is what keeps a block alive.
@Suite("Unfriend, live project")
struct LiveUnfriendTests {

    @Test("Unfriend deletes an accepted row and never a blocked one", .enabled(if: LiveProject.isEnabled))
    func unfriendDeletesOnlyAccepted() async throws {
        let a = LiveProject.fresh()
        let b = LiveProject.fresh()
        let pa = try await a.signInAnonymously()
        let pb = try await b.signInAnonymously()

        // Accepted, then unfriended: the row is gone from both ends.
        _ = try await a.requestFriend(addresseeID: pb.id)
        _ = try await b.respondToFriendRequest(requesterID: pa.id, accept: true)
        try await a.unfriend(pb.id)
        #expect(try await a.friendships().isEmpty)
        #expect(try await b.friendships().isEmpty)

        // Same pair, now blocked. Neither end's unfriend may lift it.
        _ = try await a.requestFriend(addresseeID: pb.id)
        _ = try await b.block(pa.id)
        await #expect(throws: BackendError.notFound) { try await a.unfriend(pb.id) }
        await #expect(throws: BackendError.notFound) { try await b.unfriend(pa.id) }

        let rows = try await a.friendships()
        #expect(rows.count == 1 && rows.first?.status == .blocked, "the block did not survive: \(rows)")

        // Cleanup, bypassing the filter on purpose.
        _ = try await b.rest.from("friendships")
            .delete()
            .or(SupabaseBackend.pairFilter(pa.id, pb.id))
            .execute()
    }
}
