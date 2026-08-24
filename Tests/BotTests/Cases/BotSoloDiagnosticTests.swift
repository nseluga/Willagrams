import Foundation
import Testing
import WillagramsRules
import Match
import Bot

/// Not an assertion suite — a diagnostic you can rerun. It plays a whole solo
/// match against each difficulty with the real dictionary and prints what the
/// far end actually did, so "the bot isn't playing" is answered with a number
/// rather than a guess.
///
/// Pacing is collapsed to zero so a match takes milliseconds to play, but the
/// ticks are *counted* through the brain's sleep seam and multiplied by the
/// preset's real `thinkDelay` afterwards. That is what makes the reported
/// duration honest without waiting half an hour for an easy bot: a tick is a
/// tick whether it was slept through or not.
///
///     swift test --package-path Tests/BotTests --filter BotSoloDiagnosticTests
@MainActor
@Suite("Bot solo diagnostic")
struct BotSoloDiagnosticTests {

    /// Counts the brain's ticks from inside its own sleep.
    actor Ticks {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    /// What one match cost, separated into the two things that decide it: how
    /// many decisions the bot had to make, and how long each one took to reach.
    struct Run {
        var label: String
        var seed: UInt64
        var ticks: Int
        var placed: Int
        var compute: Duration
        var pace: Duration
        var over: Bool
        var winner: String
        var pool: String
        var rack: String
        var firstPeel: Int

        /// Ticks at the preset's real pace, plus what the search actually cost.
        /// This is the number a player experiences.
        var wallClock: Duration { (pace + compute / max(ticks, 1)) * ticks }
    }

    /// One full match. The human is passive but obedient: it takes every tile
    /// it is handed, exactly as a player pressing Draw would, and never plays.
    /// That isolates the far end — anything that stops here is the bot's own.
    static func play(_ difficulty: BotDifficulty, seed: UInt64, ticks limit: Int) async throws -> Run {
        let dictionary = try EnableWordList()
        let match = BotMatch(dictionary: dictionary, sleepFor: { _ in })
        defer { match.leave() }
        let human = MatchSession(
            transport: match.humanTransport,
            peerPlayerID: BotMatch.botPlayerID,
            dictionary: dictionary,
            sleepFor: { _ in }
        )
        defer { human.leave() }

        human.startMatch(seed: seed, startingHandSize: 21, countdownSeconds: 0)
        var paced = difficulty
        paced.thinkDelay = .zero
        let counter = Ticks()
        let brain = BotBrain(
            session: match.session,
            dictionary: dictionary,
            difficulty: paced,
            sleepFor: { _ in await counter.bump() }
        )
        let started = ContinuousClock.now
        let task = Task { await brain.run() }
        defer { task.cancel() }

        var placed = 0
        var pool: [Int] = []
        var firstPeel = -1
        // Give up only after the *bot* has taken a run of ticks that changed
        // nothing. Counting wall-clock polls instead would call a slow preset
        // deadlocked purely for being slow: a depth-2 tick runs a 20,000
        // validation rebuild, so medium takes seconds to do what hard does in
        // one, and a poll-based cutoff cuts it off mid-recovery.
        var idleSince = 0
        for _ in 0..<limit {
            try await Task.sleep(for: .milliseconds(5))
            if human.hasPendingDraw { human.draw() }
            let ticked = await counter.count
            let now = match.session.state.board.placementList.count
            if now != placed { idleSince = ticked }
            placed = max(placed, now)
            if let remaining = human.poolRemaining, pool.last != remaining {
                if pool.count == 1 { firstPeel = placed }
                pool.append(remaining)
            }
            if human.isMatchOver || ticked - idleSince > 900 { break }
        }
        let compute = ContinuousClock.now - started

        return Run(
            label: difficulty.ladderDepth == 3 ? "hard" : difficulty.ladderDepth == 2 ? "medium" : "easy",
            seed: seed,
            ticks: await counter.count,
            placed: placed,
            compute: compute,
            pace: difficulty.thinkDelay,
            over: human.isMatchOver,
            winner: human.winner.map(\.rawValue) ?? "none",
            pool: human.poolRemaining.map(String.init) ?? "—",
            rack: match.session.state.hand.map { String($0.letter) }.joined(separator: ","),
            firstPeel: firstPeel
        )
    }

    @Test("Diagnostic: what each difficulty actually does, and how long it takes")
    func everyDifficulty() async throws {
        for seed: UInt64 in [7, 11, 23, 42] {
            for difficulty in [BotDifficulty.easy, .medium, .hard] {
                let run = try await Self.play(difficulty, seed: seed, ticks: 24_000)
                print("""
                \(run.label) seed \(run.seed) — \(run.ticks) ticks at \(run.pace) \
                → about \(run.wallClock) to watch
                  board \(run.placed) tiles · first peel after \(run.firstPeel) placements \
                  · rack [\(run.rack)] · pool \(run.pool)
                  over \(run.over) · winner \(run.winner) · search cost \(run.compute)
                """)
            }
        }
    }
}
