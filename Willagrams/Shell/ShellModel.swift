#if canImport(Bot)
import Bot
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
        }
    ) {
        self.route = route
        self.dictionary = dictionary
        self.sleepFor = sleepFor
        self.seedSource = seedSource
    }

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

    /// What the next solo match will be played with. Lives here rather than on
    /// the screen that edits it, so choices survive backing out to the menu.
    public let soloSetup = SoloSetup()

    /// Menu → solo setup. Only from the menu, for the same reason the rules
    /// screen is: a live match must not be yanked out from under the player by
    /// a stray tap on a stale control.
    public func showSoloSetup() {
        guard case .menu = route else { return }
        route = .soloSetup
    }

    /// Menu → rules. Only from the menu, so the rules screen cannot be reached
    /// from inside a match and cannot strand a live run behind it. ``returnToMenu()``
    /// is the way back.
    public func showHowToPlay() {
        guard case .menu = route else { return }
        route = .howToPlay
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

        startMatch(
            MatchSetup(
                seed: fresh,
                startingHandSize: handSize ?? soloSetup.handSize,
                countdownSeconds: Self.soloCountdownSeconds,
                options: options ?? soloSetup.options
            )
        )
        // `startMatch` only moves from `.menu`, so this is the assertion that
        // the route really did advance rather than silently no-op.
        guard case .countdown(let setup) = route else { return false }

        seed = fresh
        generation &+= 1
        let built = MatchRun(
            shell: self,
            setup: setup,
            dictionary: loadedDictionary(),
            generation: generation,
            difficulty: difficulty ?? soloSetup.difficulty,
            sleepFor: sleepFor
        )
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
