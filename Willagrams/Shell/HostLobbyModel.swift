//
//  HostLobbyModel.swift
//  Willagrams
//
//  The host's side of "play a friend": create the lobby, show the code, watch
//  who arrives, and open the match. Every decision, every derived string and
//  every pending state is here — `HostLobbyView` renders this and branches on
//  nothing.
//
//  NO SwiftUI here — see the note in AppRoute.swift. This file is pure state,
//  so it compiles into the macOS `Shell` test target and must NOT be listed in
//  that target's `exclude:`.
//
//  This file must never import GameKit.
//

#if canImport(Match)
import Match
#endif
#if canImport(Settings)
import Settings
#endif

import Foundation
import Observation
import WillagramsRules

/// One visit to the host lobby.
///
/// Built by ``ShellModel/playAFriend()`` and dropped by ``ShellModel/returnToMenu()``,
/// which is what guarantees the guardrail: the façade is torn down before the
/// route moves, on every way out, including the ones that are not a Cancel tap.
///
/// It never assigns a route. Start hands the paired façade and session to
/// ``ShellModel/startMatch(_:opponent:)`` and Cancel calls
/// ``ShellModel/returnToMenu()``; both transitions belong to the shell.
@MainActor
@Observable
public final class HostLobbyModel {

    /// What the screen is doing, published rather than inferred. A view that
    /// guessed "creating" from `inviteCode == nil` would also guess it after a
    /// failure, and show a spinner over an error.
    public enum Phase: Equatable, Sendable {

        /// The `matches` row is being written.
        case creating

        /// The lobby exists; the code is up and the roster is live.
        case waiting

        /// Start was pressed and the session is opening.
        case starting

        /// Creating the lobby failed. ``HostLobbyModel/message`` says why, and
        /// there is nothing on this screen but the way back.
        case failed
    }

    public private(set) var phase: Phase = .creating

    /// Six characters, once the row exists.
    public private(set) var inviteCode: String?

    /// Who is in the lobby, as names a player can read, in the order
    /// ``OnlineMatch/lobby`` reports — this device first, because the façade
    /// seeds itself.
    ///
    /// A name that has not come back from `profile(id:)` yet reads as
    /// ``pendingName`` rather than as a UUID.
    public private(set) var roster: [String] = []

    /// True exactly when the lobby holds two players. `OnlineMatch.start()`
    /// refuses anything else, so this is that rule read forward rather than a
    /// second one.
    public private(set) var canStart = false

    /// One line about the last thing that went wrong, or nil. Copy, never an
    /// error: `OnlineMatchError` and `BackendError` reach the screen through
    /// ``message(for:)`` and nowhere else.
    public private(set) var message: String?

    // MARK: - The host's match settings
    //
    // The same pair the solo setup screen edits, minus the opponent: solo has a
    // bot to configure and a lobby has a friend. Both read and write one
    // `SettingsStore`, so whichever screen was used last is what the other opens
    // on. What travels is whatever is here when Start is pressed — the `matches`
    // row's own options are written before this screen can be touched and are
    // never what either device plays under.

    /// The rules half, as the settings lane models it. Nil only when the
    /// bundled word list failed to read, which is this model's state to hold
    /// rather than a branch for the view — ``options`` then falls back to what
    /// the store holds.
    public var optionsForm: MatchOptionsForm?

    /// How many tiles each player opens with. Clamped on write to
    /// ``SoloSetup/handSizeRange``, so a control that forgot its own limits
    /// still cannot deal a hand outside them.
    public var handSize: Int {
        get { storedHandSize }
        set {
            storedHandSize = min(
                max(SoloSetup.handSizeRange.lowerBound, newValue),
                SoloSetup.handSizeRange.upperBound
            )
        }
    }

    private var storedHandSize: Int

    /// Whether the settings are still open: exactly when the lobby is up and
    /// nothing is in flight.
    ///
    /// Derived rather than latched, so it cannot disagree with the button
    /// beside it. `phase` is `.starting` from the press onward — the gear is
    /// dead while a start is in flight and stays dead through a successful
    /// hand-off, because nothing resets `phase`. A start that *throws* puts the
    /// lobby back in `.waiting` and re-offers Start, and the gear comes back
    /// with it: nothing was sent, so nothing is a rule only this device holds.
    ///
    /// `work` is not observed, and is correct today only because there is no
    /// suspension point between the catch's `phase = .waiting` and its
    /// `work = nil` — the pair lands in one uninterrupted main-actor run, so
    /// the observed half is what re-reads the view. An `await` inserted
    /// between them would publish a state this property lies about.
    public var canEditSettings: Bool { phase == .waiting && work == nil }

    /// What Start would send: the edited form, or the stored options while the
    /// form has not been built.
    public var chosenOptions: MatchOptions { (optionsForm?.options ?? storedOptions).validated }

    // MARK: Injected

    @ObservationIgnored private unowned let shell: ShellModel
    @ObservationIgnored private let backend: any BackendClient
    @ObservationIgnored private let store: SettingsStore?
    @ObservationIgnored private let storedOptions: MatchOptions
    @ObservationIgnored private let dictionary: any WordList
    @ObservationIgnored
    private let sleepFor: @MainActor @Sendable (Duration) async throws -> Void

    /// The live façade, or nil once it has been handed to a run or torn down.
    /// Nil is what makes ``teardown()`` correct after a successful Start: the
    /// run owns the channel from then on, and tearing it down here would end a
    /// match that just began.
    @ObservationIgnored private(set) var match: OnlineMatch?

    /// The one async thing in flight — creating, or starting. Held so
    /// ``teardown()`` cancels it, so a cancel during either cannot land a lobby
    /// on a screen that has gone.
    @ObservationIgnored private(set) var work: Task<Void, Never>?

    /// Display names already resolved, by `PlayerID.rawValue`.
    @ObservationIgnored private var names: [String: String] = [:]

    @ObservationIgnored private var nameTask: Task<Void, Never>?

    /// What a player whose profile has not come back yet reads as. Screen
    /// chrome, so it is declared here and not in the frozen `Terminology`.
    public static let pendingName = "…"

    /// This screen's own name, on the menu and at the top of it. Screen chrome,
    /// not a game concept — the same reason `SoloSetup.title` and
    /// `HowToPlay.title` live on their models rather than in `Terminology`.
    public static let title = "Play a Friend"

    /// What the code under it is. Chrome, same rule.
    public static let inviteCodeLabel = "Invite code"

    /// This screen's own name for the settings action. Chrome, same rule.
    public static let settingsLabel = "Match settings"

    init(
        shell: ShellModel,
        backend: any BackendClient,
        store: SettingsStore?,
        dictionary: any WordList,
        localProfile: Profile?,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void
    ) {
        self.shell = shell
        self.backend = backend
        self.store = store
        let stored = store?.load() ?? .standard
        self.storedOptions = stored
        self.storedHandSize = store?.loadHandSize() ?? SettingsStore.defaultHandSize
        self.dictionary = dictionary
        self.sleepFor = sleepFor
        // The local player's name is already in hand; only a guest costs a read.
        if let localProfile {
            names[localProfile.playerID.rawValue] = localProfile.displayName
        }
        // Through the setter, so a stored value written by an older build — or
        // by hand — is still inside the range the stepper offers.
        handSize = storedHandSize
    }

    /// Builds the options form and seeds it from the store. Called when the
    /// settings are opened, not on the way into the lobby: `MatchOptionsForm()`
    /// hashes the whole bundled word list, and most visits to this screen never
    /// touch the gear. Built once and seeded once per lobby: reopening the
    /// sheet must show what was last chosen, not the store's values again.
    public func loadOptions() {
        guard optionsForm == nil, var form = try? MatchOptionsForm() else { return }
        form.swapEnabled = storedOptions.swapEnabled
        form.minimumWordLength = storedOptions.minimumWordLength
        try? form.selectDictionary(storedOptions.dictionaryID)
        optionsForm = form
    }

    // MARK: - Creating

    /// Writes the `matches` row and opens its channel. Called once, by
    /// ``ShellModel/playAFriend()``, immediately after the route moves.
    public func create() {
        guard match == nil, work == nil, phase == .creating else { return }
        message = nil
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let made = try await OnlineMatch.host(
                    options: storedOptions,
                    backend: backend,
                    dictionary: dictionary,
                    sleepFor: sleepFor
                )
                // A cancel that landed while the row was being written still
                // owns a live lobby — leaving it is what abandons the row.
                guard !Task.isCancelled else { return made.leave() }
                match = made
                inviteCode = made.inviteCode
                phase = .waiting
                watchLobby(made)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed
                message = Self.message(for: error)
            }
            work = nil
        }
    }

    // MARK: - The roster

    /// Re-reads the lobby now and every time it changes.
    ///
    /// `withObservationTracking` is spent when it fires, so the re-arm hops to
    /// the next main-actor turn — where the new value is readable — exactly as
    /// `ShellModel.advanceWhenCountdownEnds` does. The identity guard is what
    /// stops a superseded façade's callback writing over a newer lobby's roster.
    private func watchLobby(_ match: OnlineMatch) {
        refreshRoster(match)
        withObservationTracking {
            _ = match.lobby
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.match === match else { return }
                self.watchLobby(match)
            }
        }
    }

    private func refreshRoster(_ match: OnlineMatch) {
        let players = match.lobby
        canStart = players.count == 2
        roster = players.map { names[$0.rawValue] ?? Self.pendingName }
        resolveNames(players)
    }

    /// Fills in the names the lobby does not have yet, one read each, then
    /// republishes the roster. A failed read leaves ``pendingName`` in place: a
    /// lobby is still joinable by someone whose profile row would not load.
    private func resolveNames(_ players: [PlayerID]) {
        let missing = players.filter { names[$0.rawValue] == nil }
        guard !missing.isEmpty, nameTask == nil else { return }
        nameTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for player in missing {
                guard let id = UUID(uuidString: player.rawValue) else { continue }
                if let profile = try? await backend.profile(id: id) {
                    names[player.rawValue] = profile.displayName
                }
            }
            guard !Task.isCancelled else { return }
            nameTask = nil
            if let match { refreshRoster(match) }
        }
    }

    // MARK: - The two ways out

    /// Opens the match and hands it to the shell.
    ///
    /// The façade is released from this model *before* the run is built, so the
    /// teardown `startMatch(_:opponent:)` runs on the way through the menu
    /// cannot end the very match it is starting.
    public func start() {
        guard canStart, phase == .waiting, let match, work == nil else { return }
        message = nil
        // Shut before anything awaits: `canEditSettings` reads `.starting`, so
        // the gear is unavailable from the press, not from whenever the open
        // comes back.
        phase = .starting
        let chosen = chosenOptions
        let hand = handSize
        // Start is where the choices are written back, so the next lobby opens
        // on what this match is about to be played under. The same rule
        // `startSoloPractice` follows.
        store?.save(chosen)
        store?.saveHandSize(hand)
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await match.start(handSize: hand, options: chosen)
                guard !Task.isCancelled else {
                    session.leave()
                    match.leave()
                    return
                }
                // Handed over: this model no longer tears it down.
                self.match = nil
                let record = match.record
                shell.startMatch(
                    MatchSetup(
                        seed: record.poolSeed,
                        startingHandSize: hand,
                        countdownSeconds: OnlineMatch.countdownSeconds,
                        options: chosen
                    ),
                    opponent: { OnlineOpponent(match: match, session: session) }
                )
            } catch {
                guard !Task.isCancelled else { return }
                phase = .waiting
                message = Self.message(for: error)
            }
            work = nil
        }
    }

    /// Leaves the lobby and goes home. The teardown is
    /// ``ShellModel/returnToMenu()``'s, which runs it before it moves the route.
    public func cancel() { shell.returnToMenu() }

    /// Ends everything this model started. Called by `ShellModel` on every exit
    /// from the screen, not only Cancel, and idempotent.
    func teardown() {
        work?.cancel()
        work = nil
        nameTask?.cancel()
        nameTask = nil
        match?.leave()
        match = nil
    }

    // MARK: - Copy

    /// A failure as one line a player can read.
    ///
    /// Pure and static, so every mapping is decidable without a lobby, a
    /// backend or a screen — and so a `catch` here can never reach the view as
    /// a raw error or as a silent return to the menu.
    public static func message(for error: any Error) -> String {
        if let error = error as? OnlineMatchError {
            return switch error {
            case .lobbyNotReady: "Wait for your friend to join before starting."
            case .notAuthenticated: "You're not signed in yet. Try again in a moment."
            }
        }
        return switch error as? BackendError {
        case .offline: "You're offline. Reconnect to play a friend."
        case .notFound: "That match is no longer available."
        case .matchFull: "That match is already full."
        case .notAuthenticated, .permissionDenied: "You can't host a match right now."
        case .alreadyExists, .blocked, .none: "Something went wrong. Try again."
        }
    }
}
