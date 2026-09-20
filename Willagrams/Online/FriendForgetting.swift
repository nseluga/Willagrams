//
//  FriendForgetting.swift
//  Willagrams
//
//  One protocol, in its own SDK-free file for the reason
//  `FriendRequestForgetting.swift` gives: every test package compiles this
//  seam, and most of them cannot compile `SupabaseBackend+Friends.swift`,
//  which imports PostgREST.
//

import Foundation

/// Unfriending: forgetting an accepted friendship outright.
///
/// Declared here rather than on `BackendClient` for the reason
/// ``FriendRequestForgetting`` is: `BackendContracts.swift` is the protected
/// wire contract, and this is one screen's need.
///
/// `friendships_delete_own` lets either end delete a row of *any* status, so
/// the accepted-only filter lives in every implementation. It is the only
/// thing that keeps an unfriend from lifting a block.
public protocol FriendForgetting: Sendable {
    /// Deletes the `accepted` row between the signed-in user and `friendID`,
    /// whichever end asked. Throws `BackendError.notFound` where there is no
    /// such row — a pending or blocked pair included — so an unfriend that hit
    /// nothing cannot read as one that landed.
    func unfriend(_ friendID: UUID) async throws
}
