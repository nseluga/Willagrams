//
//  SoloSetupTests.swift
//  ShellTests
//
//  The setup screen is SwiftUI and cannot be built on macOS, so what is
//  asserted here is everything that is not the drawing: the bounds, which live
//  on `SoloSetup`, and the route, which lives on `ShellModel`.
//

import Foundation
import Testing
import WillagramsRules
@testable import Bot
@testable import Match
@testable import Shell
import Style

@MainActor
@Suite("Solo setup")
struct SoloSetupTests {

    @Test("The menu reaches the setup screen, and only the menu does")
    func onlyTheMenuReachesIt() {
        let shell = ShellModel()
        shell.showSoloSetup()
        #expect(shell.route == .soloSetup)

        let setup = MatchSetup(seed: 1, startingHandSize: 21, countdownSeconds: 3)
        for route in [AppRoute.countdown(setup), .match(setup), .results(winner: nil), .howToPlay] {
            let other = ShellModel(route: route)
            other.showSoloSetup()
            #expect(other.route == route, "showSoloSetup moved the route away from \(route)")
        }
    }

    @Test("Every bound is enforced on write, not at the point of use")
    func boundsClampOnWrite() {
        let settings = SoloSetup()

        settings.handSize = 1
        #expect(settings.handSize == SoloSetup.handSizeRange.lowerBound)
        settings.handSize = 999
        #expect(settings.handSize == SoloSetup.handSizeRange.upperBound)

        settings.minimumWordLength = 1
        #expect(settings.minimumWordLength == MatchOptions.lengthRange.lowerBound)
        settings.minimumWordLength = 99
        #expect(settings.minimumWordLength == MatchOptions.lengthRange.upperBound)
    }

    @Test("The options carry the choices, under the shipped word list")
    func optionsCarryTheChoices() {
        let settings = SoloSetup()
        settings.swapEnabled = false
        settings.minimumWordLength = 4

        #expect(settings.options.swapEnabled == false)
        #expect(settings.options.minimumWordLength == 4)
        // The dictionary is not offered, so it can never disagree with its hash.
        #expect(settings.options.dictionaryID == MatchOptions.standardDictionaryID)
        #expect(settings.options.dictionaryHash == MatchOptions.standardDictionaryHash)
        #expect(settings.options == settings.options.validated)
    }

    @Test("Starting from the screen plays the match that was configured")
    func startUsesTheChoices() throws {
        let shell = ShellModel(dictionary: { SoloMatchTests.EveryWordIsReal() })
        shell.showSoloSetup()
        shell.soloSetup.difficulty = BotDifficulty.hard
        shell.soloSetup.handSize = 9
        shell.soloSetup.swapEnabled = false

        #expect(shell.startSoloPractice(seed: 4242))
        let run = try #require(shell.run)
        #expect(run.match.difficulty == BotDifficulty.hard)
        guard case let .countdown(setup) = shell.route else {
            Issue.record("the start left the route somewhere other than the countdown")
            return
        }
        #expect(setup.startingHandSize == 9)
        #expect(setup.options.swapEnabled == false)

        shell.returnToMenu()
    }

    /// The settings outlive the screen: backing out and coming in again shows
    /// what was chosen, not the defaults.
    @Test("Choices survive a trip back to the menu")
    func choicesOutliveTheScreen() {
        let shell = ShellModel()
        shell.showSoloSetup()
        shell.soloSetup.handSize = 12
        shell.returnToMenu()
        shell.showSoloSetup()
        #expect(shell.soloSetup.handSize == 12)
    }

    @Test("The three presets are offered, in one place")
    func presetsComeFromTheBotsOwnList() {
        #expect(SoloSetup.difficulties.count == BotDifficultyMenu.choices.count)
        #expect(SoloSetup.difficulties.map(\.difficulty) == [.easy, .medium, .hard])
    }
}
