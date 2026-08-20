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

#if DEBUG
    /// The live match and everything drawn from it, or `nil` between one ending
    /// and the next starting. Exactly one exists at a time and it is the only
    /// strong reference to that match, so dropping it is the teardown.
    ///
    /// The countdown, match and results screens all read this one instance —
    /// that is the whole point of it living here rather than in a route payload.
    ///
    /// `#if DEBUG` because `MatchRun` owns a `SoloMatch`, which owns a
    /// `FakeTransport`, which must not reach a shipping build. See the finding
    /// in the engineer report: solo practice cannot run in Release today.
    public private(set) var run: MatchRun?
#endif

    /// The seed the last run was dealt from. Outlives the run it belongs to, so
    /// the never-repeat rule in ``startSoloPractice(seed:)`` has something to
    /// compare against after a teardown.
    public private(set) var seed: UInt64?

    /// Counts matches started. Not the run's identity: a teardown nils `run`,
    /// and an end screen's Main Menu runs before its Rematch, so an identity
    /// check would decline the very rematch it was meant to allow.
    @ObservationIgnored private var generation = 0

    /// Built once per match, not once per launch — a word list costs a few MB
    /// and a test wants a handful of words rather than 172k.
    @ObservationIgnored private let dictionary: @MainActor () -> any WordList
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

    /// What the menu's one action starts. Solo practice takes no options, so the
    /// setup is fixed apart from the seed — there is no difficulty selector and
    /// no opponent to configure.
    public static let soloHandSize = 21
    public static let soloCountdownSeconds = 3

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
    @discardableResult
    public func startSoloPractice(seed explicit: UInt64? = nil) -> Bool {
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
                startingHandSize: Self.soloHandSize,
                countdownSeconds: Self.soloCountdownSeconds
            )
        )
        // `startMatch` only moves from `.menu`, so this is the assertion that
        // the route really did advance rather than silently no-op.
        guard case .countdown(let setup) = route else { return false }

        seed = fresh
        generation &+= 1
#if DEBUG
        let built = MatchRun(
            shell: self,
            setup: setup,
            dictionary: dictionary(),
            generation: generation,
            sleepFor: sleepFor
        )
        run = built
        built.start()
#endif
        return true
    }

    /// Ends the live run and drops it, leaving the route alone. A no-op when
    /// nothing is running, so calling it twice cannot tear down a match that has
    /// already been replaced.
    public func endSoloPractice() {
#if DEBUG
        run?.leave()
        run = nil
#endif
    }

    /// Countdown → match, carrying the same setup forward untouched.
    public func countdownFinished() {
        guard case .countdown(let setup) = route else { return }
        route = .match(setup)
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
        route = .menu
    }
}
