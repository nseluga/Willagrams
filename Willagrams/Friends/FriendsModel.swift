#if canImport(Match)
import Match
#endif

import Foundation
import Observation

// NO SwiftUI in this directory except in a file named in the `Friends` target's
// `exclude:` list in `Tests/FriendsTests/Package.swift` *and* in
// `Tests/ShellTests/Package.swift` — both symlink this directory whole and both
// build for macOS. `SourceGuardrailTests` in FriendsTests fails first and says
// so.
//
// NO navigation either: this screen never learns that routes exist. It reports
// back through the closures its owner hands it, and `ShellModel` decides where
// that goes.

/// One counterpart, with the row that put them in a section.
///
/// The `Profile` and the `Friendship` travel together because every action on
/// this screen needs both: the row says who asked, the profile says what to
/// draw.
public struct FriendEntry: Identifiable, Sendable, Equatable {

    /// The *other* player — never the signed-in one.
    public let profile: Profile
    public let friendship: Friendship

    public var id: UUID { profile.id }

    public init(profile: Profile, friendship: Friendship) {
        self.profile = profile
        self.friendship = friendship
    }
}

/// The friends list: who you play with, who has asked, and who you have asked.
///
/// Three published sections rather than one list with a status on each row, so
/// the view draws what it is given and decides nothing. Every section is derived
/// from `friendships()` on each load and never patched in place — a status this
/// client worked out is a status that can disagree with the database the RLS
/// policies rank it by.
@MainActor
@Observable
public final class FriendsModel {

    /// Friendships both ends have agreed to.
    public private(set) var accepted: [FriendEntry] = []

    /// Requests waiting on *this* player's answer.
    public private(set) var incoming: [FriendEntry] = []

    /// Requests this player sent that nobody has answered yet.
    public private(set) var outgoing: [FriendEntry] = []

    /// True while a load or an action is in flight, so the view shows a pending
    /// state it did not have to infer.
    public private(set) var isLoading = false

    /// One line saying why the last thing failed, or nil.
    public private(set) var message: String?

    /// The signed-in player. Every row is read from their end — which side of
    /// `Friendship` they are on is what tells an incoming request from an
    /// outgoing one.
    @ObservationIgnored private let me: UUID
    @ObservationIgnored private let backend: any BackendClient

    public init(me: UUID, backend: any BackendClient) {
        self.me = me
        self.backend = backend
    }

    /// Which list a row belongs to. `nil` — not a fourth case — is how a
    /// blocked row is hidden, so "appears nowhere" is one answer of the same
    /// decision rather than a filter somewhere else.
    private enum Section { case accepted, incoming, outgoing }

    // MARK: - Loading

    /// Re-reads every friendship and re-derives the three sections.
    ///
    /// Blocked rows are dropped before anything else: a blocked player is not a
    /// friend, not a request and not an invite, so they appear in no section in
    /// either direction — whether this player blocked them or they blocked this
    /// player.
    public func load() async {
        isLoading = true
        defer { isLoading = false }

        let rows: [Friendship]
        do {
            rows = try await backend.friendships()
        } catch {
            message = Self.loadFailedMessage
            return
        }

        var accepted: [FriendEntry] = []
        var incoming: [FriendEntry] = []
        var outgoing: [FriendEntry] = []

        for row in rows {
            // One place decides where a row goes, including nowhere. A second
            // `status != .blocked` guard above this would make the `.blocked`
            // arm dead code, and dead code is a rule no test can break.
            let section: Section?
            switch (row.status, row.requesterID == me) {
            case (.accepted, _): section = .accepted
            case (.pending, true): section = .outgoing
            case (.pending, false): section = .incoming
            case (.blocked, _): section = nil
            }

            guard let section, let them = row.other(than: me) else { continue }
            // A counterpart whose profile cannot be read is dropped rather than
            // failing the whole list: one unreadable row must not empty a
            // screen that has ten good ones on it.
            guard let profile = try? await backend.profile(id: them) else { continue }

            let entry = FriendEntry(profile: profile, friendship: row)
            switch section {
            case .accepted: accepted.append(entry)
            case .incoming: incoming.append(entry)
            case .outgoing: outgoing.append(entry)
            }
        }

        // Ordered by name so the list does not reshuffle between loads: rows
        // come back in whatever order the query gave them.
        self.accepted = accepted.sorted(by: Self.byName)
        self.incoming = incoming.sorted(by: Self.byName)
        self.outgoing = outgoing.sorted(by: Self.byName)
        message = nil
    }

    private static func byName(_ a: FriendEntry, _ b: FriendEntry) -> Bool {
        (a.profile.displayName, a.profile.id.uuidString)
            < (b.profile.displayName, b.profile.id.uuidString)
    }

    // MARK: - Answering

    /// Accepts an incoming request. The section it moves to is whatever the
    /// reload says it is.
    public func accept(_ entry: FriendEntry) async {
        await respond(to: entry, accept: true, failure: Self.acceptFailedMessage)
    }

    /// Declines an incoming request. The backend's answer to a decline is a
    /// block, in both implementations — that is the seam's semantics, not a
    /// choice made here.
    public func decline(_ entry: FriendEntry) async {
        await respond(to: entry, accept: false, failure: Self.declineFailedMessage)
    }

    public func block(_ entry: FriendEntry) async {
        await perform(failure: Self.blockFailedMessage) {
            _ = try await $0.block(entry.profile.id)
        }
    }

    private func respond(to entry: FriendEntry, accept: Bool, failure: String) async {
        await perform(failure: failure) {
            _ = try await $0.respondToFriendRequest(
                requesterID: entry.friendship.requesterID,
                accept: accept
            )
        }
    }

    /// One write through the seam, then a full re-read.
    ///
    /// The re-read is the whole point: nothing here edits a `Friendship` it is
    /// holding, so the sections after an action are the database's answer rather
    /// than this client's guess at it.
    private func perform(
        failure: String,
        _ write: (any BackendClient) async throws -> Void
    ) async {
        isLoading = true
        do {
            try await write(backend)
        } catch {
            isLoading = false
            message = failure
            return
        }
        isLoading = false
        await load()
    }

    // MARK: - Copy

    /// Screen chrome, declared local to the screen that uses it — `Terminology`
    /// names game concepts, and none of these is one.
    public static let title = "Friends"
    public static let acceptedSectionTitle = "Friends"
    public static let incomingSectionTitle = "Wants to be friends"
    public static let outgoingSectionTitle = "Asked"
    public static let acceptLabel = "Accept"
    public static let declineLabel = "Decline"
    public static let blockLabel = "Block"
    public static let backLabel = "Done"
    public static let emptyMessage = "No friends yet. Share your friend code to add one."
    public static let loadFailedMessage = "Couldn't load your friends. Try again."
    public static let acceptFailedMessage = "Couldn't accept that request. Try again."
    public static let declineFailedMessage = "Couldn't decline that request. Try again."
    public static let blockFailedMessage = "Couldn't block that player. Try again."

    /// Whether the screen has nothing at all to draw — asked here so the view
    /// holds no branch of its own.
    public var isEmpty: Bool { accepted.isEmpty && incoming.isEmpty && outgoing.isEmpty }
}
