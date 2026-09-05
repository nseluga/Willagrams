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
import Settings
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

    @Test("The starting hand is bounded on write, not at the point of use")
    func boundsClampOnWrite() {
        let settings = SoloSetup()

        settings.handSize = 1
        #expect(settings.handSize == SoloSetup.handSizeRange.lowerBound)
        settings.handSize = 999
        #expect(settings.handSize == SoloSetup.handSizeRange.upperBound)
    }

    /// The rules half is the settings lane's form, not a second model of the
    /// same values: the screen's options are whatever that form produces, and
    /// its bounds are the ones that hold.
    @Test("The options carry the form's choices, under the shipped word list")
    func optionsCarryTheChoices() throws {
        let settings = SoloSetup()
        settings.loadOptions()
        var form = try #require(settings.optionsForm, "entry did not build the form")

        form.swapEnabled = false
        form.minimumWordLength = 4
        settings.optionsForm = form
        #expect(settings.options.swapEnabled == false)
        #expect(settings.options.minimumWordLength == 4)

        // The form's clamp is the one in force — the screen adds none of its own.
        settings.optionsForm?.minimumWordLength = 99
        #expect(settings.options.minimumWordLength == MatchOptions.lengthRange.upperBound)

        // The dictionary is not offered, so it can never disagree with its hash.
        #expect(settings.options.dictionaryID == MatchOptions.standardDictionaryID)
        #expect(settings.options.dictionaryHash == MatchOptions.standardDictionaryHash)
        #expect(settings.options == settings.options.validated)
    }

    /// A named suite of its own per test, torn down after: `UserDefaults` is
    /// global, and a leaked key would surface as a failure in another file.
    static func store(_ name: String) -> (SettingsStore, UserDefaults, String) {
        let suite = "solo-setup-tests-\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SettingsStore(defaults: defaults), defaults, suite)
    }

    // MARK: - done when 1

    @Test("An option changed in solo setup and started is what the next launch opens on")
    func changedOptionsSurviveARebuildOnTheSameSuite() throws {
        let (settings, defaults, suite) = Self.store("rebuild")
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = ShellModel(
            dictionary: { SoloMatchTests.EveryWordIsReal() },
            sleepFor: { _ in },
            services: ShellServices(settings: settings)
        )
        first.showSoloSetup()
        #expect(try #require(first.soloSetup.optionsForm).swapEnabled)
        first.soloSetup.optionsForm?.swapEnabled = false
        first.soloSetup.optionsForm?.minimumWordLength = 7
        #expect(first.startSoloPractice(seed: 77))
        first.returnToMenu()

        // A second model, same suite: entry reads what Start wrote.
        let second = ShellModel(
            dictionary: { SoloMatchTests.EveryWordIsReal() },
            sleepFor: { _ in },
            services: ShellServices(settings: settings)
        )
        second.showSoloSetup()
        let reopened = try #require(second.soloSetup.optionsForm)
        #expect(reopened.swapEnabled == false)
        #expect(reopened.minimumWordLength == 7)
        #expect(second.soloSetup.options.swapEnabled == false)
        #expect(second.soloSetup.options.minimumWordLength == 7)
    }

    // MARK: - done when 2

    @Test("The lobby hosts under the rules solo setup last saved")
    func theLobbyHostsUnderTheRulesSoloSaved() async throws {
        let (settings, defaults, suite) = Self.store("lobby")
        defer { defaults.removePersistentDomain(forName: suite) }

        let f = try await HostLobbyTests.make(settings: settings)
        f.shell.showSoloSetup()
        f.shell.soloSetup.optionsForm?.swapEnabled = false
        f.shell.soloSetup.optionsForm?.minimumWordLength = 6
        #expect(f.shell.startSoloPractice(seed: 88))
        f.shell.returnToMenu()

        #expect(f.shell.playAFriend())
        let lobby = try #require(f.shell.hostLobby)
        await HostLobbyTests.until("the lobby exists") { lobby.phase == .waiting }

        let matchID = try #require(lobby.match?.record.id)
        let record = try #require(await f.backend.matchRecord(matchID))
        #expect(record.options.swapEnabled == false)
        #expect(record.options.minimumWordLength == 6)

        lobby.cancel()
    }

    @Test("Starting from the screen plays the match that was configured")
    func startUsesTheChoices() throws {
        // `sleepFor` injected as every other solo test does. Every assertion
        // below runs before the first suspension, so the clock changes nothing
        // this test measures — but a default `ShellModel` leaves a wall-clock
        // countdown ticking past the end of the test, and the session
        // cancelling that sleep as it is torn down aborts the whole process.
        let shell = ShellModel(
            dictionary: { SoloMatchTests.EveryWordIsReal() }, sleepFor: { _ in }
        )
        shell.showSoloSetup()
        shell.soloSetup.difficulty = BotDifficulty.hard
        shell.soloSetup.handSize = 9
        shell.soloSetup.optionsForm?.swapEnabled = false

        #expect(shell.startSoloPractice(seed: 4242))
        let run = try #require(shell.run)
        #expect(run.match.difficulty == BotDifficulty.hard)
        guard case let .countdown(setup) = shell.route else {
            Issue.record("the start left the route somewhere other than the countdown")
            return
        }
        #expect(setup.startingHandSize == 9)
        #expect(setup.options.swapEnabled == false)
        // What travels is the form's options, put through the engine's own rule.
        #expect(setup.options == shell.soloSetup.options)
        #expect(setup.options == setup.options.validated)

        shell.returnToMenu()
    }

    /// The engine's own rule is the last one applied, on whatever the form — or
    /// a caller — produced. The form clamps too, so this drives the one path
    /// that can still hand the match options it did not build.
    @Test("Options are validated before they reach the match, whoever produced them")
    func optionsAreValidatedBeforeTheMatch() throws {
        let (settings, defaults, suite) = Self.store("validated")
        defer { defaults.removePersistentDomain(forName: suite) }

        let shell = ShellModel(
            dictionary: { SoloMatchTests.EveryWordIsReal() },
            sleepFor: { _ in },
            services: ShellServices(settings: settings)
        )
        let unchecked = MatchOptions(
            minimumWordLength: 99,
            swapEnabled: false,
            dictionaryID: MatchOptions.standardDictionaryID,
            dictionaryHash: MatchOptions.standardDictionaryHash
        )
        #expect(unchecked != unchecked.validated, "pick options the engine would actually change")
        #expect(shell.startSoloPractice(seed: 99, options: unchecked))

        guard case let .countdown(setup) = shell.route else {
            Issue.record("the start left the route somewhere other than the countdown")
            return
        }
        #expect(setup.options == unchecked.validated)
        #expect(setup.options.minimumWordLength == MatchOptions.lengthRange.upperBound)
        // And what was stored is the validated form, not the raw one.
        #expect(settings.load() == unchecked.validated)

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
