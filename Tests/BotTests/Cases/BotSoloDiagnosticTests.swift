import Foundation
import Testing
import WillagramsRules
import Match
import Bot

/// Not an assertion suite — a diagnostic you can rerun. It plays a whole solo
/// match against each difficulty with the real dictionary and prints what the
/// far end actually did, so "the bot isn't playing" is answered with a number
/// rather than a guess. Pacing is collapsed to zero: `thinkDelay` decides how
/// long a match takes to watch, never whether the bot can play at all.
///
///     swift test --package-path Tests/BotTests --filter BotSoloDiagnosticTests
@MainActor
@Suite("Bot solo diagnostic")
struct BotSoloDiagnosticTests {

    /// One full match. The human is passive but obedient: it takes every tile
    /// it is handed, exactly as a player pressing Draw would, and never plays.
    /// That isolates the far end — anything that stops here is the bot's own.
    static func play(_ difficulty: BotDifficulty, seed: UInt64, ticks: Int) async throws -> String {
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
        let brain = BotBrain(session: match.session, dictionary: dictionary, difficulty: paced)
        let task = Task { await brain.run() }
        defer { task.cancel() }

        var placed = 0
        var pool: [Int] = []
        var placedAtFirstPeel = -1
        // Stop early once nothing has moved for a while: a deadlocked bot would
        // otherwise burn the whole tick budget proving it is still deadlocked.
        var idle = 0
        for _ in 0..<ticks {
            try await Task.sleep(for: .milliseconds(5))
            if human.hasPendingDraw { human.draw() }
            placed = max(placed, match.session.state.board.placementList.count)
            if let remaining = human.poolRemaining, pool.last != remaining {
                if pool.count == 1 { placedAtFirstPeel = placed }
                pool.append(remaining)
            }
            idle = (match.session.state.board.placementList.count == placed) ? idle + 1 : 0
            if human.isMatchOver || idle > 1500 { break }
        }

        let rack = match.session.state.hand.map { String($0.letter) }.joined(separator: ",")
        return """
        \(difficulty.ladderDepth == 3 ? "hard" : difficulty.ladderDepth == 2 ? "medium" : "easy") \
        seed \(seed) — depth \(difficulty.ladderDepth), pace \(difficulty.thinkDelay)
          first peel after \(placedAtFirstPeel) placements (never, if -1)
          board \(placed) tiles · rack [\(rack)] · canDraw \(match.session.canDraw)
          pool \(human.poolRemaining.map(String.init) ?? "—") · exhausted \(human.poolIsExhausted)
          over \(human.isMatchOver) · winner \(human.winner.map(\.rawValue) ?? "none")
        """
    }

    @Test("Diagnostic: what each difficulty actually does")
    func everyDifficulty() async throws {
        for seed: UInt64 in [7, 11] {
            for difficulty in [BotDifficulty.easy, .medium, .hard] {
                print(try await Self.play(difficulty, seed: seed, ticks: 6000))
            }
        }
    }
}
