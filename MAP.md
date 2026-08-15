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

## Pending amendment — wire v2, for the `settings` lane

Rule variants ship in v1, which the wire cannot currently express. Before
`settings` can run, `/foundation` must amend: add `options:` to
`MatchMessage.start`, bump `WireFormat.current` to 2, regenerate the golden
fixture as `wire-v2.json`, add `MatchOptions` and its enforcement to the engine,
and extend `protected:` with both new paths.

Decided, to be pinned at amendment time:

  - The variants are **minimum word length**, **pool size**, and **selectable
    letter distribution**. No match timer — it reintroduces the unsynced-clock
    problem the countdown design deliberately avoids. No handicap.
  - Minimum word length needs no change to `BoardAnalysis`. `words()` already
    returns every run of two or more and defers validity to the injected
    `WordList`, so a decorator rejecting anything shorter turns a short run into
    an *invalid word* rather than an ignored one — which is the correct behavior,
    and leaves the `tileCount >= 2` floor intact.
  - The distribution travels as **literal letter counts, not a preset name**, so
    presets can be added, tuned, or dropped forever without a wire bump and
    therefore without a forced app update. Counts arrive from a peer and are a
    trust boundary: validate single A–Z keys, non-negative counts, and a total
    within sane bounds before building a pool from them.
  - The host chooses the options and sends them in `start`. The guest accepts or
    leaves; there is no negotiation handshake.

**Timing.** The amendment must not land while the match lane is mid-run against
`wire-v1.json`. Sequence: the current match run finishes on v1 → amend → match
rebases and builds its remaining items against v2 → `settings` runs. `board` is
unaffected by all of it and can run at any point.

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

- lane: settings
  area: Match configuration and rule variants — the host's pre-match options screen, local persistence of chosen defaults, and showing both players which rules are in force. Ships the minimum-word-length, pool-size, and letter-distribution controls.
  owns: [ Willagrams/Settings/**, Tests/SettingsTests/** ]
  assignee: nate
  depends on: match (sequenced — starts after the wire v2 amendment lands and match merges), style (tokens + Terminology strings — contract Willagrams/Style/DesignTokens.swift)

- lane: shell
  area: App shell — launch, main menu, solo practice mode, host/join flow, in-match HUD, results screen, navigation. Settings screens themselves belong to the settings lane; shell navigates into them.
  owns: [ Willagrams/Shell/**, Willagrams/App/**, Tests/ShellTests/** ]
  assignee: nate
  depends on: style (tokens + Terminology strings — contract Willagrams/Style/DesignTokens.swift), board (sequenced — starts after board merges), match (sequenced — starts after match merges), settings (sequenced — starts after settings merges)

- lane: release
  area: Ship pipeline — bundle id, signing, privacy manifest, App Store Connect metadata, store screenshots, TestFlight distribution.
  owns: [ fastlane/**, Willagrams/PrivacyInfo.xcprivacy, Willagrams/Resources/AppStore/** ]
  assignee: nate
  depends on: style (icon + store art — contract Willagrams/Resources/Branding/), shell (sequenced — needs a launchable app to build and submit)
