import Foundation
import Testing
import WillagramsRules
import Match
@testable import Bot

/// The bot's rhythm.
///
/// Every other suite drives the brain at `thinkDelay: .zero`, which is right —
/// a test that slept real milliseconds could not play a match. But it also
/// means every other suite would pass unchanged if the pacing collapsed back to
/// a metronome, and a metronome is what made the bot read as a script rather
/// than a person. This suite is the one place the *durations* are looked at.
///
/// It never sleeps them: the sleep seam records what it was asked to wait and
/// returns at once, so a hundred paced ticks cost nothing.
@MainActor
@Suite("Bot pacing")
struct BotPacingTests {

    /// Collects what the brain asked to wait for, without waiting.
    actor Pauses {
        private(set) var all: [Duration] = []
        func add(_ pause: Duration) { all.append(pause) }
    }

    /// Plays a real solo match at a real pace and returns every pause the brain
    /// asked for along the way.
    static func pauses(of difficulty: BotDifficulty, atLeast wanted: Int) async throws -> [Duration] {
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
        human.startMatch(seed: 23, startingHandSize: 21, countdownSeconds: 0)

        let log = Pauses()
        let brain = BotBrain(
            session: match.session,
            dictionary: dictionary,
            difficulty: difficulty,
            sleepFor: { await log.add($0) }
        )
        let task = Task { await brain.run() }
        defer { task.cancel() }

        for _ in 0..<4_000 {
            try await Task.sleep(for: .milliseconds(2))
            if human.hasPendingDraw { human.draw() }
            if await log.all.count >= wanted { break }
        }
        return await log.all
    }

    @Test("The pause between moves is never the same number twice running")
    func theRhythmVaries() async throws {
        let base = Duration.milliseconds(500)
        let difficulty = BotDifficulty(
            ladderDepth: 2, thinkDelay: base, stallFloorTicks: 6, pacing: 0.45...4.0
        )
        let pauses = try await Self.pauses(of: difficulty, atLeast: 60)
        try #require(pauses.count >= 60, "the brain did not tick enough to judge its rhythm")

        // The failure this guards is not "the numbers are wrong". It is the
        // bot going back to placing a tile every 500ms forever, which every
        // other suite would happily pass.
        #expect(Set(pauses).count > pauses.count / 3, "the pacing is a metronome")

        // Both sides of the base, because a rhythm that only ever hurries or
        // only ever drags is still one speed.
        #expect(pauses.contains { $0 < base }, "the bot never once got going")
        #expect(pauses.contains { $0 > base }, "the bot never once hesitated")

        // And the swing is wide enough to read as an opponent having an easier
        // or a harder time of it. Jitter alone would clear the checks above and
        // still look like a clock with a slight wobble; only the moods put a
        // multiple between the bot's best stretch and its worst.
        let widest = try #require(pauses.max()), narrowest = try #require(pauses.min())
        #expect(widest > narrowest * 3, "the rhythm wobbles but never changes gear")

        // And inside the clamp, so no preset can drift into looking frozen or
        // into emptying its rack faster than a player can read it.
        #expect(pauses.allSatisfy { $0 >= base * 0.45 && $0 <= base * 4.0 })
    }

    @Test("A preset with no room to vary still plays at its own pace")
    func aPinnedRangeIsHonoured() async throws {
        let base = Duration.milliseconds(400)
        let difficulty = BotDifficulty(
            ladderDepth: 2, thinkDelay: base, stallFloorTicks: 6, pacing: 1...1
        )
        let pauses = try await Self.pauses(of: difficulty, atLeast: 40)
        try #require(pauses.count >= 40)
        #expect(pauses.allSatisfy { $0 == base }, "the clamp is not the last word on the pause")
    }
}
