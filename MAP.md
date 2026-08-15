# Willagrams — Lane Map

protected:
  - Sources/WillagramsRules/Contracts.swift
  - Sources/WillagramsRules/BoardAnalysis.swift
  - Sources/WillagramsRules/Pool.swift
  - Sources/WillagramsRules/GameState.swift
  - Sources/WillagramsRules/MatchMessage.swift
  - Sources/WillagramsRules/WordList.swift
  - Sources/WillagramsRules/Resources/dictionary.txt
  - Tests/WillagramsRulesTests/**
  - Willagrams/Style/DesignTokens.swift
  - Willagrams/Style/Terminology.swift
  - Willagrams.entitlements
  - Package.swift

In `DesignTokens.swift` the protected surface is the **key names**, not the
values: `board` and `shell` compile against the keys, and nothing downstream
depends on a particular color or duration. The `style` lane may change values
and add keys freely. Renaming or removing a key is still an amendment.
`Terminology.swift` is protected in full — it is the IP fence, and the strings
themselves are the contract.

There is no `rules` lane. The engine it would have built — pool, board model,
connectivity and word extraction, dictionary, the Draw gate — landed whole
during `/foundation` and is green at 36 tests across 6 suites. Everything it
would have owned is on the `protected:` list above, so 100% of the lane's scope
is frozen and no item could legally run in it. Downstream lanes depend on those
contracts directly, not on a lane.

---

- lane: style
  area: Visual identity and the IP fence — palette, typography, spacing and motion tokens, tile art, app icon, launch screen, player-facing terminology, and the written distinctness review against Bananagrams' name, trade dress, and vocabulary. Ships a StyleGallery screen rendering every token in situ.
  owns: [ Willagrams/Style/**, Willagrams/Resources/Branding/**, Willagrams/Assets.xcassets/**, docs/ip-review.md ]
  assignee: nate
  depends on: —

- lane: board
  area: The playing surface — tile rack, drag/drop/snap to grid, pan/zoom, rearrange, invalid-placement feedback, haptics, tile animations.
  owns: [ Willagrams/Board/**, Tests/BoardTests/** ]
  assignee: nate
  depends on: style (tile art + token names — contract Willagrams/Style/DesignTokens.swift). Also builds on the frozen engine (Tile, Coord, Placement, Board.place/remove in Sources/WillagramsRules/Contracts.swift; the Draw gate BoardValidation in Sources/WillagramsRules/BoardAnalysis.swift) — no lane edge, those shipped with the foundation and are fenced under protected:

- lane: match
  area: GameKit multiplayer — Game Center auth, friend invite, GKMatch lifecycle, message codec, host-authoritative pool, draw/grow broadcast, win claim, disconnect + reconnect.
  owns: [ Willagrams/Match/**, Tests/MatchTests/** ]
  assignee: nate
  depends on: — builds on the frozen engine (MatchMessage wire enum in Sources/WillagramsRules/MatchMessage.swift, with golden fixture Tests/WillagramsRulesTests/Fixtures/wire-v1.json; host-side Pool.draw/swap in Sources/WillagramsRules/Pool.swift) — no lane edge, those shipped with the foundation and are fenced under protected:

- lane: shell
  area: App shell — launch, main menu, solo practice mode, host/join flow, in-match HUD, results screen, settings, navigation.
  owns: [ Willagrams/Shell/**, Willagrams/App/**, Tests/ShellTests/** ]
  assignee: nate
  depends on: style (tokens + Terminology strings — contract Willagrams/Style/DesignTokens.swift), board (sequenced — starts after board merges), match (sequenced — starts after match merges)

- lane: release
  area: Ship pipeline — bundle id, signing, privacy manifest, App Store Connect metadata, store screenshots, TestFlight distribution.
  owns: [ fastlane/**, Willagrams/PrivacyInfo.xcprivacy, Willagrams/Resources/AppStore/** ]
  assignee: nate
  depends on: style (icon + store art — contract Willagrams/Resources/Branding/), shell (sequenced — needs a launchable app to build and submit)
