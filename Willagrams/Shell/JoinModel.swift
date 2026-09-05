//
//  JoinModel.swift
//  Willagrams
//
//  The guest's side of "play a friend": type the code, join the lobby, wait for
//  the host, and walk into the match the host opened. Every decision, every
//  derived string and every pending state is here — `JoinView` renders this and
//  branches on nothing.
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

/// One visit to the join screen.
///
/// Built by ``ShellModel/showJoin()`` and dropped by ``ShellModel/returnToMenu()``,
/// which is what guarantees the guardrail: the façade, the session and the
/// in-flight join are all torn down before the route moves, on every way out.
///
/// It never assigns a route. The start hands the paired façade and session to
/// ``ShellModel/startMatch(_:opponent:)`` and Cancel calls
/// ``ShellModel/returnToMenu()``; both transitions belong to the shell.
///
/// The error copy is ``HostLobbyModel/message(for:)`` verbatim — one mapping
/// for both sides of the same lobby, so a wrong code cannot read one way to the
/// host and another to the guest.
@MainActor
@Observable
public final class JoinModel {

    /// What the screen is doing, published rather than inferred.
    public enum Phase: Equatable, Sendable {

        /// The field is up and the player is typing.
        case entering

        /// The join call is in flight.
        case joining

        /// This device is in the lobby; the host has not opened the match yet.
        case waiting
    }

    public private(set) var phase: Phase = .entering

    /// What the field holds, sanitised on every write.
    ///
    /// The clamp is here rather than in the view for the usual reason — a view
    /// holds no rule that changes what the app does — and it is *before* the
    /// call rather than after it because the backend's regex is the last line
    /// of defence, not the first.
    public var code: String = "" {
        didSet {
            let clean = Self.sanitised(code)
            // The second pass through `didSet` finds nothing to change and
            // stops; a guard on equality here would be the same two passes.
            guard clean == code else { return code = clean }
            if oldValue != code { message = nil }
        }
    }

    /// The host's display name once it has been read, or nil while it is being
    /// read or if it could not be.
    public private(set) var hostName: String?

    /// One line about the last thing that went wrong, or nil. Copy, never an
    /// error.
    public private(set) var message: String?

    // MARK: Injected

    @ObservationIgnored private unowned let shell: ShellModel
    @ObservationIgnored private let backend: any BackendClient
    @ObservationIgnored private let dictionary: any WordList
    @ObservationIgnored
    private let sleepFor: @MainActor @Sendable (Duration) async throws -> Void

    /// The live façade, or nil before a join and once it has been handed to a
    /// run or torn down. Nil is what makes ``teardown()`` correct after the
    /// match opens: the run owns the channel from then on.
    @ObservationIgnored private(set) var match: OnlineMatch?

    /// The session `awaitStart()` handed back, held on the same terms.
    @ObservationIgnored private(set) var session: MatchSession?

    /// The join, and the `awaitStart()` after it, as one task. Held so
    /// ``teardown()`` cancels it: a cancel mid-join must not land a lobby on a
    /// screen that has gone, and must not leave its channel subscribed.
    @ObservationIgnored private(set) var work: Task<Void, Never>?

    @ObservationIgnored private var nameTask: Task<Void, Never>?

    /// How many characters a code is. `OnlineMatch` mints them at this length.
    public static let codeLength = 6

    /// This screen's own name, on the menu and at the top of it. Screen chrome,
    /// not a game concept — the same rule `HostLobbyModel.title` follows.
    public static let title = "Join a Friend"

    /// What the guest sees while the host has not pressed Start yet.
    public static let waitingTitle = "Waiting for host"

    /// What a code that is not six characters says. Not an error from anywhere:
    /// no call is made, so there is nothing to map.
    public static let shortCodeMessage = "Enter the six-character code."

    init(
        shell: ShellModel,
        backend: any BackendClient,
        dictionary: any WordList,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void
    ) {
        self.shell = shell
        self.backend = backend
        self.dictionary = dictionary
        self.sleepFor = sleepFor
    }

    /// Whether the Join button does anything. One question, asked here, so the
    /// view that draws the button and the call that honours it cannot disagree.
    public var canJoin: Bool { phase == .entering && code.count == Self.codeLength }

    /// The waiting line, host included once the name is in.
    public var waitingLine: String {
        guard let hostName else { return Self.waitingTitle }
        return "\(Self.waitingTitle): \(hostName)"
    }

    /// Uppercased, stripped to `[A-Z0-9]` and cut to ``codeLength``.
    ///
    /// Pure and static, so the clamp is decidable without a screen, a model or
    /// a backend.
    public static func sanitised(_ raw: String) -> String {
        String(
            raw.uppercased()
                .filter { $0.isASCII && ($0.isUppercase || $0.isNumber) }
                .prefix(codeLength)
        )
    }

    // MARK: - Joining

    /// Joins the lobby the code names, then waits for the host to open it.
    public func join() {
        guard phase == .entering, work == nil else { return }
        // The client-side fence. A short code never reaches the network.
        guard code.count == Self.codeLength else {
            message = Self.shortCodeMessage
            return
        }
        message = nil
        phase = .joining
        let code = code
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let joined = try await OnlineMatch.join(
                    code: code,
                    backend: backend,
                    dictionary: dictionary,
                    sleepFor: sleepFor
                )
                // A cancel that landed while the row was being written still
                // owns a live channel — leaving it is what closes it.
                guard !Task.isCancelled else { return joined.leave() }
                match = joined
                phase = .waiting
                resolveHostName(joined)

                // Returns as soon as the membership rows name both players; the
                // `.start` itself arrives over the channel, which is what
                // ``watchStart(match:session:)`` below waits for.
                let opened = try await joined.awaitStart()
                guard !Task.isCancelled else {
                    opened.leave()
                    joined.leave()
                    return
                }
                session = opened
                watchStart(match: joined, session: opened)
            } catch {
                guard !Task.isCancelled else { return }
                // A join that succeeded and an `awaitStart()` that did not
                // leaves a live channel this screen no longer has a use for.
                match?.leave()
                match = nil
                phase = .entering
                message = HostLobbyModel.message(for: error)
            }
            work = nil
        }
    }

    /// Reads the host's name, once. A failed read leaves the waiting line
    /// nameless: a lobby is still joinable by someone whose profile row would
    /// not load.
    private func resolveHostName(_ match: OnlineMatch) {
        guard hostName == nil, nameTask == nil else { return }
        let hostID = match.record.hostID
        nameTask = Task { @MainActor [weak self] in
            let profile = try? await self?.backend.profile(id: hostID)
            guard !Task.isCancelled, let self else { return }
            hostName = profile?.displayName
            nameTask = nil
        }
    }

    /// Moves to the countdown the moment the host's `.start` lands.
    ///
    /// `awaitStart()` hands back a session that has not begun yet — a guest that
    /// walked into `.countdown` on it would find `CountdownOverlay` already nil
    /// and be carried straight through to a board nobody has dealt. So the
    /// route waits on the session, not on the call.
    ///
    /// `withObservationTracking` is spent when it fires, so the re-arm hops to
    /// the next main-actor turn — where the new status is readable — exactly as
    /// `HostLobbyModel.watchLobby` does. The identity guard is what stops a torn
    /// -down screen's callback starting a match behind the menu.
    private func watchStart(match: OnlineMatch, session: MatchSession) {
        guard self.match === match else { return }
        guard !Self.hasBegun(session) else {
            return begin(match: match, session: session)
        }
        withObservationTracking {
            _ = session.state.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.watchStart(match: match, session: session)
            }
        }
    }

    /// Whether the host's `.start` has been applied to this session.
    ///
    /// A session that has not started sits at `.countdown(secondsRemaining: 0)`
    /// — the one status that means "nothing has happened yet". Everything else,
    /// a running count included, means it has.
    static func hasBegun(_ session: MatchSession) -> Bool {
        guard case .countdown(let secondsRemaining) = session.state.status else { return true }
        return secondsRemaining > 0
    }

    /// Hands the façade and its session to the shell.
    ///
    /// Both are released from this model *before* the run is built, so the
    /// teardown `startMatch(_:opponent:)` runs on the way through the menu
    /// cannot end the very match it is starting.
    private func begin(match: OnlineMatch, session: MatchSession) {
        self.match = nil
        self.session = nil
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
    }

    // MARK: - The way out

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
        session?.leave()
        session = nil
        match?.leave()
        match = nil
    }
}
