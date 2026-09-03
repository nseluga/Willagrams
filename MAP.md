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
  - Willagrams/Online/BackendContracts.swift
  - Willagrams/Audio/AudioPlayer.swift

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

Two test packages contain directory symlinks into other lanes:

    Tests/ShellTests/BoardSrc   → Willagrams/Board
    Tests/ShellTests/MatchSrc   → Willagrams/Match
    Tests/ShellTests/StyleSrc   → Willagrams/Style/Terminology.swift
    Tests/OnlineTests/MatchSrc  → Willagrams/Match
    Tests/OnlineTests/OnlineSrc → Willagrams/Online

`shell` owns `Tests/ShellTests/**` and `online` owns `Tests/OnlineTests/**`, so
an agent editing what looks like its own test package can write through a
symlink into `board`, `match`, `style` or `online`. The glob overlap check
cannot see this — the tracked object is the symlink.

`Tests/OnlineTests/OnlineSrc` points inside `online`'s own lane, but
`Tests/OnlineTests/MatchSrc` is a live write-through into `match`: the app
compiles `Match` and `Online` as one module, so the fixture package has to
compile both directories together to see `MatchTransport` at all.

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

Landed on `main`. `MatchOptions` exists in the engine, and `WireFormat.current`
was 2 at the time. The round-2 v3 amendment superseded both: the golden fixture
is now `Tests/WillagramsRulesTests/Fixtures/wire-v3.json`.
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

## Landed amendment — wire v3, up to 6 players

**Landed 2026-08-19 in `83e300c` (`/foundation` round 2). Not a lane item.**

`WireFormat.current` is `3`, `MatchMessage.start` carries `roster: [PlayerID]`
sorted ascending, and `HostPool.host(of:)` picks `roster[0]` on every device, so
there is still no negotiation message. The `match` lane is unblocked.

What follows is the amendment as written, kept because it is the record of why
the break was confined where it was.

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

**Both are spent.** The opening deal and the board-commit bridge landed in round
1 as `Willagrams/Shell/MatchBoard.swift`, and `BoardView`'s init became
binding-based in `bad1bb2`. A round-2 item wanting a `match` or `board` path is
a fresh amendment, not covered by either.

**Also landed under the second grant, 2026-08-19 (`8cdbcae`):** the invalid-run
flash — `BoardModel.flashedInvalid` / `attemptedCompletion()` / `clearFlash()`
and `BoardView(completionAttempts:)`. Written 2026-08-17, stranded uncommitted,
replayed onto `integration`. Recorded here because it crossed into
`Willagrams/Board/**` and the glob check cannot see a crossing after the fact.
Detail in `progress/board.md`.

## Granted amendment — the host's remaining pool count, in `shell`

`MatchHUDModel.poolRemaining` is hardcoded `nil`, so the HUD's Pool reads `—`
for the whole match. The count exists — `HostPool.pool` is already
`public private(set)` — but `MatchSession.hostPool` is `private`, and that file
is `match`'s.

**Granted:** the `shell` lane may add a published remaining-pool count to
`Willagrams/Match/MatchSession.swift`, and only that. Its agents do not stop at
the fence for it. Every other path in `match`'s `owns:` remains closed.

Scope, stated because the two halves are not the same problem:

  - **The host's own count is in scope.** The local player holds the `hostPool`
    and can read it. Solo practice elects the local player host, so this is the
    whole of what round 2 needs.
  - **A guest's count is not.** A guest has `hostPool == nil` and cannot know the
    number. Broadcasting it needs a new field on `MatchMessage`, which is
    `protected:` — a wire break to v4 and a `/foundation` amendment. No guest
    exists until the `online` lane lands, so it is not a round-2 question.

Rationale: the same one the grants above carry — every lane has one assignee,
`match` is merged, and a whole lane round for one published integer is ceremony.

## Recorded crossing — the design-comp visual pass, 2026-08-20

**Not a lane. Run directly on `design/visual-pass-r1`, cut from `main`.**

A Claude Design comp of eleven screens arrived after `style`, `shell` and
`settings` had all closed. Rerunning three closed lanes to repaint them would
have cost more than the repaint, so the visual pass ran in one session across
all three trees at once. Recorded here because it crossed `Willagrams/Style/**`,
`Willagrams/Shell/**`, `Willagrams/Settings/**` and `Tests/StyleTests/**`, and
the glob check cannot see a crossing after the fact — same reason as the
`8cdbcae` entry above.

**Hard rule the pass held to: no functional change.** Layout, type, colour,
spacing, card and shadow treatment, and the wordmark. No new data on any screen,
no new action, no new state. Every test count is unchanged at 653 across the
seven packages, which is the evidence: a functional change would have moved one.

Landed:

  - `Willagrams/Style/` gains four shared primitives — `BrandLabel` (the mono
    metadata modifier), `WordmarkTiles` (the crossword mark), `ScreenHeader`,
    `StatRow`. All four joined `StyleSourceTests.views`, so the no-literals and
    no-system-colour guardrails cover them.
  - `MenuView` is two-column landscape with the wordmark; same two actions.
  - `HowToPlayView` is a two-column card grid under a `ScreenHeader`.
  - `CountdownView` and `ResultsView` open their cards with a mono kicker.
  - `MatchOptionsView` and `RulesInForceView` take the kicker header and a
    bounded panel width.

**No `MAP_PROGRESS.md` row was added. No lane ran** — recording one would make
the progress file claim a round that did not happen.

What the comp shows and this repo deliberately does not build is written up in
`docs/design/README.md`, screen by screen, with the reason for each. A lane
picking up one of those screens should read that file first.

## Recorded crossing — the in-match HUD round, 2026-08-24

**Not a lane. Same branch as the visual pass above, and unlike it, this one DID
change what the app does.** Recorded here because it crossed
`Willagrams/Shell/**`, `Willagrams/Board/**` and `Willagrams/Style/**`.

The comp has no in-match screen — see `docs/design/README.md` — so this layout
was decided in session, from what the screen was actually doing wrong.

  - **The HUD is three corners, not one bar.** The bag top-leading, Draw and
    Swap bottom-leading, Resign bottom-trailing. `BoardView`'s recenter control
    moved to top-trailing to make room. One bar had put the pool readout inside
    the run of pressable things and left the whole top of the table empty.
  - **The pool is a bag with its count on it**, in `Palette.ink`.
    `Terminology.pool` is still the accessibility label — the frozen name is
    what VoiceOver reads, and dropping the visible word is a layout decision,
    not a rename.
  - **The win call waits for an empty pool.** `isWinEnabled` was
    `{ isDrawEnabled }`, which is backwards: Draw is disabled once the pool runs
    out, so the control for ending the match was live all game and dead at the
    one moment it could ever have been pressed. It now needs an exhausted pool
    AND a finished board, and `MatchHUD` shows it only then. Guardrail against
    deriving it from Draw's gate again.
  - **Tiles travel between the bag and the table.** One `FromBag` modifier, run
    forwards on arrival and backwards on removal, so a draw and a swap are the
    same motion in both directions. Keyed on which tiles are on the table, never
    on where they are — a drag must not run it. This is the deal animation
    `progress/board-lane-plan.md` cut as out of scope; it is in scope now that
    there is a shell to start a real match.
  - **`Typography.button` 17 -> 20**, the one number all three button styles
    read, so every button in the app is bigger.

Test counts moved, as they should for a functional change: ShellTests 101 ->
102, BoardTests 249 -> 251.

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

## Decided — the Release fence comes down onto `BotMatch`, 2026-08-21

**Nate's call, and it settles a framing error this file carried.** There is no
practice mode with no opponent. **Solo *is* the bot match** — one real player,
one `BotMatch` opponent, no second product and no separate no-opponent path.
The menu's "Solo Practice" button is the v1 feature, not a debug affordance
standing in for one.

So the fence does not need a feature behind it before it can come down; it needs
the shell pointed at the opponent that already ships. What follows is still an
accurate description of the fence and still the work.

### Fixed on the way — the match never started, 2026-08-21

Not the fence, which is open in Debug. `MatchSession` runs its own countdown and
flips `state.status` to `.playing` when the last second lands, and **nothing
carried that to `ShellModel.route`**: `countdownFinished()` had nine call sites
and all nine were tests. The app dealt a rack, the card went away, and the route
sat on `.countdown` for good — a board with no HUD and no way to play. Fixed in
`ShellRootView` (`7331611`), with a source guardrail so the wire cannot go
missing again.

### Fixed on the way — the invalid-board flash was unreachable, 2026-08-24

The same shape, one screen over, and also not the design pass: `MatchHUD.swift`
has not been touched since `a4c453e`. `MatchHUDModel.refuse()` counts a refused
Draw or win claim, and `BoardView` keys its red flash on that count — but
`isDrawEnabled` folded in `board.canDraw`, and `MatchHUD` gates both buttons on
it with `.disabled()`. So the control was dead in exactly the state the flash
exists to explain: the press never arrived, the count never rose, no run ever
tinted. The suite was green because every test calls `hud.draw()` directly.

Tappability and drawability are now two questions. `isDrawEnabled` gates only
the three states where drawing is meaningless (match over, peer absent, pool
exhausted); `draw()` and `claimWin()` check `board.canDraw` themselves and
refuse through the counter. Source guardrail on the gate.

**The lesson for every lane still to run:** a green suite proves the model
transitions, not that anything in the app calls them. A transition whose only
callers are tests is not wired — and a control that is `.disabled()` in the
state its own refusal path describes is the same bug wearing a different hat.

### Fixed on the way — the opening block opened on the lattice corner, 2026-08-24

Third instance of the same shape, found by the same question. `BoardLayout.opening`
lays the block from `Coord(0, 0)`, so a default camera opens on the corner of the
lattice: the rack in the top-left, three quarters of the screen empty, recenter
required before the first move. The board lane's throwaway app root framed the
block before handing the camera over; `ShellRootView` replaced that root in
`eb39f9e` and did not carry the framing across. `BoardLayout.framing` has had
**zero production callers** since — only `BoardLayoutTests`. Fixed in `27d3a40`
by framing through `BoardGesture.recentered` on `.task(id: board)`, guarded by
`hasFramed`. Source guardrail in `BoardSourceTests`. Verified on the simulator.

### Fixed on the way — the flash had nothing to tint, 2026-08-24

`ee6c73b` made the refused press *arrive*. It still tinted nothing, and that was
a second, deeper defect. `BoardAnalysis.isComplete` is `clusterCount == 1 &&
invalidWords.isEmpty && tileCount >= 2`, and `attemptedCompletion` built its
flash set from `invalidWords` alone — so a board refused for being **in pieces**
had nothing to point at. That is not an edge case: it is the first Draw every
player presses. A freshly dealt board is loose letters, so `invalidWords` is
empty, because a word needs two letters to exist.

Fixed in `850db17`. `BoardModel` now keeps the coords outside the biggest
cluster alongside the bad runs — written in the same one place published
validation is — and the flash is the union of the two. The biggest cluster is
what the player is building on, so what needs moving is everything else; ties
fall to the lowest coord in reading order, never to `Set` iteration order.

**No foundation round was needed.** `Board.clusters` was already public — only
`BoardValidation` withholds the coords, and nothing had to read them from there.
Verified on the simulator: twenty of twenty-one opening tiles go red.

**Verified still true 2026-08-20. This is the largest thing between the repo and
a build a stranger can play.**

`Willagrams/Bot/BotMatch.swift` opens with "the whole point of this lane: no
`#if DEBUG` fence. This ships." That is true of `BotMatch` itself and false of
the app around it:

  - `ShellModel.run` is `#if DEBUG`, because `MatchRun` owns a `SoloMatch`,
    which owns a `FakeTransport`, which must not ship.
  - `ShellModel.startSoloPractice()` opens with `#if !DEBUG return false`, and
    refuses on purpose — advancing the route with no run would soft-lock the
    menu's one button.
  - `ShellRootView` fences `.countdown`, `.match` and `.results` the same way.

So a Release build today is a menu and a rules screen. The fix is not a new
feature: it is switching the shell from `SoloMatch`/`FakeTransport` to
`BotMatch` over a local link, which already ships unfenced with 63 tests behind
it. It crosses `Willagrams/Shell/**` and `Willagrams/Bot/**`, so it is an
amendment or a round-2 `shell` item, not something a visual pass may touch.

## Decided — what the `audio` lane is and is not, 2026-08-25

Three things about the audio seam were discovered when the lane opened, and all
three would otherwise be found again by whoever runs it.

**The seam has zero call sites, and that is not this lane's problem.** Nothing
outside `Willagrams/Audio/` references `AudioPlayer`, `SoundEffect` or
`HapticStrength`, despite `AudioPlayer.swift`'s own header saying the shell
would wire them first. It didn't. That work crosses `Willagrams/Shell/**`,
`Willagrams/Match/**` and `Willagrams/Board/**`, and **`shell` already carries
the edge** — its `depends on:` line ends `audio (playback seam — sequenced)`.
So the call sites are a **shell round 3** item, not an audio amendment. The
audio lane ships a working player that nothing calls yet, and that is the
design, not a gap.

**Mute is sound only. Haptics are not muted, and this is correct.** Two
independent haptics stacks exist: `AudioPlayer.impact` in this seam, and
`BoardHaptics` / `BoardHapticEvent` / `TileFeedback` in
`Willagrams/Board/BoardDrag.swift` and `BoardFeedback.swift`, which fires UIKit
generators directly and does not route through the seam. That looked like a
contradiction — an app-level mute that leaves tile pickup buzzing — and it is
not one. iOS governs haptics through its own System Haptics setting, and the
silent switch does not mute them either; an in-app control that silenced them
would be the odd behaviour, not the expected one. **No board amendment.**
`TileFeedback` stays where it is and keeps firing directly.

**The mute state is audio's; the mute control is not.** `audio` owns the muted
flag and its persistence inside `Willagrams/Audio/**`. The toggle the player
actually taps lives in `Willagrams/Settings/**`, which is `settings`' `owns:`
and merged. MAP lists "a mute control" in this lane's `area:` and that line
overreaches — it was written before the settings lane closed. The control is a
shell round 3 or settings amendment item. Audio ships the state it reads.

**Build constraint, inside `owns:` and so not an amendment:**
`Tests/AudioTests/AudioSrc` is a directory symlink to `Willagrams/Audio` and the
package declares `.macOS(.v14)`, so **the whole directory compiles on the host**.
One AVFoundation or UIKit import added there breaks
`swift test --package-path Tests/AudioTests`. The lane splits a host-compilable
routing layer from a `#if canImport(UIKit)` hardware file, or excludes the
hardware file in `Package.swift`. `Tests/BoardTests` dodged this by never
compiling `Willagrams/Board` at all.

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
  depends on: — builds on the frozen engine (MatchMessage wire enum in Sources/WillagramsRules/MatchMessage.swift, golden fixture Tests/WillagramsRulesTests/Fixtures/wire-v3.json; host-side Pool.draw/swap in Sources/WillagramsRules/Pool.swift) — no lane edge, fenced under protected:. The wire v3 amendment landed 2026-08-19 in `83e300c`, so this lane is unblocked.

- lane: settings
  area: Match configuration and rule variants — the host's pre-match options screen, local persistence of chosen defaults, and showing both players which rules are in force. Ships the disable-swap, minimum-word-length, and selectable-dictionary controls.
  owns: [ Willagrams/Settings/**, Tests/SettingsTests/** ]
  assignee: nate
  depends on: match (MatchOptions on the wire — contract Sources/WillagramsRules/MatchOptions.swift), style (tokens + Terminology strings — contract Willagrams/Style/DesignTokens.swift)

- lane: shell
  area: App shell — launch, opening animation, the home page and its actions (start a match, how to play), the countdown/match/results routes and the navigation between them, in-match HUD, results and rematch. Round 2 replaces the placeholder routes with the real screens and composes them into a playable match; the board-commit bridge landed in round 1 as `Willagrams/Shell/MatchBoard.swift`. Feature lanes own their own screens; shell navigates into them.
  owns: [ Willagrams/Shell/**, Willagrams/App/**, Tests/ShellTests/** ]
  assignee: nate
  depends on: style (tokens + Terminology strings — contract Willagrams/Style/DesignTokens.swift), board (BoardView init signature — contract Willagrams/Board/BoardView.swift), match (MatchSession + MatchTransport — contracts Willagrams/Match/MatchTransport.swift), bot (the solo opponent and its difficulty screen — contracts Willagrams/Bot/BotMatch.swift, Willagrams/Bot/BotDifficultyView.swift — sequenced: shell's bot wiring sits below its stop marker and runs once bot merges), settings (options screen entry point — contract Willagrams/Settings/Views/MatchOptionsView.swift), online (match creation and invite — sequenced), account (sign-in and profile screen entry points — sequenced), friends (friends screen entry point — sequenced), audio (playback seam — sequenced)

- lane: online
  area: The backend seam that replaces GameKit — hosted client, authentication session, database access, and the MatchTransport adapter over realtime channels. Owns match creation and the invite plumbing behind shell's buttons. Owns the schema migrations. Does not own any screen.
  owns: [ Willagrams/Online/**, Tests/OnlineTests/**, supabase/** ]
  assignee: nate
  depends on: match (MatchTransport protocol it implements, and the MatchMessage wire it carries — contracts Willagrams/Match/MatchTransport.swift, Sources/WillagramsRules/MatchMessage.swift)

- lane: account
  area: Identity screens — Sign in with Apple, the profile page and its stats. Reads the session and the user record from `online`; owns no client and no schema. No phone sign-in: Supabase sends no SMS itself and every supported provider is paid, so Sign in with Apple is the only route this release.
  owns: [ Willagrams/Account/**, Tests/AccountTests/** ]
  assignee: nate
  depends on: online (auth session + user record — the schema landed 2026-08-19 in `83e300c`: `docs/schema.md`, `supabase/migrations/0001_init.sql`, and the `BackendClient` seam with a complete `FakeBackend` behind it, so this lane can be built and tested with no server), style (tokens — contract Willagrams/Style/DesignTokens.swift)

- lane: friends
  area: The friends page — friends list, friend requests and accept/block, and invites by share link and short friend code. No chat this release, and no phone-number invites: that would need a paid SMS provider, so a friend code carried over any messenger the player already has replaces it.
  owns: [ Willagrams/Friends/**, Tests/FriendsTests/** ]
  assignee: nate
  depends on: online (client + friend tables — landed 2026-08-19 in `83e300c`; `Friendship`/`FriendshipStatus` and the friend calls are on `BackendClient`, faked end to end), account (the current user — sequenced), style (tokens — contract Willagrams/Style/DesignTokens.swift)

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
