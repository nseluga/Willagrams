//
//  MatchRun.swift
//  Willagrams
//
//  One match, and everything drawn from it. The countdown, the match and the
//  results screens are three views of the same `MatchSession`, which is only
//  true if exactly one thing builds it — this.
//
//  NO SwiftUI here — see the note in AppRoute.swift. This file is pure state,
//  so it compiles into the macOS `Shell` test target and must NOT be listed in
//  that target's `exclude:`.
//
//  This file must never import GameKit.
//

// `SoloMatch` used to be `#if DEBUG`, because the `FakeTransport` it owned was,
// and this type carried the same fence. That far end is a shipping `BotMatch`
// now, so neither this type nor `ShellModel.run` is fenced any more.

// The app compiles `Willagrams/Match`, `Willagrams/Bot` and `Willagrams/Shell`
// into one module, where there is nothing to import. `Tests/ShellTests`
// compiles them as separate ones, so the imports are real there and only there
// — the same shim `SoloMatch.swift` uses.
#if canImport(Match)
import Match
#endif
#if canImport(Bot)
import Bot
#endif

import Foundation
import WillagramsRules

/// The live match and the two models built over it, held together for exactly
/// as long as that match lasts.
///
/// ## Why one type
///
/// `MatchBoard` and `MatchHUDModel` are both built *over a session*. Left to
/// the routes, `.countdown` and `.match` would each build their own, and the
/// countdown would then be counting down to a different match than the one that
/// starts. Everything here is constructed once, in one statement, from one
/// ``MatchOpponent`` — so "the same session" is true by construction rather than
/// by every call site remembering to pass one along. Which kind of opponent it
/// is never enters here: solo and online differ in how the opponent was built,
/// not in how this drives it.
///
/// ## What it does not do
///
/// No routing. ``ShellModel`` constructs this, releases it, and owns every
/// transition; the two closures ``results(board:)`` hands the end screen call
/// back into `ShellModel`'s own API rather than assigning a route here.
///
/// ## Staleness
///
/// ``results(board:)`` is a factory and SwiftUI calls a factory again on every
/// re-render, so `ResultsModel`'s own spend-once guard is per screen instance.
/// Both closures are therefore bound to the generation that was live when the
/// screen was built, and no-op once `ShellModel` has built another — an
/// identity check would not do, because `ResultsModel.rematch()` runs teardown
/// first and would then find no live run to match against.
@MainActor
public final class MatchRun {

    /// The far end, whatever it is. Its `session` is the one every screen reads,
    /// and this type never asks which kind of opponent it holds — see the
    /// second initializer.
    public let opponent: any MatchOpponent

    /// The solo match this run was built over, or nil when it was built over an
    /// opponent someone else constructed.
    ///
    /// Implicitly unwrapped, and deliberately: it is the handle the solo suites
    /// reach through for the bot's own half of the wire (`peerTransport`,
    /// `peerTileIDs`, `difficulty`) — things no protocol the shell needs would
    /// carry. Nothing in the app reads it, and reading it on a non-solo run is a
    /// bug that should trap rather than silently pass a nil along. It is set by
    /// the solo initializer, never by a cast.
    public private(set) var match: SoloMatch!

    /// What the board surface draws, kept in step with ``session``.
    public let board: MatchBoard

    /// What the in-match HUD shows and what its controls do.
    public let hud: MatchHUDModel

    /// The word list this run was built against. Held so the three screens read
    /// the list their own match validates with, rather than the root view
    /// reaching for a second one.
    public let dictionary: any WordList

    /// The seed this run was dealt from. Read by `ShellModel` to guarantee the
    /// next run is a different deal, and by tests to prove it.
    public let seed: UInt64

    /// The one session. The opponent owns it; this is the short way to it.
    public var session: MatchSession { opponent.session }

    /// `unowned`, like ``MatchHUDModel``'s: `ShellModel` owns this run, so a
    /// strong reference back would close a cycle that survives the shell being
    /// dropped mid-match. The run cannot outlive its owner, so there is nothing
    /// to unwrap — only the escaping closures in ``results(board:)``, which do
    /// outlive the run by design, capture the shell weakly.
    private unowned let shell: ShellModel

    /// Which `ShellModel` generation built this. See "Staleness" above.
    private let generation: Int

    /// A run over an opponent someone else built — a lobby's `OnlineMatch`, or
    /// a test's double. The opponent must be built *after* the previous run was
    /// torn down; `ShellModel.startMatch(_:opponent:)` is what guarantees that.
    ///
    /// Internal, not public: a run that `ShellModel` did not build is a second
    /// live session, which is the exact thing this type exists to prevent.
    init(
        shell: ShellModel,
        setup: MatchSetup,
        dictionary: any WordList,
        generation: Int,
        opponent: any MatchOpponent
    ) {
        self.shell = shell
        self.generation = generation
        self.seed = setup.seed
        self.dictionary = dictionary
        self.opponent = opponent
        let board = MatchBoard(session: opponent.session, dictionary: dictionary)
        self.board = board
        self.hud = MatchHUDModel(shell: shell, session: opponent.session, board: board)
    }

    /// A run over a solo match this builds itself. The one path that names a
    /// concrete opponent, and the only place ``match`` is set.
    convenience init(
        shell: ShellModel,
        setup: MatchSetup,
        dictionary: any WordList,
        generation: Int,
        difficulty: BotDifficulty? = nil,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        let match = SoloMatch(
            setup: setup, dictionary: dictionary, difficulty: difficulty, sleepFor: sleepFor
        )
        self.init(
            shell: shell, setup: setup, dictionary: dictionary,
            generation: generation, opponent: match
        )
        self.match = match
    }

    /// Opens the match. Separate from `init` so the run is fully assembled — and
    /// observing — before the first tile arrives.
    public func start() { opponent.start() }

    /// Ends the session, cancels the far end's pump and leaves its transport.
    /// Idempotent, so tearing a run down twice cannot reach a live one.
    public func leave() { opponent.leave() }

    /// The end screen for this run, wired to the two ways out.
    ///
    /// Built here so Main Menu and Rematch get the same teardown rather than
    /// each call site assembling its own — and so the closures `ResultsModel`
    /// declares but cannot provide have exactly one implementation.
    public func results(board: Board = Board()) -> ResultsModel {
        let generation = generation
        return ResultsModel(
            shell: shell,
            session: session,
            board: board,
            teardown: { [weak shell] in
                // A gone shell owns no live run, so there is nothing to hold the
                // route back for — only a stale generation declines.
                guard let shell else { return true }
                guard shell.isLiveGeneration(generation) else { return false }
                shell.endSoloPractice()
                return true
            },
            rematch: { [weak shell] in
                guard let shell, shell.isLiveGeneration(generation) else { return }
                // The one construction path, and it tears down before it builds.
                shell.startSoloPractice()
            }
        )
    }
}
