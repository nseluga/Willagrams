# Willagrams — Lane: settings

Lane: settings — Match configuration and rule variants — the host's pre-match
options screen, local persistence of chosen defaults, and showing both players
which rules are in force. Ships the disable-swap, minimum-word-length, and
selectable-dictionary controls.

Owned — this lane's items live inside these paths:
  Willagrams/Settings/**
  Tests/SettingsTests/**

Stop and report if an item requires changing a path outside them:
  protected — Sources/WillagramsRules/Contracts.swift,
    Sources/WillagramsRules/BoardAnalysis.swift, Sources/WillagramsRules/Pool.swift,
    Sources/WillagramsRules/GameState.swift, Sources/WillagramsRules/MatchMessage.swift,
    Sources/WillagramsRules/WordList.swift,
    Sources/WillagramsRules/Resources/dictionary.txt, Tests/WillagramsRulesTests/**,
    Willagrams/Style/DesignTokens.swift, Willagrams/Style/Terminology.swift,
    Willagrams.entitlements, Package.swift
  another lane's — Willagrams/Style/**, Willagrams/Resources/Branding/**,
    Willagrams/Assets.xcassets/**, docs/ip-review.md, Willagrams/Board/**,
    Tests/BoardTests/**, Willagrams/Match/**, Tests/MatchTests/**,
    Willagrams/Shell/**, Willagrams/App/**, Tests/ShellTests/**, Willagrams/Bot/**,
    Tests/BotTests/**, fastlane/**, Willagrams/PrivacyInfo.xcprivacy,
    Willagrams/Resources/AppStore/**
  unowned — none listed in MAP.md

Frozen contracts — build and test against these; they will not move:
  Sources/WillagramsRules/MatchOptions.swift — the options type this lane produces
  Sources/WillagramsRules/MatchMessage.swift — wire v2, `start` carries `MatchOptions`
  Tests/WillagramsRulesTests/Fixtures/wire-v2.json — golden fixture
  Sources/WillagramsRules/WordList.swift — `WordList` protocol, `EnableWordList`
  Willagrams/Style/DesignTokens.swift — token key names

Test against the fixture, not the producing lane. Do not wait for it to exist.

Global rules:
  - Never edit project.pbxproj. The target uses PBXFileSystemSynchronizedRootGroup,
    so new files are picked up automatically. Anything needing a build-setting
    change is a stop-and-report, not a workaround.
  - **Model/Views split.** `Willagrams/Settings/Model/` is symlinked into the test
    package and compiled by it, so nothing there may `import SwiftUI` or reference
    `DesignTokens`. Everything that renders lives in `Willagrams/Settings/Views/`
    and is verified by reading source, never by compiling it.
  - Terminology.swift is the IP fence. The mechanic is **Draw**, never "peel".
    The banned words — bunch, split, peel, dump, bananas, rotten — must not appear
    as player-facing strings *or* as source identifiers, comments, or test names.
    The mechanic this lane can disable is **Swap**, never "dump".
  - Decoding anything that arrived from a peer is a trust boundary. No force
    unwraps, no `try!`, no fatalError on a decode path.
  - Two players per match this round. Do not build for N.
  - The checkout directory must be named `Willagrams`. SwiftPM derives a path
    dependency's package identity from the directory name, so a worktree named
    anything else fails item 1 with `unknown package 'Willagrams'` — the nested
    test package cannot resolve `../..`. Worktrees nest as `<name>/Willagrams`.
  - This lane is purely additive inside `Willagrams/Settings/`. Enforcement of
    every option already landed with the wire v2 amendment; nothing here changes
    engine or match behavior.

---

- task: Stand up the settings test package and the ruleset type. Create
    `Tests/SettingsTests/Package.swift` as a standalone nested SwiftPM package
    following `Tests/MatchTests/Package.swift` — `swift-tools-version: 6.0`,
    `platforms: [.macOS(.v14)]`, a path dependency on `../..`, a `Settings`
    target at path `SettingsSrc` depending on the `WillagramsRules` product, and
    a `SettingsTests` test target at path `Cases`. Commit `SettingsSrc` as a
    symlink to `../../Willagrams/Settings/Model`, matching MatchTests'
    `MatchSrc -> ../../Willagrams/Match`. Carry the explanatory header from
    `Tests/StyleTests/Package.swift` naming the run command. Then add
    `Willagrams/Settings/Model/Ruleset.swift` — a named preset wrapping a
    `MatchOptions`, plus a catalogue holding exactly one entry, "Standard",
    whose options equal `MatchOptions.standard`.
  guardrails:
    - Do not add the package to the root Package.swift — it is protected, and
      SwiftPM ignores directories the root manifest does not name
    - SettingsSrc is a symlink, never a copy — a copied tree silently rots
    - Ruleset.swift must not import SwiftUI or reference DesignTokens
  done when:
    - `swift test --package-path Tests/SettingsTests` builds and runs from a
      clean checkout
    - The "Standard" preset's options compare equal to `MatchOptions.standard`
    - `Tests/SettingsTests/SettingsSrc` resolves to `Willagrams/Settings/Model`
      as a symlink, verified by reading the link target, not by file contents
    - Existing passing tests remain passing
  status: done

- task: Add `Willagrams/Settings/Model/DictionaryCatalogue.swift` — the mapping
    from a `dictionaryID` string to a display name, a constructed `WordList`, and
    that list's content hash computed with the engine's canonical hashing
    function. Ship exactly one entry, `"standard"`, backed by `EnableWordList()`.
    Lookup of an unknown ID returns nil.
  guardrails:
    - An unknown dictionaryID returns nil and never falls back to the standard
      list — a silent substitution is the desync this design exists to prevent
    - Do not read or embed a second word list file in this item
    - Must not import SwiftUI or reference DesignTokens
  done when:
    - Looking up `"standard"` returns a list whose hash equals the engine's hash
      of the bundled ENABLE list
    - Looking up an unknown ID returns nil
    - Existing passing tests remain passing
  status: not started
  parallel-group: a

- task: Add `Willagrams/Settings/Model/SettingsStore.swift` — persistence of the
    host's chosen `MatchOptions` to UserDefaults, with the suite injected rather
    than reaching for `.standard`, so tests use a throwaway suite. Absent or
    corrupt stored data returns `MatchOptions.standard`.
  guardrails:
    - The UserDefaults suite is injected, never hardcoded to `.standard`
    - A decode failure returns the standard options, never traps
    - Must not import SwiftUI or reference DesignTokens
  done when:
    - Options written then read back from a fresh store over the same suite
      compare equal
    - Reading from an empty suite returns `MatchOptions.standard`
    - Reading a suite seeded with malformed bytes returns `MatchOptions.standard`
      without trapping
  status: done
  parallel-group: a

- task: Add the host's options form. `Willagrams/Settings/Model/MatchOptionsForm.swift`
    holds the editable state and the clamping rules — `minimumWordLength` clamps
    to `2...15`, `swapEnabled` is a boolean, `dictionaryID` must resolve in the
    catalogue — and produces a `MatchOptions` with the hash filled in from the
    catalogue. `Willagrams/Settings/Views/MatchOptionsView.swift` renders it
    against DesignTokens and Terminology strings.
  guardrails:
    - The form never produces a MatchOptions whose dictionaryHash disagrees with
      the catalogue entry for its dictionaryID
    - All clamping lives in the Model file; the View sets values and never
      validates them
    - The swap control is labelled from Terminology.swift — never the word "dump"
  done when:
    - Setting minimumWordLength to 1 or to 99 yields 2 and 15 respectively
    - The produced MatchOptions' dictionaryHash equals the catalogue's hash for
      the selected ID
    - A form left untouched produces options equal to `MatchOptions.standard`
  status: not started

- task: Add the rules-in-force summary. `Willagrams/Settings/Model/RulesSummary.swift`
    is a pure function from `MatchOptions` to an ordered list of short display
    lines — one per rule that differs from standard, plus the dictionary name
    always. `Willagrams/Settings/Views/RulesInForceView.swift` renders it, so both
    players can see the rules the host chose.
  guardrails:
    - RulesSummary is a pure function — no store access, no catalogue mutation
    - Summary lines come from Terminology.swift, never inline literals
    - Must not import SwiftUI or reference DesignTokens
  done when:
    - `MatchOptions.standard` yields exactly one line, naming the standard dictionary
    - Options with swap disabled and a minimum of 4 yield three lines including
      both changed rules
    - Line order is stable across two calls with the same options
  status: not started

## Out of scope

- Pool size and letter distribution — cut deliberately; the pool stays at 144
  and its composition is fixed this round
- Starting hand size — the rule it would serve (21 dropping to 14 at four or
  more players) has no code path to attach to; N-player is a match-lane round
- Custom and made-up-word dictionaries — the catalogue seam ships here with one
  entry; adding lists needs no wire bump and can land any later round
- A negotiation handshake — the host chooses, the guest accepts or leaves
- Match timer and handicap — deferred

## Not yet specified

- Where the options screen is entered from, and whether the guest sees the
  rules-in-force view before or after joining — revisit after the shell lane
  merges, since shell owns the navigation into these screens
