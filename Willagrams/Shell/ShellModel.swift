#if canImport(Bot)
import Bot
#endif
#if canImport(Match)
import Match
#endif
#if canImport(Account)
import Account
#endif
#if canImport(Friends)
import Friends
#endif
#if canImport(UIKit)
import UIKit
#endif

import Observation
import WillagramsRules

// NO SwiftUI here — see the note in AppRoute.swift.

/// Owns the current route and every legal move between routes. Views read
/// ``route`` and call these methods; nothing outside this type may assign a
/// route, which is why the setter is private.
@MainActor
@Observable
public final class ShellModel {

    public private(set) var route: AppRoute

    /// The live match and everything drawn from it, or `nil` between one ending
    /// and the next starting. Exactly one exists at a time and it is the only
    /// strong reference to that match, so dropping it is the teardown.
    ///
    /// The countdown, match and results screens all read this one instance —
    /// that is the whole point of it living here rather than in a route payload.
    ///
    /// No longer `#if DEBUG`: `SoloMatch` runs on a shipping `LocalMatchLink`
    /// against a real `BotMatch`, so solo practice is a shipping feature and
    /// this reference is one too.
    public private(set) var run: MatchRun?

    /// The seed the last run was dealt from. Outlives the run it belongs to, so
    /// the never-repeat rule in ``startSoloPractice(seed:)`` has something to
    /// compare against after a teardown.
    public private(set) var seed: UInt64?

    /// Counts matches started. Not the run's identity: a teardown nils `run`,
    /// and an end screen's Main Menu runs before its Rematch, so an identity
    /// check would decline the very rematch it was meant to allow.
    @ObservationIgnored private var generation = 0

    /// Built once per *launch*, on the first match, and reused by every match
    /// after it — including a rematch. The bundled list is a ~172k-entry `Set`
    /// read off disk, and building one per rematch is a main-actor stall the
    /// player would feel between the end screen and the next deal.
    @ObservationIgnored private let dictionary: @MainActor () -> any WordList
    @ObservationIgnored private var cachedDictionary: (any WordList)?

    private func loadedDictionary() -> any WordList {
        if let cachedDictionary { return cachedDictionary }
        let loaded = dictionary()
        // A failed bundle read degrades to a list that accepts no word. Caching
        // that would make every match of the process unwinnable off one bad
        // read, so it is returned uncached and the next match retries the load.
        if (loaded as? EnableWordList)?.count == 0 { return loaded }
        cachedDictionary = loaded
        return loaded
    }

    @ObservationIgnored private let sleepFor: @MainActor @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let seedSource: @MainActor () -> UInt64

    /// The backend, player and settings store the root built. Screens read them
    /// from here; none of them constructs its own.
    @ObservationIgnored public let services: ShellServices

    /// The signed-in player, once sign-in lands. Nil until then, and for the
    /// whole run of a build that carries no sign-in.
    public private(set) var currentProfile: Profile?

    /// One line saying why the menu's online actions are off, or nil when they
    /// work. The copy is derived here rather than in a view: a view holds no
    /// branch that changes what the app says.
    public private(set) var onlineUnavailableReason: String?

    /// Owned here so it can be cancelled when this model goes away; never
    /// awaited on the launch path, so the menu draws while it is still running.
    /// Readable so a test can await the launch sign-in instead of polling for
    /// it; nothing in the app reads it.
    @ObservationIgnored private(set) var signInTask: Task<Void, Never>?

    public static let signingInReason = "Signing in…"
    public static let noSignInReason = "Online play is unavailable in this build."

    /// A `BackendError` as one line a player can read. Pure, so the copy is
    /// testable without a model and without a view.
    public static func onlineUnavailableReason(for error: any Error) -> String {
        switch error as? BackendError {
        case .offline: "You're offline. Reconnect to play a friend."
        case .permissionDenied: "This account can't play online."
        case .notAuthenticated, .notFound, .alreadyExists, .blocked, .matchFull, .none:
            "Couldn't sign in. Reopen the app to try again."
        }
    }

    public init(
        route: AppRoute = .menu,
        dictionary: @escaping @MainActor () -> any WordList = {
            // ponytail: a missing bundled list degrades to a list that accepts
            // no word, so a match becomes unwinnable rather than crashing on
            // launch. Upgrade to a surfaced load error when there is a screen
            // that can say so.
            (try? EnableWordList()) ?? EnableWordList(words: [])
        },
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        seedSource: @escaping @MainActor () -> UInt64 = {
            UInt64.random(in: UInt64.min ... UInt64.max)
        },
        services: ShellServices = ShellServices()
    ) {
        self.route = route
        self.dictionary = dictionary
        self.sleepFor = sleepFor
        self.seedSource = seedSource
        self.services = services
        self.soloSetup = SoloSetup(store: services.settings)

        guard let signIn = services.signIn else {
            onlineUnavailableReason = Self.noSignInReason
            return
        }
        onlineUnavailableReason = Self.signingInReason
        signInTask = Task { @MainActor [weak self] in
            do {
                let profile = try await signIn.signIn()
                guard !Task.isCancelled, let self else { return }
                currentProfile = profile
                onlineUnavailableReason = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                onlineUnavailableReason = Self.onlineUnavailableReason(for: error)
            }
        }
    }

    /// Cancels the sign-in the model started. A failed or cancelled sign-in is
    /// a disabled menu with a reason — never a retry, never an alert.
    deinit { signInTask?.cancel() }

    /// Whether `generation` is still the live one. Read by a
    /// ``MatchRun/results(board:)`` screen's closures, which must decline once
    /// the run they were built for has been replaced.
    func isLiveGeneration(_ generation: Int) -> Bool { generation == self.generation }

    /// Menu → countdown. Ignored from anywhere else, so a stray tap on a stale
    /// menu button cannot yank a live match back to the start.
    public func startMatch(_ setup: MatchSetup) {
        guard case .menu = route else { return }
        route = .countdown(setup)
    }

    /// The guest's join screen for this visit, or nil when it is not up. Like
    /// ``hostLobby`` it owns a live `OnlineMatch` once a code lands, so it is
    /// built on the way in and torn down by ``returnToMenu()`` on every way out.
    public private(set) var join: JoinModel?

    /// Menu → the join screen.
    ///
    /// Refused on the same terms as ``playAFriend()``: joining writes a
    /// `match_players` row, and there is nobody to write one as.
    ///
    /// - Returns: whether the route moved.
    @discardableResult
    public func showJoin() -> Bool {
        guard case .menu = route, canPlayOnline, let backend = services.backend else {
            return false
        }
        join = JoinModel(
            shell: self,
            backend: backend,
            dictionary: loadedDictionary(),
            sleepFor: sleepFor
        )
        route = .join
        return true
    }

    /// The profile screen for this visit, or nil when it is not up. Torn down
    /// by ``returnToMenu()`` like every other screen model, so a stale draft
    /// name cannot survive a trip to the menu and reappear.
    public private(set) var profile: ProfileModel?

    /// Menu → the local player's profile, with editing on.
    ///
    /// Refused without a signed-in profile, on the same terms the menu button
    /// is disabled: there is no row to render and nobody to save as.
    ///
    /// - Returns: whether the route moved.
    @discardableResult
    public func showProfile() -> Bool {
        guard case .menu = route, let currentProfile else { return false }
        profile = ProfileModel(
            profile: currentProfile,
            isEditable: true,
            backend: services.backend,
            pasteboard: Self.pasteboard
        )
        route = .profile
        return true
    }

    /// The friends list for this visit, or nil when it is not up. Torn down by
    /// ``returnToMenu()`` like every other screen model, so the next visit reads
    /// the sections again rather than showing the last visit's.
    public private(set) var friends: FriendsModel?

    /// Menu → the friends list.
    ///
    /// Refused without a signed-in profile, on the same terms the menu button is
    /// disabled: `friendships()` is read as somebody, and there is nobody.
    ///
    /// - Returns: whether the route moved.
    @discardableResult
    public func showFriends() -> Bool {
        guard case .menu = route, let currentProfile, let backend = services.backend else {
            return false
        }
        friends = FriendsModel(me: currentProfile.id, backend: backend)
        route = .friends
        return true
    }

    /// Putting the friend code on the clipboard. Here rather than in
    /// `Willagrams/Account` because `UIPasteboard` is UIKit and that directory
    /// is compiled for macOS by two test packages; a no-op there is correct,
    /// since nothing on macOS renders the button that calls it.
    static let pasteboard: @MainActor (String) -> Void = { text in
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    /// What the next solo match will be played with. Lives here rather than on
    /// the screen that edits it, so choices survive backing out to the menu.
    public let soloSetup: SoloSetup

    /// Menu → solo setup. Only from the menu, for the same reason the rules
    /// screen is: a live match must not be yanked out from under the player by
    /// a stray tap on a stale control.
    public func showSoloSetup() {
        guard case .menu = route else { return }
        // Entry is where the stored rules are read, so the screen opens on what
        // was last chosen — here or in a host lobby — rather than on defaults.
        soloSetup.loadOptions()
        route = .soloSetup
    }

    /// Menu → rules. Only from the menu, so the rules screen cannot be reached
    /// from inside a match and cannot strand a live run behind it. ``returnToMenu()``
    /// is the way back.
    public func showHowToPlay() {
        guard case .menu = route else { return }
        route = .howToPlay
    }

    /// The host's lobby for this visit, or nil when the screen is not up. It
    /// owns a live `OnlineMatch`, so it is built on the way in and torn down by
    /// ``returnToMenu()`` on every way out.
    public private(set) var hostLobby: HostLobbyModel?

    /// Whether the menu's online actions can be taken. One question, asked here,
    /// so the view that draws the button and the transition that honours it
    /// cannot disagree.
    public var canPlayOnline: Bool { currentProfile != nil && services.backend != nil }

    /// Menu → host lobby, building the lobby that screen renders.
    ///
    /// Refused with no sign-in and no backend, for the same reason the button is
    /// disabled: a lobby needs a `matches` row and there is nobody to write one
    /// as. The rules are whatever ``SettingsStore`` last stored, so a host plays
    /// under the options they last chose for solo.
    ///
    /// - Returns: whether the route moved.
    @discardableResult
    public func playAFriend() -> Bool {
        guard case .menu = route, canPlayOnline, let backend = services.backend else {
            return false
        }
        let lobby = HostLobbyModel(
            shell: self,
            backend: backend,
            options: services.settings?.load() ?? .standard,
            dictionary: loadedDictionary(),
            localProfile: currentProfile,
            sleepFor: sleepFor
        )
        hostLobby = lobby
        route = .hostLobby
        lobby.create()
        return true
    }

    /// What the menu's first action starts. The setup is fixed apart from the
    /// seed: there is no difficulty selector on the menu yet, so every solo
    /// match is played against the bot at ``soloDifficulty``.
    public static let soloHandSize = 21
    public static let soloCountdownSeconds = 3

    /// How hard the opponent plays. One named constant rather than a literal at
    /// the call site, so the screen that will eventually choose this has exactly
    /// one value to replace.
    public static let soloDifficulty = BotDifficulty.medium

    /// Menu → countdown with the solo setup, and the one place a match is built.
    ///
    /// Starting and rematching are the same call: a rematch is not a reset, it
    /// is another start. ``MatchTransport`` states that each stream has exactly
    /// one consumer per endpoint, so a live transport cannot be handed to a
    /// second `MatchSession` — a rematch needs a new pair, a new session and a
    /// new pool, which is exactly what a first start builds.
    ///
    /// It returns to the menu first rather than refusing off `.menu`: that is
    /// what tears the previous run down *before* the replacement is
    /// constructed, so two live sessions never overlap. `startMatch` keeps its
    /// own guard for every other caller.
    ///
    /// - Parameter explicit: a seed to use instead of the injected source. It is
    ///   still put through the never-repeat rule below, so no caller can hand
    ///   the player the same deal twice running.
    /// - Returns: whether a match was started.
    /// - Parameters:
    ///   - difficulty: how hard the far end plays. `nil` takes what
    ///     ``soloSetup`` holds, which is what the setup screen just edited.
    ///   - handSize: how many tiles each player opens with, same rule.
    ///   - options: the rules the match runs under, same rule.
    @discardableResult
    public func startSoloPractice(
        seed explicit: UInt64? = nil,
        difficulty: BotDifficulty? = nil,
        handSize: Int? = nil,
        options: MatchOptions? = nil
    ) -> Bool {
        // Down before up: the previous run's stream-iteration tasks are
        // cancelled here, not left for whenever the old objects deallocate.
        returnToMenu()

        // A hard guarantee, not a probabilistic one: `.random` can repeat, and
        // an identical pool turns practice into memorising one deal.
        //
        // ponytail: guards the immediately previous seed only, so a source that
        // alternates between two values still deals A, B, A, B. Upgrade to a
        // monotonic counter mixed into the seed if that ever matters — a full
        // history set would grow without bound.
        let candidate = explicit ?? seedSource()
        let fresh = candidate == seed ? candidate &+ 1 : candidate

        // Start is where the rules are written back, so the next launch and the
        // next host lobby open on what this match is about to be played under.
        let chosen = (options ?? soloSetup.options).validated
        soloSetup.saveOptions(chosen)

        startMatch(
            MatchSetup(
                seed: fresh,
                startingHandSize: handSize ?? soloSetup.handSize,
                countdownSeconds: Self.soloCountdownSeconds,
                options: chosen
            )
        )
        return install { setup, dictionary, generation in
            MatchRun(
                shell: self,
                setup: setup,
                dictionary: dictionary,
                generation: generation,
                difficulty: difficulty ?? self.soloSetup.difficulty,
                sleepFor: self.sleepFor
            )
        }
    }

    /// Menu → countdown over an opponent the caller built — a lobby's
    /// `OnlineMatch`, or a test's double.
    ///
    /// The opponent arrives as a closure rather than as a value so the same
    /// down-before-up order solo has is kept for a caller who cannot see it: the
    /// previous run is torn down, and only then is the next opponent made. A
    /// built value in an argument would be constructed before this call is even
    /// entered, with two far ends live at once for as long as that took.
    @discardableResult
    public func startMatch(
        _ setup: MatchSetup,
        opponent makeOpponent: @MainActor () -> any MatchOpponent
    ) -> Bool {
        // Down before up, exactly as in `startSoloPractice`.
        returnToMenu()
        startMatch(setup)
        return install { setup, dictionary, generation in
            MatchRun(
                shell: self,
                setup: setup,
                dictionary: dictionary,
                generation: generation,
                opponent: makeOpponent()
            )
        }
    }

    /// Builds the run for the countdown the route is already on, arms it and
    /// opens it. The one place a run becomes *the* run, so solo and online
    /// cannot arm different things.
    private func install(
        _ build: (MatchSetup, any WordList, Int) -> MatchRun
    ) -> Bool {
        // `startMatch` only moves from `.menu`, so this is the assertion that
        // the route really did advance rather than silently no-op.
        guard case .countdown(let setup) = route else { return false }

        seed = setup.seed
        generation &+= 1
        let built = build(setup, loadedDictionary(), generation)
        run = built
        // Armed BEFORE the deal: `start()` is what sets the count running, and a
        // tracker armed after it would miss a status change that landed in
        // between and never advance.
        advanceWhenCountdownEnds(built, generation: generation)
        endWhenTheMatchDoes(built, generation: generation)
        built.start()
        return true
    }

    /// Ends the live run and drops it, leaving the route alone. A no-op when
    /// nothing is running, so calling it twice cannot tear down a match that has
    /// already been replaced.
    public func endSoloPractice() {
        run?.leave()
        run = nil
    }

    /// Countdown → match, carrying the same setup forward untouched.
    public func countdownFinished() {
        guard case .countdown(let setup) = route else { return }
        route = .match(setup)
    }

    /// Moves the route on by itself the moment the count runs out.
    ///
    /// Without this nothing in the app calls ``countdownFinished()`` — only
    /// tests did, so the app dealt a hand and then sat on `.countdown` forever,
    /// showing a board `CountdownView` had locked and no HUD at all.
    ///
    /// The decision lives here rather than in `CountdownView` because a view
    /// holds no branch that changes what the app does, and it is the *same*
    /// question `CountdownOverlay` already answers: no card means nothing should
    /// cover the board, which is precisely when the match screen owns it. Asking
    /// that one type twice cannot disagree with itself the way a second rule
    /// here would.
    ///
    /// `withObservationTracking` fires before the change lands and is spent when
    /// it does, so the check hops to the next main-actor turn — where the new
    /// status is readable — and re-arms there. The generation guard is what stops
    /// a superseded run's last callback yanking a newer match's route.
    private func advanceWhenCountdownEnds(_ run: MatchRun, generation: Int) {
        withObservationTracking {
            _ = run.session.state.status
            _ = run.session.isMatchOver
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isLiveGeneration(generation) else { return }
                guard case .countdown = self.route else { return }
                // A card still up means the count is still running.
                guard CountdownOverlay(session: run.session) == nil else {
                    return self.advanceWhenCountdownEnds(run, generation: generation)
                }
                self.countdownFinished()
            }
        }
    }

    /// Moves to the results by itself when the match ends without this player
    /// ending it.
    ///
    /// ``MatchHUDModel`` calls ``matchEnded(winner:)`` on the two endings this
    /// player causes — their own Win and their own Resign — and nothing called
    /// it on the ending the *opponent* causes. Against a silent far end that
    /// never showed; against a bot that plays to a win it is the ordinary way a
    /// match finishes, and it left the player on a match screen with every
    /// control disabled by `isMatchOver` and a Resign the session refuses,
    /// because a finished session is locked. There was no way out of that
    /// screen.
    ///
    /// Re-arms exactly like ``advanceWhenCountdownEnds(_:generation:)`` and for
    /// the same reason. The route guards make it harmless on the endings this
    /// player did cause: the route is already `.results` by the time this runs.
    private func endWhenTheMatchDoes(_ run: MatchRun, generation: Int) {
        withObservationTracking {
            _ = run.session.isMatchOver
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isLiveGeneration(generation) else { return }
                guard run.session.isMatchOver else {
                    return self.endWhenTheMatchDoes(run, generation: generation)
                }
                // A match can end before the count does — a peer who resigns
                // during the countdown — and `matchEnded` only moves from
                // `.match`. Finishing the countdown first is what stops that
                // ending being swallowed.
                if case .countdown = self.route { self.countdownFinished() }
                self.matchEnded(winner: run.session.winner)
            }
        }
    }

    /// Match → results. Only reachable from a match, so results can never show
    /// an outcome for a match that never ran.
    public func matchEnded(winner: PlayerID?) {
        guard case .match = route else { return }
        route = .results(winner: winner)
    }

    /// The one transition legal from anywhere: back out to the root screen,
    /// taking the live match with it. The teardown runs first, so the menu is
    /// never shown over a session that is still pumping.
    public func returnToMenu() {
        // Before the route moves, and before the run is touched: a cancelled
        // lobby must not leave a channel subscribed behind the menu. Every exit
        // from `.hostLobby` runs through here — Cancel, Start's own teardown,
        // and anything else that goes home — so there is one place this happens
        // rather than one per way out.
        hostLobby?.teardown()
        hostLobby = nil
        // The guest's half of the same rule: the join in flight is cancelled and
        // its channel closed before the menu is shown over them.
        join?.teardown()
        join = nil
        // No channel and no task behind this one — dropping it is the whole
        // teardown — but it goes before the route moves for the same reason the
        // other two do: the menu is never shown over a screen model that is
        // still reachable.
        profile = nil
        // Same rule again: no channel and no task behind it, but it is gone
        // before the route moves so the menu is never shown over a live screen
        // model, and a stale section list cannot reappear on the next visit.
        friends = nil
        endSoloPractice()
        // Reaching the menu is what makes every end screen stale: the run they
        // were built for is gone and cannot come back. The bump is here rather
        // than in ``endSoloPractice()`` because `ResultsModel.rematch()` runs
        // the teardown *first* and then starts — bumping there would make a
        // live screen decline its own rematch.
        generation &+= 1
        route = .menu
    }
}
