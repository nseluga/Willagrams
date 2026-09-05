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

    /// The *row*, not the player: a pair can hold more than one row and two
    /// entries sharing a counterpart must still be two rows in a `ForEach`.
    public var id: String { "\(friendship.requesterID)|\(friendship.addresseeID)" }

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

    /// The signed-in player — the whole row, not just the id.
    ///
    /// Every friendship is read from their end, which is what tells an incoming
    /// request from an outgoing one; and their own `friendCode` is what lets
    /// ``lookup(code:)`` refuse itself without a round trip. An id alone could
    /// not answer that question without asking the backend who the code belongs
    /// to, which is the one call the refusal exists to avoid.
    @ObservationIgnored private let me: Profile

    /// The signed-in player's id. Named apart from ``me`` so the section rules
    /// below read the same as they did when `me` was the id.
    private var myID: UUID { me.id }
    @ObservationIgnored private let backend: any BackendClient

    /// Counterparts already resolved, for the life of this screen. An action
    /// re-reads every row, and re-reading a row must not re-read a name that has
    /// not changed since the screen opened.
    @ObservationIgnored private var profiles: [UUID: Profile] = [:]

    /// Loads and actions in flight. `isLoading` is "any of them", so a load
    /// finishing while another runs does not put the spinner away.
    @ObservationIgnored private var inFlight = 0

    /// Bumped by every load; only the newest one publishes. Two overlapping
    /// loads can finish in either order, and the older one's sections are stale
    /// whichever order that is.
    @ObservationIgnored private var generation = 0

    /// How many counterpart profiles are read at once. Bounded because a long
    /// list would otherwise open one connection per friend.
    private static let profileFetchLimit = 8

    public init(me: Profile, backend: any BackendClient) {
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
        generation += 1
        let mine = generation
        begin()
        defer { end() }

        let rows: [Friendship]
        do {
            rows = try await backend.friendships()
        } catch {
            // Same guard as the publish below, for the same reason: a load that
            // has been cancelled or overtaken owns nothing on this screen, and
            // its failure must not stamp an error over sections a newer load
            // just published correctly.
            guard !Task.isCancelled, generation == mine else { return }
            message = Self.loadFailedMessage
            return
        }

        var placed: [(section: Section, row: Friendship, them: UUID)] = []

        for row in rows {
            // One place decides where a row goes, including nowhere. A second
            // `status != .blocked` guard above this would make the `.blocked`
            // arm dead code, and dead code is a rule no test can break.
            let section: Section?
            switch (row.status, row.requesterID == myID) {
            case (.accepted, _): section = .accepted
            case (.pending, true): section = .outgoing
            case (.pending, false): section = .incoming
            case (.blocked, _): section = nil
            }

            guard let section, let them = row.other(than: myID) else { continue }
            placed.append((section, row, them))
        }

        // Every counterpart this screen has not seen yet, once each and in
        // parallel — one round trip per row, in series, is what makes a list of
        // twenty friends feel like a list of twenty loads.
        let unresolved = Set(placed.map(\.them)).subtracting(profiles.keys)
        let (fetched, failures) = await Self.fetch(unresolved, from: backend)

        // Kept even by a load that is about to lose: a `Profile` is keyed by id
        // and says nothing about which load read it, so throwing these away
        // would only make the winner pay for the same reads again.
        profiles.merge(fetched) { _, new in new }

        // Nothing below this line runs for a load that has been cancelled or
        // overtaken: a cancelled load's rows are truncated and an overtaken
        // one's are stale, and either would be assigned over good sections.
        guard !Task.isCancelled, generation == mine else { return }

        var accepted: [FriendEntry] = []
        var incoming: [FriendEntry] = []
        var outgoing: [FriendEntry] = []

        for item in placed {
            // A counterpart whose profile cannot be read is dropped rather than
            // failing the whole list: one unreadable row must not empty a
            // screen that has ten good ones on it. It is said out loud, though
            // — a friend silently missing is worse than a slow one.
            guard let profile = profiles[item.them] else { continue }
            let entry = FriendEntry(profile: profile, friendship: item.row)
            switch item.section {
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
        message = failures > 0 ? Self.partialLoadMessage : nil
    }

    /// Reads `ids` through the seam, `profileFetchLimit` at a time, and reports
    /// how many could not be read.
    private static func fetch(
        _ ids: Set<UUID>,
        from backend: any BackendClient
    ) async -> (profiles: [UUID: Profile], failures: Int) {
        let ids = Array(ids)
        var profiles: [UUID: Profile] = [:]
        var failures = 0

        await withTaskGroup(of: (UUID, Profile?).self) { group in
            var next = 0
            func addNext() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask { (id, try? await backend.profile(id: id)) }
            }
            for _ in 0..<min(Self.profileFetchLimit, ids.count) { addNext() }
            while let (id, profile) = await group.next() {
                if let profile { profiles[id] = profile } else { failures += 1 }
                addNext()
            }
        }
        return (profiles, failures)
    }

    private func begin() {
        inFlight += 1
        isLoading = true
    }

    private func end() {
        inFlight -= 1
        if inFlight == 0 { isLoading = false }
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
    @discardableResult
    private func perform(
        failure: String,
        map: (any Error) -> String? = { _ in nil },
        _ write: (any BackendClient) async throws -> Void
    ) async -> Bool {
        // Held across the write *and* its reload, so the spinner never blinks
        // off between the two and the empty state never flashes in the gap.
        begin()
        defer { end() }
        do {
            try await write(backend)
        } catch {
            // The mapper gets first refusal so a seam error the screen has real
            // words for is not flattened into the generic line.
            message = map(error) ?? failure
            return false
        }
        await load()
        return true
    }


    // MARK: - Adding by code

    /// What the code field holds, always normalized. Private setter because the
    /// clamp is the model's rule: a view that could assign a raw string would be
    /// a second, looser copy of it.
    public private(set) var lookupCode = ""

    /// The player the last lookup found, or nil. The view draws a result row off
    /// this and decides nothing about whether there is one.
    public private(set) var lookupResult: Profile?

    /// Bumped by every lookup, for the reason ``generation`` is bumped by every
    /// load: two overlapping lookups can finish in either order and the older
    /// one's answer is stale whichever order that is.
    @ObservationIgnored private var lookupGeneration = 0

    /// How many characters a friend code is. The same eight the `profiles`
    /// column holds and the same eight the backend matches on.
    public static let codeLength = 8

    /// A typed code as the backend would see it: uppercase, `A–Z0–9` only, and
    /// no longer than a code. Pure, so the field and ``lookup(code:)`` cannot
    /// clamp differently.
    public static func normalize(_ raw: String) -> String {
        String(
            raw.uppercased()
                .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                .prefix(codeLength)
        )
    }

    /// What the field's binding writes through, so the clamp lives here.
    public func setLookupCode(_ raw: String) {
        lookupCode = Self.normalize(raw)
    }

    /// Whether ``lookup(code:)`` would reach the backend at all. Asked here so
    /// the button can disable itself without holding the rule.
    public var canLookup: Bool { lookupCode.count == Self.codeLength }

    /// Looks a stranger up by the code they gave you.
    ///
    /// The player's own code is refused *before* the seam is touched: asking the
    /// backend who owns a code this model already holds would be a round trip
    /// whose answer is known, and a request that followed it would be refused by
    /// the database anyway.
    public func lookup(code raw: String) async {
        let code = Self.normalize(raw)
        lookupCode = code
        lookupResult = nil

        guard code.count == Self.codeLength else {
            message = Self.codeLengthMessage
            return
        }
        guard code != Self.normalize(me.friendCode) else {
            message = Self.ownCodeMessage
            return
        }

        lookupGeneration += 1
        let mine = lookupGeneration
        begin()
        defer { end() }

        do {
            let found = try await backend.profile(friendCode: code)
            guard !Task.isCancelled, lookupGeneration == mine else { return }
            lookupResult = found
            message = found == nil ? Self.noSuchCodeMessage : nil
        } catch {
            // Same guard as the publish above, and for the same reason: an
            // overtaken lookup's failure must not stamp an error over a result a
            // newer one just published.
            guard !Task.isCancelled, lookupGeneration == mine else { return }
            message = Self.lookupFailedMessage
        }
    }

    /// Asks `profile` to be friends, then re-reads the sections.
    ///
    /// Refuses the local player without a call, on the same terms
    /// ``lookup(code:)`` does — a player cannot be their own friend, and the
    /// only thing asking would buy is a round trip to be told so.
    public func request(_ profile: Profile) async {
        guard profile.id != myID else {
            message = Self.ownCodeMessage
            return
        }
        let sent = await perform(failure: Self.requestFailedMessage, map: Self.requestMessage(for:)) {
            _ = try await $0.requestFriend(addresseeID: profile.id)
        }
        // Cleared only on success: a refused request leaves the row up, with the
        // reason beside it, so the player is not left retyping a code to find
        // out what happened.
        guard sent else { return }
        lookupResult = nil
        lookupCode = ""
    }

    /// The two seam refusals this screen has real words for. Everything else is
    /// the generic line — a player cannot act on an RLS refusal.
    public static func requestMessage(for error: any Error) -> String? {
        switch error as? BackendError {
        case .alreadyExists: alreadyKnownMessage
        case .blocked: blockedMessage
        default: nil
        }
    }

    // MARK: - Copy

    /// Screen chrome, declared local to the screen that uses it — `Terminology`
    /// names game concepts, and none of these is one.
    public static let title = "Friends"
    public static let acceptedSectionTitle = "Friends"
    public static let incomingSectionTitle = "Wants to be friends"
    public static let outgoingSectionTitle = "Asked"
    public static let acceptLabel = "Accept"
    /// Says what it does. The seam answers a decline with a block, so a button
    /// reading "Decline" would be the one word that hides the only irreversible
    /// thing on this screen.
    public static let declineLabel = "Decline & block"
    public static let declineFootnote = "Declining blocks that player. It can't be undone here."
    public static let blockLabel = "Block"
    /// Only ever drawn on an accepted row — the screen passes it to that one
    /// section, so a pending row cannot render it.
    public static let invitePlayLabel = "Invite to play"
    public static let backLabel = "Done"
    public static let emptyMessage = "No friends yet. Share your friend code to add one."
    public static let loadFailedMessage = "Couldn't load your friends. Try again."
    public static let partialLoadMessage = "Some friends couldn't be loaded. Try again."
    public static let acceptFailedMessage = "Couldn't accept that request. Try again."
    public static let declineFailedMessage = "Couldn't decline that request. Try again."
    public static let blockFailedMessage = "Couldn't block that player. Try again."
    public static let addSectionTitle = "Add a friend"
    public static let codeFieldLabel = "Friend code"
    public static let codeFieldPrompt = "8 characters"
    public static let lookupLabel = "Look up"
    public static let requestLabel = "Request"
    public static let codeLengthMessage = "A friend code is 8 characters."
    public static let ownCodeMessage = "That's your own friend code."
    public static let noSuchCodeMessage = "No player has that friend code."
    public static let lookupFailedMessage = "Couldn't look up that code. Try again."
    public static let requestFailedMessage = "Couldn't send that request. Try again."
    public static let alreadyKnownMessage = "You've already asked that player, or you're already friends."
    public static let blockedMessage = "You can't add that player."

    /// Whether the screen has nothing at all to draw — asked here so the view
    /// holds no branch of its own.
    public var isEmpty: Bool { accepted.isEmpty && incoming.isEmpty && outgoing.isEmpty }
}
