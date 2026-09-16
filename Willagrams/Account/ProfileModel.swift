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
    @ObservationIgnored private let onSaved: @MainActor (Profile) -> Void

    public init(
        profile: Profile,
        isEditable: Bool,
        backend: (any BackendClient)? = nil,
        pasteboard: @escaping @MainActor (String) -> Void = { _ in },
        onSaved: @escaping @MainActor (Profile) -> Void = { _ in }
    ) {
        self.profile = profile
        self.isEditable = isEditable
        self.backend = backend
        self.pasteboard = pasteboard
        self.onSaved = onSaved
        self.draftName = profile.displayName
        // An editable screen with nowhere to write is the one state where the
        // refusal cannot wait for a tap: the Save button is disabled, so no tap
        // is coming. Say why on arrival instead of going quiet.
        if isEditable, backend == nil {
            self.message = Self.noBackendMessage
        }
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

    /// Won ÷ played as a whole percent, rounded — `2/3` reads `67`, never
    /// `66` or `67.0`. `nil` before anything has been played: a rate over
    /// zero games is not a number, it is a guess dressed as one, and the
    /// view hides the card rather than draw a guess.
    public var winRatePercent: Int? {
        guard profile.matchesPlayed > 0 else { return nil }
        return Int((Double(profile.matchesWon) / Double(profile.matchesPlayed) * 100).rounded())
    }

    // MARK: - The name

    /// The draft with its edges trimmed — what would actually be sent.
    public var trimmedDraft: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the Save button is enabled. An empty draft, a save in flight, or
    /// no backend to write through disables it: a too-long name stays pressable
    /// so ``save()`` can refuse it with ``nameLengthMessage`` — no round trip
    /// either way. The backend check is here and not only in ``save()`` because
    /// a button that is enabled and does nothing is worse than a disabled one.
    public var canSave: Bool {
        isEditable && backend != nil && !trimmedDraft.isEmpty && !isSaving
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
            // The owner's copy of the row, not a second source of truth: this
            // screen is rebuilt from `ShellModel.currentProfile` on every visit,
            // so without this the next visit reopens on the old name.
            onSaved(profile)
        } catch {
            // Deliberately one line rather than a second `BackendError` switch:
            // `HostLobbyModel.message(for:)` is the shared mapping and every
            // case of it is worded for a match, not for a name.
            message = Self.saveFailedMessage
        }
    }

    /// Takes a freshly-read copy of the same row — stats a finished match moved
    /// while this screen was not up, most of all.
    ///
    /// Not a second source of truth: the owner reads the row and hands it here,
    /// exactly as ``save()`` hands one back. A draft the player has already
    /// changed survives, because a late read must never eat what they typed,
    /// and a different row is refused outright. There is deliberately no
    /// mid-save guard: the owner drops a read that a save has overtaken before
    /// it ever gets here, so one here would pin nothing.
    public func adopt(_ fresh: Profile) {
        guard fresh.id == profile.id else { return }
        let untouched = draftName == profile.displayName
        profile = fresh
        if untouched { draftName = fresh.displayName }
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
    public static let matchesPlayedLabel = "Played"
    public static let matchesWonLabel = "Won"
    public static let tilesPlacedLabel = "Tiles placed"
    public static let fastestWinLabel = "Fastest win"
    public static let winRateLabel = "Win rate"
    public static let noValue = "—"
    public static let shareLead = "Add me on Willagrams — my friend code is"
    public static let nameLengthMessage = "A name is 1 to 24 characters."
    public static let saveFailedMessage = "Couldn't save that name. Try again."
    public static let savedMessage = "Saved."
    public static let noBackendMessage = "You're offline, so your name can't be changed right now."

    /// What the `display_name` column allows, mirrored client-side.
    public static let nameLength = 1...24
}
