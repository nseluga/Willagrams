//
//  FriendRequestForgetting.swift
//  Willagrams
//
//  One protocol, in its own SDK-free file for the reason `MatchAbandoning`
//  lives in `OnlineMatch.swift`: every test package compiles this seam, and
//  most of them cannot compile `SupabaseBackend+Friends.swift`, which imports
//  PostgREST. Declaring it beside the real client would put it out of reach of
//  `FakeBackend` in exactly those packages.
//

import Foundation

/// Forgetting an incoming friend request outright.
///
/// Declared here rather than on `BackendClient` for the reason
/// ``MatchAbandoning`` is: `BackendContracts.swift` is the protected wire
/// contract, and this is one screen's need, not a new obligation on every
/// backend a future lane writes.
///
/// It exists because `respondToFriendRequest(requesterID:accept:)` has only two
/// answers, and its "no" is `blocked` — permanent, silent, and with no undo.
/// A decline should mean "not now", so it deletes the row and lets the other
/// player ask again. Blocking stays a separate, explicit button.
public protocol FriendRequestForgetting: Sendable {
    /// Deletes the pending row `requesterID` addressed to the signed-in user.
    /// Throws `BackendError.notFound` where there is no such request, so a
    /// decline that hit nothing cannot read as one that landed.
    func forgetFriendRequest(requesterID: UUID) async throws
}
