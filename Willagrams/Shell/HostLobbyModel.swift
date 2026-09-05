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

    // MARK: Injected

    @ObservationIgnored private unowned let shell: ShellModel
    @ObservationIgnored private let backend: any BackendClient
    @ObservationIgnored private let options: MatchOptions
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

    init(
        shell: ShellModel,
        backend: any BackendClient,
        options: MatchOptions,
        dictionary: any WordList,
        localProfile: Profile?,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void
    ) {
        self.shell = shell
        self.backend = backend
        self.options = options
        self.dictionary = dictionary
        self.sleepFor = sleepFor
        // The local player's name is already in hand; only a guest costs a read.
        if let localProfile {
            names[localProfile.playerID.rawValue] = localProfile.displayName
        }
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
                    options: options,
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
        phase = .starting
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await match.start()
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
                        startingHandSize: OnlineMatch.startingHandSize,
                        countdownSeconds: OnlineMatch.countdownSeconds,
                        options: record.options
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
