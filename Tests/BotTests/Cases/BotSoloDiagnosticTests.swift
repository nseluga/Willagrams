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
/// The brain runs at its real pace and never actually sleeps: the sleep seam
/// adds up what it was *asked* to wait for and returns at once. That is what
/// makes the reported duration honest without waiting half an hour for an easy
/// bot — and it is the only way to report one at all now that pacing varies,
/// since ticks × `thinkDelay` stopped being the length of a match the moment a
/// pause could be three times its base.
///
///     swift test --package-path Tests/BotTests --filter BotSoloDiagnosticTests
@MainActor
@Suite("Bot solo diagnostic")
struct BotSoloDiagnosticTests {

    /// Adds up the brain's own sleeps without serving any of them.
    actor Ticks {
        private(set) var count = 0
        private(set) var waited = Duration.zero
        private(set) var longest = Duration.zero
        private(set) var shortest = Duration.seconds(3600)
        func bump(_ pause: Duration) {
            count += 1
            waited += pause
            longest = max(longest, pause)
            shortest = min(shortest, pause)
        }
    }

    /// What one match cost, separated into the two things that decide it: how
    /// many decisions the bot had to make, and how long each one took to reach.
    struct Run {
        var label: String
        var seed: UInt64
        var ticks: Int
        var placed: Int
        var compute: Duration
        var paced: Duration
        var shortest: Duration
        var longest: Duration
        /// Paced gaps between the pool falling — the only thing about the bot's
        /// speed a player can actually see, since the opponent's board is not on
        /// screen. Every other number here is about work they never watch.
        var peelGaps: [Duration]

        var meanPeelGap: Duration {
            guard !peelGaps.isEmpty else { return .zero }
            return peelGaps.reduce(.zero, +) / peelGaps.count
        }
        var over: Bool
        var winner: String
        var pool: String
        var rack: String
        var firstPeel: Int

        /// Every pause the bot asked for, plus what the search actually cost.
        /// This is the number a player experiences.
        var wallClock: Duration { paced + compute }
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
        let counter = Ticks()
        let brain = BotBrain(
            session: match.session,
            dictionary: dictionary,
            difficulty: difficulty,
            sleepFor: { await counter.bump($0) }
        )
        let started = ContinuousClock.now
        let task = Task { await brain.run() }
        defer { task.cancel() }

        var placed = 0
        var pool: [Int] = []
        var firstPeel = -1
        var peelGaps: [Duration] = []
        var lastPeelAt = Duration.zero
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
                let now = await counter.waited
                if pool.count > 2 { peelGaps.append(now - lastPeelAt) }
                lastPeelAt = now
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
            paced: await counter.waited,
            shortest: await counter.shortest,
            longest: await counter.longest,
            peelGaps: peelGaps,
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
                \(run.label) seed \(run.seed) — \(run.ticks) ticks \
                → about \(run.wallClock) to watch
                  pauses \(run.shortest) … \(run.longest)
                  pool falls every \(run.meanPeelGap) on average \
                  (\(run.peelGaps.min() ?? .zero) … \(run.peelGaps.max() ?? .zero))
                  board \(run.placed) tiles · first peel after \(run.firstPeel) placements \
                  · rack [\(run.rack)] · pool \(run.pool)
                  over \(run.over) · winner \(run.winner) · search cost \(run.compute)
                """)
            }
        }
    }
}
