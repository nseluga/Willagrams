//
//  SupabaseBackend+Friends.swift
//  Willagrams
//
//  Friendships against `public.friendships`, under the policies in
//  `0001_init.sql` and nothing else. The semantics are the ones `FakeBackend`
//  already pins, so the two implementations answer a test the same way.
//
//  The one-row-per-unordered-pair rule is `friendships_pair_idx`'s job, not
//  this file's: `requestFriend` inserts and lets the index reject the
//  duplicate. There is no pre-scan, because a pre-scan is a race that reads
//  like a guarantee.
//

import Foundation
import PostgREST

extension SupabaseBackend {

    // MARK: - Reads

    public func friendships() async throws -> [Friendship] {
        guard let me = currentUserID else { throw BackendError.notAuthenticated }
        let rows = try await mapping {
            try await rest.from("friendships")
                .select()
                .or(Self.rowsConcerning(me))
                .execute()
                .data
        }
        return try Self.friendships(fromRows: rows)
    }

    // MARK: - Writes

    public func requestFriend(addresseeID: UUID) async throws -> Friendship {
        guard let me = currentUserID else { throw BackendError.notAuthenticated }
        guard addresseeID != me else { throw BackendError.permissionDenied }

        do {
            let rows = try await mapping {
                try await rest.from("friendships")
                    .insert(
                        [
                            "requester_id": me.uuidString,
                            "addressee_id": addresseeID.uuidString,
                            "status": FriendshipStatus.pending.rawValue,
                        ],
                        returning: .representation
                    )
                    .execute()
                    .data
            }
            return try Self.firstFriendship(fromRows: rows)
        } catch BackendError.alreadyExists {
            // `friendships_pair_idx` refused it, so a row for this pair exists
            // in one direction or the other. Only now is it worth a read, and
            // only to tell "already friends" from "blocked" — the uniqueness
            // itself was decided by the index, above.
            if try await existingPair(me, addresseeID)?.status == .blocked {
                throw BackendError.blocked
            }
            throw BackendError.alreadyExists
        }
    }

    public func respondToFriendRequest(requesterID: UUID, accept: Bool) async throws -> Friendship {
        guard let me = currentUserID else { throw BackendError.notAuthenticated }

        // `status = pending` in the filter is what stamps `responded_at`
        // exactly once: a second answer matches no row and never writes.
        let rows = try await mapping {
            try await rest.from("friendships")
                .update(Self.answerPayload(accept: accept, at: Date()), returning: .representation)
                .eq("requester_id", value: requesterID.uuidString)
                .eq("addressee_id", value: me.uuidString)
                .eq("status", value: FriendshipStatus.pending.rawValue)
                .execute()
                .data
        }
        if let answered = try Self.friendships(fromRows: rows).first { return answered }

        // Zero rows is ambiguous on its own: no such request, or one that was
        // already answered. Only this branch pays for the extra read.
        let existing = try await mapping {
            try await rest.from("friendships")
                .select()
                .eq("requester_id", value: requesterID.uuidString)
                .eq("addressee_id", value: me.uuidString)
                .limit(1)
                .execute()
                .data
        }
        let openRequestExists = try !Self.friendships(fromRows: existing).isEmpty
        throw openRequestExists ? BackendError.alreadyExists : BackendError.notFound
    }

    public func block(_ playerID: UUID) async throws -> Friendship {
        guard let me = currentUserID else { throw BackendError.notAuthenticated }
        guard playerID != me else { throw BackendError.permissionDenied }

        if let blocked = try await blockExistingPair(me, playerID) { return blocked }
        do {
            let rows = try await mapping {
                try await rest.from("friendships")
                    .insert(
                        Self.blockInsertPayload(requester: me, addressee: playerID, at: Date()),
                        returning: .representation
                    )
                    .execute()
                    .data
            }
            return try Self.firstFriendship(fromRows: rows)
        } catch BackendError.alreadyExists {
            // Someone created the pair between the update and the insert. The
            // row is there now, so the update that found nothing will find it.
            guard let blocked = try await blockExistingPair(me, playerID) else {
                throw BackendError.alreadyExists
            }
            return blocked
        }
    }

    // MARK: - Helpers

    /// The pair's single row set to `blocked`, or nil when no row exists yet.
    /// Written in either direction, because the pair — not the direction — is
    /// what is unique.
    private func blockExistingPair(_ me: UUID, _ them: UUID) async throws -> Friendship? {
        let rows = try await mapping {
            try await rest.from("friendships")
                .update(Self.answerPayload(accept: false, at: Date()), returning: .representation)
                .or(Self.pairFilter(me, them))
                .execute()
                .data
        }
        return try Self.friendships(fromRows: rows).first
    }

    private func existingPair(_ a: UUID, _ b: UUID) async throws -> Friendship? {
        let rows = try await mapping {
            try await rest.from("friendships")
                .select()
                .or(Self.pairFilter(a, b))
                .limit(1)
                .execute()
                .data
        }
        return try Self.friendships(fromRows: rows).first
    }

    // MARK: - Pure parts

    /// "This row concerns this unordered pair", as a PostgREST `or` filter.
    ///
    /// The ends are sorted before they are written, so the two argument orders
    /// produce the *same string* rather than merely an equivalent one — the
    /// same thing `friendships_pair_idx` does with `least`/`greatest`.
    static func pairFilter(_ a: UUID, _ b: UUID) -> String {
        let ends = [a.uuidString, b.uuidString].sorted()
        return "and(requester_id.eq.\(ends[0]),addressee_id.eq.\(ends[1]))"
            + ",and(requester_id.eq.\(ends[1]),addressee_id.eq.\(ends[0]))"
    }

    /// "This row concerns me", for `friendships()`. RLS already restricts the
    /// answer to these rows; the filter is what keeps the query indexed instead
    /// of making the policy scan the table.
    static func rowsConcerning(_ me: UUID) -> String {
        "requester_id.eq.\(me.uuidString),addressee_id.eq.\(me.uuidString)"
    }

    /// Declining is not "no", it is a block — the same choice `FakeBackend`
    /// makes, so a declined request cannot be re-sent by the other side.
    static func answeredStatus(accept: Bool) -> FriendshipStatus {
        accept ? .accepted : .blocked
    }

    /// `status` and `responded_at` in one payload, so they can never be written
    /// apart. `friendships_responded_iff_answered` rejects the split anyway;
    /// this is the client-side half of the same biconditional.
    static func answerPayload(accept: Bool, at date: Date) -> [String: String?] {
        payload(status: answeredStatus(accept: accept), at: date)
    }

    static func blockInsertPayload(requester: UUID, addressee: UUID, at date: Date) -> [String: String?] {
        payload(status: .blocked, at: date)
            .merging([
                "requester_id": requester.uuidString,
                "addressee_id": addressee.uuidString,
            ]) { current, _ in current }
    }

    private static func payload(status: FriendshipStatus, at date: Date) -> [String: String?] {
        [
            "status": status.rawValue,
            "responded_at": status == .pending ? nil : timestamp.format(date),
        ]
    }

    /// The same form `BackendCoding.encoder` writes. Postgres reads either, but
    /// two spellings of one timestamp in one client is a bug waiting to be read
    /// as a rounding difference.
    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Zero rows is `[]`, never a throw: PostgREST answers a filter nobody
    /// matches — including one a policy refused — with an empty array.
    static func friendships(fromRows data: Data) throws -> [Friendship] {
        try BackendCoding.decoder.decode([Friendship].self, from: data)
    }

    static func firstFriendship(fromRows data: Data) throws -> Friendship {
        guard let friendship = try friendships(fromRows: data).first else {
            throw BackendError.notFound
        }
        return friendship
    }
}
