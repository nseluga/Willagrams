#if canImport(Match)
import Match
#endif

import Foundation
import Observation

// NO SwiftUI in this directory except in a file named in the `Account` target's
// `exclude:` list in `Tests/AccountTests/Package.swift` *and* in
// `Tests/ShellTests/Package.swift` — both symlink this directory whole and both
// build for macOS. `SourceGuardrailTests` in AccountTests fails first and says
// so.
//
// NO navigation either: this screen never learns that routes exist. It reports
// back through the closures its owner hands it, and `ShellModel` decides where
// that goes.

/// One `label — value` line of the stats table, as the row's own copy.
///
/// A value, not a view: `StatRow` is SwiftUI and cannot be built in a macOS
/// test, so what the screen *says* is decided here and only the drawing is
/// left to ``ProfileView``.
public struct ProfileStat: Hashable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// The profile screen: one `Profile` row, rendered, and — when this is the
/// local player — the one field on it that can be edited.
///
/// It renders *any* profile, not only the signed-in one. `isEditable` is the
/// only difference between the local screen and a friend's, so item 9 reuses
/// this type read-only rather than copying it.
@MainActor
@Observable
public final class ProfileModel {

    /// The row as read. Replaced wholesale by whatever `updateDisplayName`
    /// returns, so nothing on screen is ever a locally-guessed value.
    public private(set) var profile: Profile

    /// Whether the name field is offered at all. False for anyone but the
    /// signed-in player.
    public let isEditable: Bool

    /// What the player has typed. Not written back to ``profile`` until the
    /// backend confirms it.
    public var draftName: String

    /// One line under the field: a refusal, a failure, or a confirmation.
    public private(set) var message: String?

    /// True while `save()` is in flight, so the view shows a pending state it
    /// did not have to infer.
    public private(set) var isSaving = false

    /// True once the code has been copied this visit. The view reads it; it
    /// decides nothing.
    public private(set) var didCopyCode = false

    @ObservationIgnored private let backend: (any BackendClient)?
    @ObservationIgnored private let pasteboard: @MainActor (String) -> Void

    public init(
        profile: Profile,
        isEditable: Bool,
        backend: (any BackendClient)? = nil,
        pasteboard: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.profile = profile
        self.isEditable = isEditable
        self.backend = backend
        self.pasteboard = pasteboard
        self.draftName = profile.displayName
    }

    // MARK: - Stats

    /// The four numbers on the row, as they are stored.
    ///
    /// Nothing is derived: no win rate, no average, no total. Every value here
    /// is one column of `profiles` formatted, because a number the client works
    /// out is a number that can disagree with the database that ranks it.
    public var stats: [ProfileStat] {
        [
            ProfileStat(label: Self.matchesPlayedLabel, value: String(profile.matchesPlayed)),
            ProfileStat(label: Self.matchesWonLabel, value: String(profile.matchesWon)),
            ProfileStat(label: Self.tilesPlacedLabel, value: String(profile.tilesPlaced)),
            ProfileStat(
                label: Self.fastestWinLabel,
                value: profile.fastestWinSeconds.map { "\($0)s" } ?? Self.noValue
            ),
        ]
    }

    // MARK: - The name

    /// The draft with its edges trimmed — what would actually be sent.
    public var trimmedDraft: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether ``save()`` would reach the backend. The same 1–24 the
    /// `display_name` column checks, asked here so a refusal costs no round
    /// trip and the field can disable its own button.
    public var canSave: Bool {
        isEditable && Self.nameLength.contains(trimmedDraft.count) && !isSaving
    }

    /// Sends the draft, and adopts whatever comes back.
    ///
    /// A draft outside 1–24 returns before any call is made: the column check is
    /// the last line of defence, not the first.
    public func save() async {
        guard isEditable, let backend else { return }
        let name = trimmedDraft
        guard Self.nameLength.contains(name.count) else {
            message = Self.nameLengthMessage
            return
        }

        isSaving = true
        defer { isSaving = false }
        do {
            profile = try await backend.updateDisplayName(name)
            draftName = profile.displayName
            message = Self.savedMessage
        } catch {
            // Deliberately one line rather than a second `BackendError` switch:
            // `HostLobbyModel.message(for:)` is the shared mapping and every
            // case of it is worded for a match, not for a name.
            message = Self.saveFailedMessage
        }
    }

    // MARK: - The friend code

    public func copyFriendCode() {
        pasteboard(profile.friendCode)
        didCopyCode = true
    }

    /// What the share sheet sends. Built here so the view carries no copy.
    public var shareMessage: String {
        "\(Self.shareLead) \(profile.friendCode)"
    }

    // MARK: - Copy

    /// Screen chrome, declared local to the screen that uses it — `Terminology`
    /// names game concepts, and none of these is one.
    public static let title = "Profile"
    public static let nameLabel = "Display name"
    public static let friendCodeLabel = "Friend code"
    public static let saveLabel = "Save"
    public static let copyLabel = "Copy"
    public static let copiedLabel = "Copied"
    public static let shareLabel = "Share"
    public static let backLabel = "Done"
    public static let matchesPlayedLabel = "Matches played"
    public static let matchesWonLabel = "Matches won"
    public static let tilesPlacedLabel = "Tiles placed"
    public static let fastestWinLabel = "Fastest win"
    public static let noValue = "—"
    public static let shareLead = "Add me on Willagrams — my friend code is"
    public static let nameLengthMessage = "A name is 1 to 24 characters."
    public static let saveFailedMessage = "Couldn't save that name. Try again."
    public static let savedMessage = "Saved."

    /// What the `display_name` column allows, mirrored client-side.
    public static let nameLength = 1...24
}
