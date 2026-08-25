# Willagrams — Lane: audio

Round 2. The playback seam was frozen by `/foundation` as
`Willagrams/Audio/AudioPlayer.swift` and has shipped as a no-op ever since:
`SilentAudioPlayer` is the value every screen would hold, and no screen holds
one yet. This lane builds the player that actually makes a sound.

Lane: audio — Sound and haptics — tile placement, draw, win and loss cues, menu
feedback, a mute control, and respecting the system silent switch.

Owned — this lane's items live inside these paths:
  Willagrams/Audio/**
  Tests/AudioTests/**

Open — merged lanes. Wiring items may edit these; rebase onto `integration` first:
  Willagrams/Style/**, Willagrams/Resources/Branding/**, Willagrams/Assets.xcassets/**, Tests/StyleTests/**, docs/ip-review.md
  Willagrams/Board/**, Tests/BoardTests/**
  Willagrams/Match/**, Tests/MatchTests/**
  Willagrams/Settings/**, Tests/SettingsTests/**
  Willagrams/Shell/**, Willagrams/App/**, Tests/ShellTests/**
  Willagrams/Bot/**, Tests/BotTests/**

Stop and report if an item requires changing a path outside both lists:
  protected — Sources/WillagramsRules/**, Tests/WillagramsRulesTests/**, Willagrams/Match/MatchTransport.swift, Willagrams/Style/DesignTokens.swift, Willagrams/Style/Terminology.swift, Willagrams.entitlements, Package.swift, supabase/migrations/**, Willagrams/Online/BackendContracts.swift, Willagrams/Audio/AudioPlayer.swift
  an unmerged lane's — Willagrams/Online/**, Tests/OnlineTests/**, supabase/**, Willagrams/Account/**, Tests/AccountTests/**, Willagrams/Friends/**, Tests/FriendsTests/**, fastlane/**, docs/store/**
  unowned — `.` (repo root), `.claude/**`, `docs/*.md` except `docs/ip-review.md` and `docs/store/**`, `progress/**`, `Sources/WillagramsRules/**`, `Tests/WillagramsRulesTests/**`, `Willagrams.xcodeproj/**`

Frozen contracts — build and test against these; they will not move:
  style — `Willagrams/Style/DesignTokens.swift` (`Motion.snapDuration = 0.16`, `Motion.dealDuration = 0.45`)
  the seam — `Willagrams/Audio/AudioPlayer.swift` (`SoundEffect` ×9, `HapticStrength`, `protocol AudioPlayer`, `SilentAudioPlayer`), fixture `Tests/AudioTests/Cases/AudioSeamTests.swift`

Test against the fixture, not the producing lane. Do not wait for it to exist.

## Global rules

- **`Willagrams/Audio/AudioPlayer.swift` is `protected:`. Do not edit it.** New
  types go in new files beside it. If an item seems to need a change there, stop
  and report — that is an amendment request, not an item.
- **`Tests/AudioTests/AudioSrc` is a directory symlink to `Willagrams/Audio`,
  and the package declares `.macOS(.v14)`. The whole directory compiles on the
  host.** One unguarded `import AVFoundation` or `import UIKit` anywhere under
  `Willagrams/Audio/` breaks `swift test --package-path Tests/AudioTests`
  outright. Every platform file is wrapped in `#if canImport(UIKit)`.
- **A host-compilable file may import `Foundation` and nothing else.** In
  particular it may not name `Palette`, `Motion`, `Typography` or anything else
  from `Willagrams/Style/**`: the app compiles Style and Audio into one module,
  but `AudioSrc` compiles Audio alone, so a Style reference resolves in the app
  and fails in the test package. Style tokens are reachable only from inside a
  `#if canImport(UIKit)` block, which the host never compiles.
- **`play` and `impact` are non-throwing and non-async, and that is load-bearing.**
  A missing asset, a failed session activation, a decode error — every one of
  them is swallowed and the game continues silently. Never surface an audio
  failure to a caller.
- `swift test --package-path Tests/AudioTests` passes after every item. It is
  six tests today and must never be fewer.

Fuller context: `MAP.md` — "Decided — what the `audio` lane is and is not"
settles the three scope questions this lane would otherwise re-open.

---

- task: Build the effect catalogue — one place that says, for each of the nine
    `SoundEffect` cases, which asset it plays, at what relative volume, and
    whether it also fires a haptic and at which `HapticStrength`. A new file
    `Willagrams/Audio/AudioCatalogue.swift`, `Foundation` only, no platform
    import. Model it as a `public struct AudioCue: Sendable, Equatable` holding
    `assetName: String`, `volume: Float`, `haptic: HapticStrength?`, and a
    `public enum AudioCatalogue { public static func cue(for effect: SoundEffect) -> AudioCue }`
    driven by a `switch` over the effect with no `default:` arm, so adding a
    tenth case to the frozen seam is a compile error here rather than a silent
    silence. This is the only file that decides what a moment sounds like; the
    player below it just plays what it is handed.
  guardrails:
    - No `default:` arm in the effect switch — exhaustiveness is the point of the file
    - `Foundation` only. No `AVFoundation`, no `UIKit`, no reference to `Willagrams/Style/**`
    - Do not edit `AudioPlayer.swift` to add a case, a property, or a conformance
    - Asset names are lowercase, no extension, and match `^[a-z][a-z0-9-]*$` — the file names do not exist yet and the catalogue is what fixes them
  done when:
    - `AudioCatalogue.cue(for:)` returns a distinct `assetName` for each of the nine cases, and `Set(SoundEffect.allCases.map { cue(for: $0).assetName }).count == 9`
    - Every returned `volume` is in `0...1`, and `countdownTick` is quieter than `win` — the tick repeats and the win fires once
    - `tilePlace`, `tileRecall`, `draw`, `swap` and `invalid` each return a non-nil `haptic`; `menuTap` returns `.light`; `win` and `loss` return `.heavy`
    - `swift test --package-path Tests/AudioTests` passes, and the six existing seam tests are unchanged
  status: done
  parallel-group: audio-a

- task: Build the mute state and its persistence — a new file
    `Willagrams/Audio/AudioSettings.swift`, `Foundation` only. A
    `public final class AudioSettings: @unchecked Sendable` (or an actor if that
    lands cleaner) reading and writing one `UserDefaults` key, `audio.muted`,
    defaulting to **unmuted** on a fresh install. It takes a `UserDefaults` in
    its initialiser so a fixture can hand it a scratch suite rather than
    polluting the host's real defaults. This owns the muted *value* only — the
    toggle the player taps lives in `Willagrams/Settings/**`, which is a merged
    lane's and out of scope this round (see `MAP.md`).
  guardrails:
    - `Foundation` only. `UserDefaults` is Foundation and works on the macOS host, so this file stays host-compilable
    - Never read `UserDefaults.standard` implicitly — the suite is injected, always, or the fixture writes into the developer's own preferences
    - Do not add a mute key to `Willagrams/Settings/SettingsStore.swift`; that file belongs to the settings lane
    - **Mute governs sound only.** Do not gate `impact` on it, and do not reach into `Willagrams/Board/BoardFeedback.swift` — iOS governs haptics through its own System Haptics setting, and `MAP.md` records this as decided
  done when:
    - A fresh `AudioSettings` over an empty scratch `UserDefaults` suite reports `isMuted == false`
    - `setMuted(true)` then a **newly constructed** `AudioSettings` over the same suite reports `isMuted == true` — the value survives the object, which is what persistence means
    - A fixture that constructs `AudioSettings` leaves `UserDefaults.standard` unmodified
    - `swift test --package-path Tests/AudioTests` passes
  status: done
  parallel-group: audio-a

- task: Build `SystemAudioPlayer` — the real `AudioPlayer` conformance, in a new
    file `Willagrams/Audio/SystemAudioPlayer.swift`, entirely inside
    `#if canImport(UIKit)`. It configures `AVAudioSession` with category
    `.ambient` so the game **respects the physical silent switch and never ducks
    another app's music**, preloads an `AVAudioPlayer` per catalogue asset,
    plays a cue at its catalogue volume unless `AudioSettings.isMuted`, and
    fires the catalogue's `HapticStrength` through warmed
    `UIImpactFeedbackGenerator`s. `Willagrams/Board/BoardFeedback.swift` already
    warms three generators the same way and is the pattern to copy, not to
    import. Overlapping sounds must overlap — two tiles placed in quick
    succession play twice, not once cut short — so a single shared player per
    asset is not sufficient.
  guardrails:
    - **The entire file is inside `#if canImport(UIKit)`.** No import escapes the guard, including at file scope. `swift test --package-path Tests/AudioTests` is the check, and it must still compile and pass with this file present
    - Category `.ambient`, never `.playback`. `.playback` overrides the silent switch and stops the player's music, which is the opposite of this lane's stated area
    - Every `AVAudioSession` and `AVAudioPlayer` call is wrapped so a throw is swallowed. `play` and `impact` are non-throwing by contract and a missing asset must never reach a caller
    - Do not activate the session at init. Activate lazily on the first sound, or an app that never makes one has still interrupted whatever was playing
    - Generators are touched on the main actor only
  done when:
    - `SystemAudioPlayer` conforms to `AudioPlayer` with no `async` and no `throws` anywhere in the conformance, and `setMuted(true)` round-trips into `isMuted` exactly as `SilentAudioPlayer` does
    - With mute on, `play(_:)` produces no sound and `impact(_:)` still fires — verified behaviourally on a device or simulator, since mute is sound-only by decision
    - The audio session category is `.ambient` and the session is not active until the first `play` — assert against `AVAudioSession.sharedInstance().category` after a first sound, and confirm a launched app that makes no sound leaves background audio playing
    - Constructing the player against a bundle holding **no** audio assets at all does not crash, does not throw, and leaves every `play` call a silent no-op — the assets do not exist yet and the app must ship before they do
    - `swift test --package-path Tests/AudioTests` still passes with the file present, proving the platform guard holds
  caution: true
  status: not started

- task: Wire the placement sound to the snap it belongs to — `tilePlace` must
    land **with** the tile, not ahead of it. `Style.Motion.snapDuration` is 0.16
    and `Motion.snap` is the ease the board animates on, so a sound fired at
    gesture-release plays while the tile is still travelling. Add the scheduling
    to `SystemAudioPlayer` (inside the existing `#if canImport(UIKit)` block,
    which is the only place `Motion` is reachable — see Global rules) so a cue
    may carry a delay, and give `tilePlace` and `tileRecall` a delay read from
    `Motion.snapDuration` and `draw` one read from `Motion.dealDuration`. This
    is the lane's one `depends on:` edge made real: without it the style lane's
    timing tokens have no audio caller and the two drift the first time a
    duration is tuned.
  guardrails:
    - The delay is **read from** `DesignTokens.swift`, never copied as a literal. A hardcoded `0.16` is the exact drift this item exists to prevent
    - `Willagrams/Style/DesignTokens.swift` is `protected:` — read the tokens, do not add one
    - The `Motion` reference stays inside `#if canImport(UIKit)`. A host-compilable file naming `Motion` breaks the AudioTests package
    - A delayed sound must still be cancelled or harmlessly dropped if the app backgrounds before it fires
  done when:
    - `tilePlace` and `tileRecall` fire `Motion.snapDuration` after the call, and `draw` fires `Motion.dealDuration` after it; every other effect fires immediately
    - Changing `Motion.snapDuration` in `DesignTokens.swift` changes when the sound plays, with no edit under `Willagrams/Audio/**` — the token is the single source
    - `grep -rn '0\.16\|0\.45' Willagrams/Audio/` returns no timing literal
    - `swift test --package-path Tests/AudioTests` passes
  status: not started

> **⚠️ AUTONOMOUS RUN — STOP HERE**

## Not yet specified

- **What the nine effects actually sound like.** No audio file exists anywhere in
  the repo, and sound design is a product decision rather than an engineering
  one. The catalogue item fixes the *names* and the player tolerates their
  absence, so every item above ships and passes with an empty asset folder. The
  question to answer next is whether these are recorded samples added to
  `Willagrams/Resources/`, or short tones synthesised at runtime — revisit after
  the `SystemAudioPlayer` item, when there is something to hear them through.
- **Whether the countdown tick needs its own cadence.** `countdownTick` fires
  once per second today only because nothing calls it. Revisit when shell round 3
  wires the countdown screen and there is a real rhythm to match.

## Out of scope

- **Every call site.** Nothing outside `Willagrams/Audio/` calls the seam, and
  wiring it crosses `Willagrams/Shell/**`, `Willagrams/Match/**` and
  `Willagrams/Board/**`. `shell`'s `depends on:` already carries the
  `audio (playback seam — sequenced)` edge, so this is a **shell round 3** item.
  This lane ships a player nothing calls yet, deliberately.
- **The mute toggle UI.** `Willagrams/Settings/**` is the settings lane's and it
  is merged. This lane owns the mute state; the control is settings' or shell
  round 3's.
- **Routing `TileFeedback` through the seam.** `Willagrams/Board/BoardDrag.swift`
  and `BoardFeedback.swift` fire UIKit generators directly and will keep doing
  so. `MAP.md` records why: iOS governs haptics separately from sound, so a
  single app-level mute over both would be the surprising behaviour.
- **Music, and per-effect volume sliders.** Neither is in the lane's `area:` and
  neither is needed to ship.
