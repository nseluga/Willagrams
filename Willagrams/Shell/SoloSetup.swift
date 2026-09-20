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
#if canImport(Settings)
import Settings
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
/// The match rules themselves are not re-modelled here: they are a
/// ``MatchOptionsForm``, the settings lane's own type, seeded from the injected
/// ``SettingsStore`` on every entry to the screen and written back on Start. The
/// host lobby reads the same store, so a host plays under the rules last chosen
/// for solo. Only what the settings lane does not model — the opponent and the
/// starting hand — is state of this screen's own.
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

    /// The rules half of the screen, as the settings lane models it. Nil only
    /// before the first entry, and after a bundled-word-list read that failed —
    /// ``loadOptions()`` retries on the next entry, and ``options`` falls back
    /// to what the store holds meanwhile.
    ///
    /// ponytail: built once per screen, not once per app: `MatchOptionsForm`
    /// hashes the whole word list on init, so re-entering reuses the built form
    /// and only re-seeds its values. Memoize `DictionaryCatalogue.entry` if that
    /// first entry ever reads as a hitch.
    public var optionsForm: MatchOptionsForm?

    @ObservationIgnored private let store: SettingsStore?

    public init(store: SettingsStore? = nil) {
        self.store = store
    }

    /// Entry: builds the form the first time and seeds it from the store.
    public func loadOptions() {
        guard var form = optionsForm ?? (try? MatchOptionsForm()) else { return }
        let stored = store?.load() ?? .standard
        form.swapEnabled = stored.swapEnabled
        form.minimumWordLength = stored.minimumWordLength
        try? form.selectDictionary(stored.dictionaryID)
        optionsForm = form
    }

    /// Start: the chosen rules become the ones the next launch — and the next
    /// host lobby — opens with.
    public func saveOptions(_ options: MatchOptions) {
        store?.save(options)
    }

    /// The rules these choices add up to, ready to travel on `.start`.
    ///
    /// The dictionary is not offered: exactly one word list ships, so a picker
    /// with one row is a control that cannot be wrong and cannot be useful.
    /// `DictionaryCatalogue` is where a second entry would go, and the picker
    /// belongs beside it on the day there is one.
    public var options: MatchOptions {
        (optionsForm?.options ?? store?.load() ?? .standard).validated
    }

    // MARK: - Chrome

    /// Local chrome, not `Terminology`: that file is the frozen IP fence and
    /// names game concepts, not screens.
    public static let title = "Solo Practice"
    public static let startLabel = "Start"
    public static let backLabel = "Back"
    public static let opponentLabel = "Opponent"
    public static let handSizeLabel = "Starting tiles"
}
