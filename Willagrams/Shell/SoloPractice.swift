//
//  SoloPractice.swift
//  Willagrams
//
//  The owner of the *current* solo match, and the one place a solo match is
//  built. Starting one and rematching are the same call: a rematch is not a
//  reset, it is another start.
//
//  NO SwiftUI here — see the note in AppRoute.swift. This file is pure state,
//  so it compiles into the macOS `Shell` test target and must NOT be listed in
//  that target's `exclude:`.
//
//  This file must never import GameKit.
//

// `SoloMatch` is `#if DEBUG` because `FakeTransport` is, and this type owns
// one — so it carries the same fence rather than smuggling it past.
#if DEBUG

// The app compiles `Willagrams/Match` and `Willagrams/Shell` into one module,
// where there is nothing to import. `Tests/ShellTests` compiles them as two, so
// the import is real there and only there — the shim `SoloMatch.swift` uses.
#if canImport(Match)
import Match
#endif

import Foundation
import WillagramsRules

/// Owns whichever solo match is currently live, and rebuilds it on a rematch.
///
/// Why a rebuild rather than a reset: ``MatchTransport`` states that each
/// stream has exactly one consumer per endpoint, so a live transport cannot be
/// handed to a second `MatchSession`. A rematch therefore needs a new
/// `FakeTransport.pair`, a new `MatchSession` and a new `HostPool` — which is
/// exactly what a first start builds. There is one construction path here,
/// ``start(seed:)``, and rematch is a call to it.
///
/// The two `PlayerID`s do not change across a rematch: they are
/// `SoloMatch.localPlayerID`/`peerPlayerID`, decided once by the engine's own
/// host election, so host ordering is stable by construction rather than by
/// re-running anything.
@MainActor
public final class SoloPractice {

    /// The live match, or `nil` between one ending and the next starting. The
    /// only strong reference to it, so ``end()`` releases it.
    public private(set) var match: SoloMatch?

    /// The seed the live match was dealt from. Read by tests to prove a rematch
    /// never replays the previous deal.
    public private(set) var seed: UInt64?

    private let shell: ShellModel
    private let dictionary: any WordList
    private let sleepFor: @MainActor @Sendable (Duration) async throws -> Void
    private let seedSource: @MainActor () -> UInt64

    /// Counts matches started. Not `match`'s identity: ``end()`` nils that, and
    /// an end screen's Main Menu runs before its Rematch, so an identity check
    /// would decline the very rematch it was meant to allow. A number that only
    /// ``start()`` moves survives the gap between the two.
    private var generation = 0

    public init(
        shell: ShellModel,
        dictionary: any WordList,
        sleepFor: @escaping @MainActor @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        seedSource: @escaping @MainActor () -> UInt64 = {
            UInt64.random(in: UInt64.min ... UInt64.max)
        }
    ) {
        self.shell = shell
        self.dictionary = dictionary
        self.sleepFor = sleepFor
        self.seedSource = seedSource
    }

    /// Ends whatever is running and starts a fresh match — new transport pair,
    /// new session, new pool, new seed.
    ///
    /// The route is driven through `ShellModel`'s own menu → countdown path, so
    /// a rematch from the end screen takes the same route transition a first
    /// start takes rather than a second one written for it.
    ///
    /// - Parameter explicit: a seed to use instead of the injected source. It is
    ///   still put through the never-repeat rule below, so no caller can hand
    ///   the player the same deal twice running.
    /// - Returns: whether a match was started.
    @discardableResult
    public func start(seed explicit: UInt64? = nil) -> Bool {
        // Down before up: the old stream-iteration task is cancelled here, not
        // left for whenever the old objects happen to deallocate.
        end()

        // A hard guarantee, not a probabilistic one: `.random` can repeat, and
        // an identical pool turns practice into memorising one deal.
        //
        // ponytail: guards the immediately previous seed only, so a source that
        // alternates between two values still deals A, B, A, B. Upgrade to a
        // monotonic counter mixed into the seed if that ever matters — a full
        // history set would grow without bound.
        let candidate = explicit ?? seedSource()
        let fresh = candidate == seed ? candidate &+ 1 : candidate

        shell.returnToMenu()
        shell.startSoloPractice(seed: fresh)
        // `startMatch` only moves from `.menu`, so this is the assertion that
        // the route really did advance rather than silently no-op.
        guard case .countdown(let setup) = shell.route else { return false }

        let started = SoloMatch(setup: setup, dictionary: dictionary, sleepFor: sleepFor)
        match = started
        seed = fresh
        generation &+= 1
        started.start()
        return true
    }

    /// Ends the live match and drops it. A no-op when nothing is running, so
    /// calling it twice cannot tear down a match that has already been replaced.
    public func end() {
        match?.leave()
        match = nil
    }

    /// The end screen for the live match, wired to this owner's two ways out.
    ///
    /// Built here so Main Menu and Rematch get the same teardown, rather than
    /// each call site assembling its own.
    ///
    /// Both closures are bound to the generation that was live when the screen
    /// was built and no-op once it has been replaced. This is a factory, and
    /// SwiftUI calls a factory again on every re-render — so `ResultsModel`'s
    /// own spend-once guard is per screen instance and cannot be relied on to
    /// stop a stale screen ending or rebuilding over the match that replaced it.
    public func results(board: Board = Board()) -> ResultsModel? {
        guard let match else { return nil }
        let generation = generation
        return ResultsModel(
            shell: shell,
            session: match.session,
            board: board,
            teardown: { [weak self] in
                guard let self, self.generation == generation else { return false }
                self.end()
                return true
            },
            rematch: { [weak self] in
                guard let self, self.generation == generation else { return }
                self.start()
            }
        )
    }
}

#endif
