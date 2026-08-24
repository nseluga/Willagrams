//
//  SoloSetup.swift
//  Willagrams
//
//  Everything the solo setup screen offers and every bound on it, as state a
//  test can execute. `SoloSetupView` renders this and decides nothing.
//
//  NO SwiftUI here — see the note in AppRoute.swift. Pure state, so it compiles
//  into the macOS `Shell` test target and must NOT be listed in that target's
//  `exclude:`.
//
//  This file must never import GameKit.
//

// The app compiles `Willagrams/Bot` into the same module as the shell, where
// there is nothing to import. `Tests/ShellTests` compiles it as a separate one,
// so this import is real there and only there.
#if canImport(Bot)
import Bot
#endif
#if canImport(Style)
import Style
#endif

import Observation
import WillagramsRules

/// What the player has chosen for the next solo match.
///
/// Owned by ``ShellModel`` rather than by the screen: the settings outlive the
/// screen, so backing out to the menu and coming in again shows what was chosen
/// last time rather than the defaults again.
///
/// Every bound lives here. The view sets values and checks none of them, so a
/// control that forgets its own limits still cannot produce a setup outside
/// them — the same rule `MatchOptionsForm` follows for the host's options, and
/// the reason both clamp on write rather than at the point of use.
///
/// ponytail: nothing here is persisted across launches. `SettingsStore` already
/// stores a `MatchOptions` and could store this one, but a solo player choosing
/// a difficulty once per session is not a complaint anyone has made. Wire it in
/// when a second screen wants the same values.
@MainActor
@Observable
public final class SoloSetup {

    /// The presets, and the copy that names them. Straight from
    /// ``BotDifficultyMenu``, which already owns that list — a second list here
    /// could only start to disagree with the one the bot screen draws.
    public static var difficulties: [BotDifficultyChoice] { BotDifficultyMenu.choices }

    /// Which preset is chosen. The app's default until a player moves it.
    public var difficulty: BotDifficulty = ShellModel.soloDifficulty

    /// How many tiles each player opens with. Clamped on write.
    ///
    /// The ceiling is not cosmetic: `HostPool` deals `handSize` to *both*
    /// players out of one 144-tile pool, so a hand over 72 cannot be dealt at
    /// all. Half of what is left over after the deal is what a solo player has
    /// to draw with, so the ceiling here leaves a real game behind it.
    /// A computed setter, not a `didSet`: `@Observable` routes every stored
    /// write through its registrar, so a `didSet` that re-assigns its own
    /// property re-enters itself until the stack runs out. Clamping in the
    /// setter is the same rule with no recursion to have.
    public var handSize: Int {
        get { storedHandSize }
        set { storedHandSize = min(max(Self.handSizeRange.lowerBound, newValue), Self.handSizeRange.upperBound) }
    }

    private var storedHandSize = ShellModel.soloHandSize

    public static let handSizeRange = 5...40

    /// Whether ``Terminology/swap`` is offered at all. Rides to the host as
    /// part of ``options``, which is what actually refuses the request.
    public var swapEnabled: Bool = MatchOptions.standard.swapEnabled

    /// Shortest word the board will accept. Clamped to the engine's own range
    /// on write, so the screen cannot describe a rule the engine would reject.
    public var minimumWordLength: Int {
        get { storedMinimumWordLength }
        set {
            storedMinimumWordLength = min(
                max(MatchOptions.lengthRange.lowerBound, newValue),
                MatchOptions.lengthRange.upperBound
            )
        }
    }

    private var storedMinimumWordLength = MatchOptions.standard.minimumWordLength

    public init() {}

    /// The rules these choices add up to, ready to travel on `.start`.
    ///
    /// The dictionary is not offered: exactly one word list ships, so a picker
    /// with one row is a control that cannot be wrong and cannot be useful.
    /// `DictionaryCatalogue` is where a second entry would go, and the picker
    /// belongs beside it on the day there is one.
    public var options: MatchOptions {
        MatchOptions(
            minimumWordLength: minimumWordLength,
            swapEnabled: swapEnabled,
            dictionaryID: MatchOptions.standardDictionaryID,
            dictionaryHash: MatchOptions.standardDictionaryHash
        ).validated
    }

    // MARK: - Chrome

    /// Local chrome, not `Terminology`: that file is the frozen IP fence and
    /// names game concepts, not screens.
    public static let title = "Solo Practice"
    public static let startLabel = "Start"
    public static let backLabel = "Back"
    public static let opponentLabel = "Opponent"
    public static let handSizeLabel = "Starting tiles"
    public static let swapLabel = "Allow \(Terminology.swap)"
    public static let minimumWordLengthLabel = "Shortest word"
}
