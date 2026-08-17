# Willagrams — Lane Map

protected:
  - Sources/WillagramsRules/Contracts.swift
  - Sources/WillagramsRules/BoardAnalysis.swift
  - Sources/WillagramsRules/Pool.swift
  - Sources/WillagramsRules/GameState.swift
  - Sources/WillagramsRules/MatchMessage.swift
  - Sources/WillagramsRules/MatchOptions.swift
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
during `/foundation` and is green at 42 tests across 7 suites. Everything it
would have owned is on the `protected:` list above, so 100% of the lane's scope
is frozen and no item could legally run in it. Downstream lanes depend on those
contracts directly, not on a lane.

## Landed amendment — wire v2, for the `settings` lane

Landed on `main`. `MatchOptions` exists in the engine, `WireFormat.current == 2`,
and `Tests/WillagramsRulesTests/Fixtures/wire-v2.json` is the golden fixture.
Engine 42 tests / 7 suites, MatchTests 100 tests / 18 suites, both green. The
spec is `docs/amendment-wire-v2.md`. A lane branch cut before this commit must
rebase onto it.

What shipped, and how it differs from what was decided in advance:

  - The variants are **disable swap**, **minimum word length**, and a
    **selectable dictionary**. Pool size and letter distribution were cut — the
    pool stays at 144 with a fixed composition this round. No match timer, no
    handicap, as decided.
  - `MatchOptions` carries `minimumWordLength`, `swapEnabled`, `dictionaryID`,
    and `dictionaryHash`. It arrives from a peer, so `validated` clamps the
    length to `2...15` and filters both identifiers to a charset and a 64-char
    ceiling before anything reads them.
  - The dictionary travels as an **id plus a content hash**, not as a list. A
    start whose hash does not match this device's list is **refused** rather
    than played: the two devices validate their own boards, so mismatched lists
    would disagree about legal words for the whole match. `MatchSession` exposes
    `optionsRefusal` for it.
  - Minimum word length needed no change to `BoardAnalysis`, as predicted.
    `MinimumLengthWordList` decorates the injected `WordList`, so a short run
    becomes an *invalid word* rather than an ignored one.
  - Swap is enforced host-side in `HostPool` with a new
    `RejectionReason.swapDisabled`, and short-circuited client-side in
    `MatchSession.swap`. Both swap refusals return the player's Draw credit.
  - The host chooses and sends the options in `start`. The guest accepts or
    leaves; there is no negotiation handshake, as decided.

**⚠️ `MatchSession` is at a Swift 6.3.3 toolchain limit.** Adding one more
*observed* stored property to that class makes MatchTests abort in the reconnect
path with `swift_task_dealloc` — "freed pointer was not the last allocation".
A bare `var probe: Int = 0` is enough; marking any one existing observed
property `@ObservationIgnored` to keep the net count unchanged makes it pass.
This amendment's two new values are therefore stored `@ObservationIgnored` and
read through computed properties that touch an observed one, so observation
still works — see the note in `Willagrams/Match/MatchSession.swift`. Any lane
adding state to `MatchSession` must run `swift test --package-path
Tests/MatchTests`; the engine suite does not cover it.

## Granted amendment — the opening deal, built in the `shell` lane

`MatchSession` receives `startingHandSize` off the wire, clamps it, and stores
it. It never gives either player a tile. The deferral is a comment at
`Willagrams/Match/MatchSession.swift:673`; the item behind it was never written
into the match lane plan, so it is neither done nor below that lane's stop
marker. Today every match — solo or two-device — begins with both hands empty.

This is not hardware-gated. `Pool` and `HostPool` already exist and the
countdown already reaches zero on both devices. It is one function that runs at
that transition, and it is headlessly testable like the rest of the match lane.

**Granted:** the `shell` lane may edit `Willagrams/Match/**` and
`Tests/MatchTests/**` for this item alone. Its agents do not stop at the fence
for it. Every other path in match's `owns:` remains closed to them.

Rationale: the match lane is merged and closed, every lane carries the same
assignee, so no parallel work can collide with the edit. The shell cannot
show a playable match without it, and a whole lane round for one function is
ceremony. A second item wanting a match path is a fresh amendment, not covered
here.

Likewise granted, and for the same reason: `shell` may change the `init`
signature of `Willagrams/Board/BoardView.swift` to expose the board state its
owner needs. `BoardView` currently takes `board:` by value into private
`@State`, so nothing can be delivered to it or read back out after
construction. No other file under `Willagrams/Board/**` is opened by this.

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
  depends on: — builds on the frozen engine (MatchMessage wire enum in Sources/WillagramsRules/MatchMessage.swift, with golden fixture Tests/WillagramsRulesTests/Fixtures/wire-v2.json; host-side Pool.draw/swap in Sources/WillagramsRules/Pool.swift) — no lane edge, those shipped with the foundation and are fenced under protected:

- lane: settings
  area: Match configuration and rule variants — the host's pre-match options screen, local persistence of chosen defaults, and showing both players which rules are in force. Ships the disable-swap, minimum-word-length, and selectable-dictionary controls.
  owns: [ Willagrams/Settings/**, Tests/SettingsTests/** ]
  assignee: nate
  depends on: match (sequenced — the wire v2 amendment has landed; starts after match merges), style (tokens + Terminology strings — contract Willagrams/Style/DesignTokens.swift)

- lane: shell
  area: App shell — launch, main menu, solo practice mode, host/join flow, in-match HUD, results screen, navigation. Settings screens themselves belong to the settings lane; shell navigates into them.
  owns: [ Willagrams/Shell/**, Willagrams/App/**, Tests/ShellTests/** ]
  assignee: nate
  depends on: style (tokens + Terminology strings — contract Willagrams/Style/DesignTokens.swift), board (sequenced — starts after board merges), match (sequenced — starts after match merges), settings (sequenced — starts after settings merges)

- lane: bot
  area: The CPU opponent for solo practice — a heuristic grid solver that holds tiles, builds a valid connected board from them, draws when its board is complete, and races the player. Owns its difficulty model and the UI for choosing a difficulty. Sits behind the transport seam exactly as a remote peer does.
  owns: [ Willagrams/Bot/**, Tests/BotTests/** ]
  assignee: nate
  depends on: match (MatchTransport seam and the MatchMessage wire — contract Willagrams/Match/MatchTransport.swift, golden fixture Tests/WillagramsRulesTests/Fixtures/wire-v2.json), style (tokens for the difficulty control — contract Willagrams/Style/DesignTokens.swift). Also builds on the frozen engine (BoardAnalysis word extraction and connectivity in Sources/WillagramsRules/BoardAnalysis.swift) — no lane edge, fenced under protected:

**Rules, not reinforcement learning.** Building a grid from a tile set is a
combinatorial construction problem with obvious greedy structure, so heuristic
search dominates. RL would need a simulator built first, training
infrastructure, and shipped weights — and it gives *worse* difficulty control,
because a trained policy's strength cannot be cleanly dialled. Every knob worth
having is a direct parameter of a heuristic: think time, vocabulary subset, how
aggressively it rebuilds.

**The bot needs a real board, and the shortcut does not work.** The player never
sees the opponent's progress, which tempts a bot that only draws on a schedule
and eventually claims a win. That fails: `MatchMessage.win` carries
`placements`, and a win is validated against them. A bot with no real grid
cannot produce valid placements, so the cheap version forces a special case into
the win path. Build the solver.

The `shell` lane ships a silent placeholder peer so a solo match is playable
before this lane lands. Replacing it is this lane's first item, not shell's.

- lane: tuning
  area: Final polish across the assembled app — the opening-deal animation (tiles flying into their places), draw and swap motion, timing and easing adjustments, haptic strength, screen transitions, copy tightening, and the small visual corrections that only become visible once every lane is merged and the app is played end to end. Adjustments to what already ships, never new features.
  owns: [ ]   # no exclusive paths — see the fence exception below
  assignee: nate
  depends on: shell (sequenced — starts after shell merges), bot (sequenced — the opponent is polished too, and its pacing is a tuning concern), settings (sequenced — nothing is tuned before every lane has landed)

**Fence exception for `tuning`.** This lane owns no globs, so it passes the
`owns:` overlap check trivially and adds nothing to the coverage check. That is
deliberate: polish edits land wherever the flaw is, and any honest `owns:` list
for it would intersect `board`, `shell`, and `style` at once and make the map
invalid.

The isolation a fence buys is unnecessary here. `tuning` runs last, alone, after
every other lane has merged and closed, and every lane carries the same
assignee. Its agents may edit **any non-protected path**. `protected:` still
stops them — the IP fence and the frozen engine are not tuneable.

Two consequences, both intended. `tuning` must **never** run in parallel with
another lane; if one reopens, tuning waits. And `/lane` cannot use an `owns:`
fence to scope its items, so the LANE.md plan itself has to name the files each
item may touch.

A polish idea that turns out to need a new feature is not a tuning item. It goes
back to the lane that owns the surface, or it waits for the next round.

- lane: release
  area: Ship pipeline — bundle id, signing, privacy manifest, App Store Connect metadata, store screenshots, TestFlight distribution.
  owns: [ fastlane/**, Willagrams/PrivacyInfo.xcprivacy, Willagrams/Resources/AppStore/** ]
  assignee: nate
  depends on: style (icon + store art — contract Willagrams/Resources/Branding/), tuning (sequenced — the app is polished before it is submitted), shell (sequenced — needs a launchable app to build and submit)
