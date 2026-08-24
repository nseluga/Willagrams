//
//  BotPlaysTests.swift
//  ShellTests
//
//  The one check that answers "is the bot actually playing?" against the real
//  bundled dictionary and the real shipped hand size. Every other bot test runs
//  a toy list; this one runs what the player runs.
//

import Foundation
import Testing
import WillagramsRules
@testable import Bot
@testable import Match
@testable import Shell

@MainActor
@Suite("The bot plays for real")
struct BotPlaysTests {

    /// Proves the two things a motionless pool would disprove: the far end lays
    /// tiles of its own, and it spends pool tiles doing it.
    ///
    /// The think delay is taken to zero so this measures the search rather than
    /// the pacing — at the shipped `medium` delay the same run takes ~13s.
    ///
    /// Deliberately NOT an assertion that the bot wins. It reliably reaches a
    /// single cluster and a first draw within a second, and then stalls on a
    /// rack it cannot rebuild into a complete grid. See the note in
    /// ``BotBrain`` about the stall floor.
    @Test("The far end lays tiles and spends the pool")
    func botPlaysAndDraws() async throws {
        let dictionary = (try? EnableWordList()) ?? EnableWordList(words: [])
        #expect(dictionary.count > 0, "the bundled list failed to load")

        let fast = BotDifficulty(ladderDepth: 2, thinkDelay: .zero, stallFloorTicks: 6)
        let setup = MatchSetup(
            seed: 20260817,
            startingHandSize: ShellModel.soloHandSize,
            countdownSeconds: 0
        )
        let solo = SoloMatch(setup: setup, dictionary: dictionary, difficulty: fast, sleepFor: { _ in })
        solo.start()

        let dealt = ShellModel.soloHandSize * 2
        let afterDeal = LetterDistribution.totalTiles - dealt

        try await SoloMatchTests.waitUntil("the bot to lay a word", within: .seconds(20)) {
            solo.bot.session.state.board.placementList.count >= 2
        }
        try await SoloMatchTests.waitUntil("the bot to draw", within: .seconds(20)) {
            (solo.session.poolRemaining ?? afterDeal) < afterDeal
        }

        let board = solo.bot.session.state.board
        #expect(board.clusters.count == 1, "the bot left its tiles scattered")
        #expect(solo.session.pendingDrawTiles.isEmpty == false, "the bot's draw owed this end nothing")

        solo.leave()
    }

    /// Proves the presets are ordered by *strength*, not only by pace.
    ///
    /// The three differ in two ways at once — how deep the move ladder goes and
    /// how long the bot pauses between placements — and at shipped pacing the
    /// pause dominates: in five real seconds easy lays ~3 tiles, medium ~7 and
    /// hard ~18, which is exactly the ratio of their think delays and says
    /// nothing about the search. So the delay is taken out here and only the
    /// ladder is left, which is the thing a player would call difficulty.
    ///
    /// Measured in draws rather than placements: laying tiles is what a stuck
    /// bot keeps doing, and taking a fresh one is what only a bot that finished
    /// a whole valid board can do. Totalled across seeds, never compared seed by
    /// seed — one lucky rack lets even the shallowest bot run.
    ///
    /// Easy and medium are deliberately NOT compared. They measure the same at
    /// this budget: rung 3, the swap, is what actually unsticks a bot, and
    /// medium cannot reach it.
    @Test("A harder preset is a stronger player, not just a faster one")
    func harderPresetsPlayBetter() async throws {
        let dictionary = (try? EnableWordList()) ?? EnableWordList(words: [])
        let seeds: [UInt64] = [11, 22, 33]

        func draws(at preset: BotDifficulty) async throws -> Int {
            var total = 0
            for seed in seeds {
                let setup = MatchSetup(
                    seed: seed,
                    startingHandSize: ShellModel.soloHandSize,
                    countdownSeconds: 0
                )
                let solo = SoloMatch(
                    setup: setup, dictionary: dictionary, difficulty: preset, sleepFor: { _ in }
                )
                solo.start()
                try await Task.sleep(for: .seconds(Self.budget))
                let dealt = ShellModel.soloHandSize * 2
                let left = solo.session.poolRemaining ?? (LetterDistribution.totalTiles - dealt)
                // One draw event spends one tile per player, so the pool falls
                // by two for every round either end took.
                total += (LetterDistribution.totalTiles - dealt - left) / 2
                solo.leave()
            }
            return total
        }

        let easy = try await draws(at: BotDifficulty(ladderDepth: 0, thinkDelay: .zero, stallFloorTicks: 12))
        let hard = try await draws(at: BotDifficulty(ladderDepth: 3, thinkDelay: .zero, stallFloorTicks: 3))

        #expect(
            hard > Int(Double(easy) * Self.margin),
            "hard drew \(hard) rounds to easy's \(easy) — the ladder is not buying strength"
        )
    }

    /// Real seconds each preset gets per seed. Small enough to keep the suite
    /// quick, long enough that the gap it measures is threefold rather than
    /// marginal.
    static let budget: Double = 1

    /// How much better hard has to be before this test believes it. Measured at
    /// roughly 3.5x, so this leaves room for a slow machine without accepting a
    /// tie.
    static let margin = 1.5
}
