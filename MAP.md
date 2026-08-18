# Willagrams — Lane Map

Round 2 — the shippable release. Goal: a working App Store build with a home
page, a friends page, a profile page, playable matches directly with friends,
a bot opponent, and sound.

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
  - Willagrams/Match/MatchTransport.swift
  - Willagrams/Style/DesignTokens.swift
  - Willagrams/Style/Terminology.swift
  - Willagrams.entitlements
  - Package.swift
  - supabase/migrations/**

In `DesignTokens.swift` the protected surface is the **key names**, not the
values: every UI lane compiles against the keys, and nothing downstream depends
on a particular color or duration. The `style` lane may change values and add
keys freely. Renaming or removing a key is still an amendment.
`Terminology.swift` is protected in full — it is the IP fence, and the strings
themselves are the contract.

**`MatchTransport.swift` is newly protected this round.** It was `match`'s file
when `match` was the only lane that touched it. Three lanes now build against
it — `online` implements it, `bot` conforms to it, `shell` consumes it — so a
unilateral change breaks two lanes silently, which is exactly what `protected:`
exists to catch.

**`supabase/migrations/**` is protected before it exists.** The database schema
is read by `online`, `account` and `friends`. A migration landing in one lane
changes what the other two read, with no compile error anywhere.

## Symlink hazard — `owns:` does not fence this

`Tests/ShellTests/` contains directory symlinks into three other lanes:

    Tests/ShellTests/BoardSrc  → Willagrams/Board
    Tests/ShellTests/MatchSrc  → Willagrams/Match
    Tests/ShellTests/StyleSrc  → Willagrams/Style/Terminology.swift

`shell` owns `Tests/ShellTests/**`, so an agent editing what looks like its own
test package can write through a symlink into `board`, `match` or `style`. The
glob overlap check cannot see this — the tracked object is the symlink.

**Agents: treat a path reached through one of these symlinks as belonging to the
lane that owns its target, and stop.** The same applies to
`Tests/MatchTests/MatchSrc`, `Tests/SettingsTests/SettingsSrc` and the file
symlinks in `Tests/BoardTests/Cases`, though those stay inside their own lane.

unowned:
  - `.` (repo root — MAP.md, Package.swift, README, .gitignore, Willagrams.entitlements) — Reviewer-only. Changed through `/map` or `/foundation`, never by a lane item.
  - `.claude/**` — dev-team run artifacts and agent reports. Tooling state, not product code.
  - `docs/*.md` except `docs/ip-review.md` (style) and `docs/store/**` (launch) — amendment specifications. Written by `/foundation`, read by lanes, edited by neither.
  - `progress/**` — archived per-lane progress files, written at merge time by `/merge-lane`.
  - `Sources/WillagramsRules/**` and `Tests/WillagramsRulesTests/**` — the frozen engine. Every path is on `protected:`; amendments go through `/foundation`. No lane writes items for it.
  - `Willagrams.xcodeproj/**` — the app target uses a **synchronized root group**, so adding a source file under `Willagrams/` requires no project-file edit. Capability and build-setting changes are Reviewer calls.

## Closed lanes

There is no `rules` lane. The engine it would have built — pool, board model,
connectivity and word extraction, dictionary, the Draw gate — landed whole
during `/foundation` and is green at 42 tests across 7 suites. Everything it
would have owned is on the `protected:` list above.

## Game Center is not used

The match lane built every session against the `MatchTransport` protocol and
never wrote the adapter behind it. **No file imports GameKit**, and
`Tests/MatchTests/Cases/SourceGuardrailTests.swift` asserts that none ever
does. The `online` lane fills that empty adapter slot with a hosted backend
instead of GameKit.

Consequences, decided this round:

  - `PlayerID` is documented in `Contracts.swift` as "keyed by
    `GKPlayer.gamePlayerID`". It becomes the backend's user ID. Doc-comment
    amendment only — the type does not change.
  - `MatchDelivery.lossy` maps onto `GKMatch.SendDataMode` and has no
    equivalent over a WebSocket. It degrades to a no-op in the adapter.
  - `MatchMessageTests` asserts a maximal win payload fits GameKit's 16KB
    reliable-send limit. The number stays as a sane transport ceiling; only its
    stated reason changes.
  - `com.apple.developer.game-center` in `Willagrams.entitlements` is unused
    and comes out. `Willagrams.entitlements` is `protected:` — Reviewer's edit.

## Landed amendment — wire v2, for the `settings` lane

Landed on `main`. `MatchOptions` exists in the engine, `WireFormat.current == 2`,
and `Tests/WillagramsRulesTests/Fixtures/wire-v2.json` is the golden fixture.
The spec is `docs/amendment-wire-v2.md`.

  - The variants are **disable swap**, **minimum word length**, and a
    **selectable dictionary**. Pool size and letter distribution were cut — the
    pool stays at 144 with a fixed composition. No match timer, no handicap.
  - `MatchOptions` carries `minimumWordLength`, `swapEnabled`, `dictionaryID`,
    and `dictionaryHash`. It arrives from a peer, so `validated` clamps the
    length to `2...15` and filters both identifiers to a charset and a 64-char
    ceiling before anything reads them.
  - The dictionary travels as an **id plus a content hash**, not as a list. A
    start whose hash does not match this device's list is **refused** rather
    than played. `MatchSession` exposes `optionsRefusal` for it.
  - Swap is enforced host-side in `HostPool` with `RejectionReason.swapDisabled`
    and short-circuited client-side in `MatchSession.swap`. Both swap refusals
    return the player's Draw credit.
  - The host chooses and sends the options in `start`. The guest accepts or
    leaves; there is no negotiation handshake.

## Pending amendment — wire v3, up to 6 players

**Not a lane item. `/foundation` runs this before `match` reopens.**

Two players is baked into the contracts, not an incidental limit:

  - `MatchTransport` exposes `localPlayerID` and a single `peerConnectionStates`
    stream — one peer, not a roster.
  - `MatchSession` has `public let peerPlayerID`, documented as "the one
    opponent", a singular `peerPresence`, and guards of the form
    `guard player == peerPlayerID else { return }`.
  - `HostPool.init(players: (PlayerID, PlayerID))` takes a 2-tuple, with
    `precondition(players.0 != players.1, "a match needs two different players")`.
  - `MatchMessage.start` carries no roster, and that file states that adding or
    reordering a case is a wire break.

The game *rules* are player-count agnostic and do not change: `Pool.draw(n)`
already takes a count, `BoardAnalysis` and `Board` do not know what a player is,
and `GameState` is explicitly one player's own view. The break is confined to
the transport, session and host-pool layer.

**⚠️ `MatchSession` is at a Swift 6.3.3 toolchain limit.** Adding one more
*observed* stored property to that class makes MatchTests abort in the reconnect
path with `swift_task_dealloc` — "freed pointer was not the last allocation".
A bare `var probe: Int = 0` is enough; marking any one existing observed
property `@ObservationIgnored` to keep the net count unchanged makes it pass.
Any lane adding state to `MatchSession` must run `swift test --package-path
Tests/MatchTests`; the engine suite does not cover it.

## Granted amendment — the opening deal and the board-commit bridge, in `shell`

`MatchSession` receives `startingHandSize` off the wire, clamps it, and stores
it. Nothing carries a board move back into `MatchSession.state.board`, so the
two diverge after the first placement and no match is truly playable.

**Granted:** the `shell` lane may edit `Willagrams/Match/**` and
`Tests/MatchTests/**` for the opening deal and the board-commit bridge alone.
Its agents do not stop at the fence for those two items. Every other path in
`match`'s `owns:` remains closed to them.

Rationale: `match` is merged, every lane carries the same assignee, so no
parallel work can collide. A whole lane round for one bridge is ceremony.
A third item wanting a match path is a fresh amendment, not covered here.

Likewise granted: `shell` may change the `init` signature of
`Willagrams/Board/BoardView.swift` to expose the board state its owner needs.
No other file under `Willagrams/Board/**` is opened by this.

## Deferred out of this round — decided, not forgotten

Named during the round-zero interview and deliberately cut. No lane owns them;
each is a later round, not an oversight.

  - **Online matchmaking with strangers.** v1 plays directly with friends only.
    The `online` lane builds the channel and the invite; it does not build a
    matchmaking queue. Adding one later is a lane item, not a contract change.
  - **Chat.** Cut from `friends` this release. It needs message storage and a
    report/block flow, which Apple reviews on any user-to-user messaging.
  - **Android and web.** Launch is iOS-only. The engine in
    `Sources/WillagramsRules` is pure Swift with no platform dependency, so this
    is a port question, not a rewrite question.

## Tuning — the last step before launch

There is no tuning lane; its `owns:` would intersect every other lane. Tuning
is a **pass**, run after every lane merges and before `launch` closes: token
values, bot difficulty constants, animation durations, sound levels. Each edit
lands in the lane that owns the file.

---

- lane: style
  area: Visual identity and the IP fence — palette, typography, spacing and motion tokens, tile art, app icon, launch screen, player-facing terminology, and the written distinctness review against Bananagrams' name, trade dress, and vocabulary. Ships a StyleGallery screen rendering every token in situ. Owns its own source-guardrail test package.
  owns: [ Willagrams/Style/**, Willagrams/Resources/Branding/**, Willagrams/Assets.xcassets/**, Tests/StyleTests/**, docs/ip-review.md ]
  assignee: nate
  depends on: —

- lane: board
  area: The playing surface — tile drag/drop/snap to grid, pan/zoom, rearrange, multi-tile selection and group drag, invalid-placement feedback, tile animations.
  owns: [ Willagrams/Board/**, Tests/BoardTests/** ]
  assignee: nate
  depends on: style (tile art + token names — contract Willagrams/Style/DesignTokens.swift). Also builds on the frozen engine (Tile, Coord, Placement, Board.place/remove in Sources/WillagramsRules/Contracts.swift; the Draw gate BoardValidation in Sources/WillagramsRules/BoardAnalysis.swift) — no lane edge, fenced under protected:

- lane: match
  area: The match session — message codec, host-authoritative pool, draw/swap/grow broadcast, win claim, disconnect freeze and reconnect. Transport-agnostic: it owns the MatchTransport protocol and never imports a networking framework. Reopens this round for wire v3 (up to 6 players).
  owns: [ Willagrams/Match/**, Tests/MatchTests/** ]
  assignee: nate
  depends on: — builds on the frozen engine (MatchMessage wire enum in Sources/WillagramsRules/MatchMessage.swift, golden fixture Tests/WillagramsRulesTests/Fixtures/wire-v2.json; host-side Pool.draw/swap in Sources/WillagramsRules/Pool.swift) — no lane edge, fenced under protected:. Blocked on the wire v3 amendment landing.

- lane: settings
  area: Match configuration and rule variants — the host's pre-match options screen, local persistence of chosen defaults, and showing both players which rules are in force. Ships the disable-swap, minimum-word-length, and selectable-dictionary controls.
  owns: [ Willagrams/Settings/**, Tests/SettingsTests/** ]
  assignee: nate
  depends on: match (MatchOptions on the wire — contract Sources/WillagramsRules/MatchOptions.swift), style (tokens + Terminology strings — contract Willagrams/Style/DesignTokens.swift)

- lane: shell
  area: App shell — launch, opening animation, the home page and its actions (start a match, how to play), the countdown/match/results routes and the navigation between them, in-match HUD, results and rematch. Round 2 also owns the board-commit bridge and replacing the placeholder routes with the real screens. Feature lanes own their own screens; shell navigates into them.
  owns: [ Willagrams/Shell/**, Willagrams/App/**, Tests/ShellTests/** ]
  assignee: nate
  depends on: style (tokens + Terminology strings — contract Willagrams/Style/DesignTokens.swift), board (BoardView init signature — contract Willagrams/Board/BoardView.swift), match (MatchSession + MatchTransport — contracts Willagrams/Match/MatchTransport.swift), settings (options screen entry point — contract Willagrams/Settings/Views/MatchOptionsView.swift), online (match creation and invite — sequenced), account (sign-in and profile screen entry points — sequenced), friends (friends screen entry point — sequenced), audio (playback seam — sequenced)

- lane: online
  area: The backend seam that replaces GameKit — hosted client, authentication session, database access, and the MatchTransport adapter over realtime channels. Owns match creation and the invite plumbing behind shell's buttons. Owns the schema migrations. Does not own any screen.
  owns: [ Willagrams/Online/**, Tests/OnlineTests/**, supabase/** ]
  assignee: nate
  depends on: match (MatchTransport protocol it implements, and the MatchMessage wire it carries — contracts Willagrams/Match/MatchTransport.swift, Sources/WillagramsRules/MatchMessage.swift)

- lane: account
  area: Identity screens — Sign in with Apple, the profile page and its stats. Reads the session and the user record from `online`; owns no client and no schema. No phone sign-in: Supabase sends no SMS itself and every supported provider is paid, so Sign in with Apple is the only route this release.
  owns: [ Willagrams/Account/**, Tests/AccountTests/** ]
  assignee: nate
  depends on: online (auth session + user record — sequenced, the schema is not designed yet), style (tokens — contract Willagrams/Style/DesignTokens.swift)

- lane: friends
  area: The friends page — friends list, friend requests and accept/block, and invites by share link and short friend code. No chat this release, and no phone-number invites: that would need a paid SMS provider, so a friend code carried over any messenger the player already has replaces it.
  owns: [ Willagrams/Friends/**, Tests/FriendsTests/** ]
  assignee: nate
  depends on: online (client + friend tables — sequenced, the schema is not designed yet), account (the current user — sequenced), style (tokens — contract Willagrams/Style/DesignTokens.swift)

- lane: bot
  area: The CPU opponent for solo play — a heuristic grid solver that holds tiles, builds a valid connected board from them, draws when its board is complete, and races the player. Owns its difficulty model and the UI for choosing a difficulty. Sits behind the transport seam exactly as a remote peer does, which is what lets solo play ship in Release.
  owns: [ Willagrams/Bot/**, Tests/BotTests/** ]
  assignee: nate
  depends on: match (MatchTransport seam and the MatchMessage wire — contract Willagrams/Match/MatchTransport.swift), style (tokens for the difficulty control — contract Willagrams/Style/DesignTokens.swift). Also builds on the frozen engine (BoardAnalysis word extraction and connectivity) — no lane edge, fenced under protected:

- lane: audio
  area: Sound and haptics — tile placement, draw, win and loss cues, menu feedback, a mute control, and respecting the system silent switch.
  owns: [ Willagrams/Audio/**, Tests/AudioTests/** ]
  assignee: nate
  depends on: style (motion/timing tokens — contract Willagrams/Style/DesignTokens.swift)

- lane: launch
  area: App Store readiness — privacy policy, in-app account deletion checklist, store metadata, screenshots, App Review notes, and the pre-submission audit. Mostly not code. Runs last, after the tuning pass.
  owns: [ fastlane/**, docs/store/** ]
  assignee: nate
  depends on: every other lane (sequenced — the audit runs against a complete build)
