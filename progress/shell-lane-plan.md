# Willagrams — Lane: shell, round 2

Lane: shell — App shell: launch, opening animation, the home page and its actions (start a match, how to play), the countdown/match/results routes and the navigation between them, in-match HUD, results and rematch. Feature lanes own their own screens; shell navigates into them.

Owned — this lane's items live inside these paths:
  Willagrams/Shell/**
  Willagrams/App/**
  Tests/ShellTests/**

Stop and report if an item requires changing a path outside them:
  protected — Sources/WillagramsRules/Contracts.swift, BoardAnalysis.swift, Pool.swift, GameState.swift, MatchMessage.swift, MatchOptions.swift, WordList.swift, Resources/dictionary.txt; Tests/WillagramsRulesTests/**; Willagrams/Match/MatchTransport.swift; Willagrams/Style/DesignTokens.swift; Willagrams/Style/Terminology.swift; Willagrams.entitlements; Package.swift; supabase/migrations/**; Willagrams/Online/BackendContracts.swift; Willagrams/Audio/AudioPlayer.swift
  another lane's — Willagrams/Style/**, Willagrams/Resources/Branding/**, Willagrams/Assets.xcassets/**, Tests/StyleTests/**, docs/ip-review.md (style) · Willagrams/Board/**, Tests/BoardTests/** (board) · Willagrams/Match/**, Tests/MatchTests/** (match) · Willagrams/Settings/**, Tests/SettingsTests/** (settings) · Willagrams/Online/**, Tests/OnlineTests/**, supabase/** (online) · Willagrams/Account/**, Tests/AccountTests/** (account) · Willagrams/Friends/**, Tests/FriendsTests/** (friends) · Willagrams/Bot/**, Tests/BotTests/** (bot) · Willagrams/Audio/**, Tests/AudioTests/** (audio) · fastlane/**, docs/store/** (launch)
  unowned — `.` (repo root: MAP.md, Package.swift, README, .gitignore, Willagrams.entitlements) · `.claude/**` · docs/*.md · progress/** · Sources/WillagramsRules/** and Tests/WillagramsRulesTests/** · Willagrams.xcodeproj/**

Frozen contracts — build and test against these; they will not move:
  style — Willagrams/Style/DesignTokens.swift (token key names; values may change under you) and Willagrams/Style/Terminology.swift. Fixture: Tests/StyleTests (source-grep suite, 30).
  board — Willagrams/Board/BoardView.swift, binding-based init taking board, model, camera, dictionary, inputLocked, completionAttempts. Fixture: Tests/BoardTests (248).
  match — Willagrams/Match/MatchTransport.swift and MatchSession's public surface. Fixture: Tests/MatchTests (124) and the golden wire Tests/WillagramsRulesTests/Fixtures/wire-v3.json.
  settings — Willagrams/Settings/Views/MatchOptionsView.swift. Fixture: Tests/SettingsTests (36).

Test against the fixture, not the producing lane. Do not wait for it to exist.

Items scope to this lane only. An item requiring a `protected:` change is not a
lane item — it is an amendment request.

## Status

Round 1 built every screen and every model this round needs, and composed none
of them. `ShellRootView` still renders bare `Text` placeholders for the
countdown, match and results routes; there is no `MatchView.swift` at all;
nothing owns a `SoloMatch` across the three routes; and `Terminology.winCall`
has no caller, so a solo match cannot be won. This round wires what exists into
a match that plays start to finish.

`MatchBoard.swift` — the board-commit bridge — landed in round 1 and is not in
this round. The invalid-run flash landed on `integration` in `8cdbcae` and has
no caller in the app; item 4 gives it one.

## Global rules

- **No SwiftUI view in this repo can be tested headlessly.** `Tests/ShellTests`
  builds for macOS and its `Shell` target excludes every View. Every decision,
  transition and derived string therefore lives in an observable model or a pure
  function; views stay thin enough that nothing untested hides in them. A view
  holding a branch that changes behavior is a defect, not a style choice. A new
  View file must be added to that target's `exclude:` list or the suite stops
  building — `SourceGuardrailTests` fails first and says so.
- **Never `import GameKit`.** `Tests/MatchTests/Cases/SourceGuardrailTests.swift`
  asserts no file ever does. Game Center is out of the project entirely.
- **`Terminology.swift` is frozen and is the IP fence.** Use `Terminology.pool`,
  `.draw`, `.swap`, `.winCall`, `.invalid`, `.countdownTitle` for game concepts.
  Screen chrome it does not define — "Resign", "Rematch", "Main Menu", "How to
  Play" — is declared local to the view that uses it, following the
  `BoardView.recenterLabel` precedent. The Bananagrams vocabulary (Bunch, Split,
  Peel, Dump, Bananas, Rotten) must never appear in player-facing copy.
- **⚠️ `MatchSession` is at a Swift 6.3.3 toolchain limit.** One more *observed*
  stored property makes MatchTests abort in the reconnect path with
  `swift_task_dealloc`. Any storage added there must be net-zero observed
  properties — mark one existing property `@ObservationIgnored` to compensate —
  and `swift test --package-path Tests/MatchTests` must be run to prove it.
- **Each nested test package needs its own literal `--package-path` command.**
  A shell variable does not word-split. The eight are: `.` (53), `Tests/BoardTests`
  (248, XCTest — reports "Executed N"), `Tests/MatchTests` (124),
  `Tests/StyleTests` (30), `Tests/ShellTests` (61), `Tests/SettingsTests` (36),
  `Tests/AudioTests` (6), `Tests/OnlineTests` (26).
- **`swift test` never compiles SwiftUI.** Only
  `xcodebuild -scheme Willagrams -destination 'generic/platform=iOS Simulator' build`
  does. Every item that touches a View must run it.
- Fuller context: `MAP.md` (lane map, `protected:`, the granted amendments) and
  `FOUNDATION.md` (the frozen contracts).

## One granted amendment

`MAP.md` grants this lane one path outside its `owns:`: **item 6 only** may add
a published remaining-pool count to `Willagrams/Match/MatchSession.swift`, and
nothing else in `match`. No other item opens a `match` path, and no item opens a
`board` path — the round-1 grants for the opening deal, the board-commit bridge
and `BoardView`'s init are all spent.

---

- task: Own the match run across the countdown, match and results routes. Build one
    type — `Willagrams/Shell/MatchRun.swift` — that constructs a `SoloMatch`, a
    `MatchBoard` over its session, and a `MatchHUDModel` over both, and holds all
    three for the life of one match. `ShellModel.startSoloPractice` builds it;
    `returnToMenu` tears it down. It also supplies the two closures `ResultsModel`
    takes and nothing currently provides: `teardown`, which calls `SoloMatch.leave()`,
    and `startRematch`, which discards the finished run and builds a fresh one with a
    new seed. Today each route would have to build its own session, so the countdown
    and the match it becomes would hold different `MatchSession` instances.
  guardrails:
    - A rematch must not leave the previous `SoloMatch`'s peer pump alive. `SoloMatch.peerTransport` is deliberately `internal` so a test can send from a finished match's transport and prove nothing reaches the session that replaced it
    - Never hold two live `MatchSession` instances at once — the old run is torn down before the replacement is constructed, not after
    - Do not add an observed stored property to `MatchSession` (Swift 6.3.3 limit, see Global rules)
    - `MatchRun` holds no SwiftUI and makes no routing decision; it is constructed and released by `ShellModel`
  done when:
    - Starting solo practice constructs exactly one `MatchSession`, and the countdown, match and results screens all read that same instance
    - Returning to the menu cancels the peer pump and leaves the transport, and a send from the finished run's `peerTransport` afterwards changes no state on any live session
    - Rematch yields a new `MatchSession` with a different seed, and the previous run's `peerTransport` cannot reach it
    - Existing passing tests remain passing
  caution: true
  status: done

- task: Compose the match screen. New `Willagrams/Shell/MatchView.swift` rendering
    `BoardView` bound to `MatchBoard.board` and `MatchBoard.model`, with `MatchHUD`
    over it. The surface's measured size and camera are written back into
    `MatchBoard.viewport` and `MatchBoard.camera` so a delivery lands inside what the
    player is actually looking at — `MatchBoard.sync()` reads both and hands them
    straight to `BoardLayout`. `MatchHUD` already lays itself out bottom-leading
    precisely so it does not cover `BoardView`'s top-trailing recenter control.
  guardrails:
    - `MatchView` computes no coordinate. Camera and viewport are handed to `MatchBoard` unchanged
    - Never write `MatchBoard.viewport` during view body evaluation — that is a mutation-during-update and it either warns or hangs
    - The HUD must not overlap `BoardView`'s recenter control
    - `MatchView` makes no routing decision and holds no branch that changes what the app does
    - Add the new View to the `Shell` target's `exclude:` list in `Tests/ShellTests/Package.swift`, or the suite stops building
  done when:
    - `MatchView` is the one shell file composing `BoardView` and `MatchHUD`, and passes `MatchBoard`'s `board` and `model` as bindings rather than copies, so a drag commits into the same value the session mirrors
    - The viewport `MatchBoard` receives is the surface's measured size rather than a hard-coded one, taken outside body evaluation
    - `xcodebuild -scheme Willagrams -destination 'generic/platform=iOS Simulator' build` succeeds
    - Existing passing tests remain passing
  status: done

- task: Wire `ShellRootView`'s three placeholder cases to the real screens —
    `CountdownView` for `.countdown`, `MatchView` for `.match`, `ResultsView` for
    `.results` — reading them off the `MatchRun` item 1 built. Delete the
    `placeholder(_:)` helper and the two local label constants that only fed it.
  guardrails:
    - No navigation container of any kind — `ShellRootView` stays a `switch` over `ShellModel.route` and nothing else. A guardrail test enforces this by name
    - The view holds no navigation state and makes no routing decision
    - A route whose `MatchRun` is absent must not crash — it renders nothing and the transition that should have built one is the defect
  done when:
    - All four routes render their real screen, and `ShellRootView` defines no `placeholder(_:)` helper
    - The existing guardrail test asserting no navigation container still passes
    - `xcodebuild -scheme Willagrams -destination 'generic/platform=iOS Simulator' build` succeeds
    - Existing passing tests remain passing
  status: done

- task: Give the invalid-run flash a caller. `MatchHUDModel` publishes a
    `completionAttempts` counter that `MatchView` passes into `BoardView`, and every
    refused completion claim increments it. `BoardModel.attemptedCompletion()` and the
    `.task(id:)` that flashes and fades already exist on the board side (`8cdbcae`);
    nothing in the app increments the counter, so a refused Draw currently explains
    nothing to the player.
  guardrails:
    - The counter only ever increases; never reset it to re-arm a flash — `BoardView` keys `.task(id:)` on the value and a reset would replay a stale flash
    - Do not restate the completeness rule here. `MatchHUDModel.isDrawEnabled` and `BoardModel.canDraw` are the gate; this item only reports a refusal
  done when:
    - A Draw press that `MatchHUDModel.draw()` refuses increments the published counter; a press that succeeds does not
    - `MatchView` passes that counter into `BoardView`'s `completionAttempts` parameter
    - Existing passing tests remain passing
  status: done

- task: Add the win claim. `MatchSession.claimWin()` exists, is covered by the match
    suite, and has no caller anywhere in the shell — so a solo match cannot be won.
    Add a `Terminology.winCall` control to `MatchHUD`, backed by a `MatchHUDModel`
    method that calls `claimWin()`, and route an accepted claim to `.results`.
  guardrails:
    - Do not restate the completeness rule. The gate is `session.claimWin()`'s own answer plus the same three states `isDrawEnabled` already excludes
    - A refused claim must leave the route on `.match` — it is a refusal, not an outcome
    - Use `Terminology.winCall`; never spell the phrase as a local string
  done when:
    - The HUD shows a `Terminology.winCall` control, disabled in exactly the states `Draw` is disabled in
    - A refused claim increments the flash counter from item 4 and leaves the route on `.match`
    - An accepted claim routes to `.results` with the local player as the winner
    - Existing passing tests remain passing
  status: done

- task: Publish the host's remaining pool count and show it in the HUD.
    `MatchHUDModel.poolRemaining` is hardcoded `nil`, so Pool reads `—` for the whole
    match. `HostPool.pool` is already `public private(set)`; `MatchSession.hostPool`
    is `private`. Under the `MAP.md` grant, add a published count to
    `Willagrams/Match/MatchSession.swift` and return it from `poolRemaining`.
  guardrails:
    - Only `Willagrams/Match/MatchSession.swift` may change under the grant — no other `match` path, and no `Tests/MatchTests` edit
    - No shell-side ledger of grants. The count comes from `HostPool.pool` or it is `nil` — a shell-side tally is a second source of truth that can silently disagree with the pool it describes
    - A session with no `hostPool` publishes `nil`, never a guess. A guest cannot know this number
    - No `Task` spawned per view body evaluation to read the actor
    - Net-zero observed stored properties on `MatchSession` (Swift 6.3.3 limit), and `swift test --package-path Tests/MatchTests` must pass
  done when:
    - During a solo match `MatchHUDModel.poolValue` renders the real remaining count, and it decreases as tiles are drawn
    - A session with no `hostPool` publishes `nil` and `poolValue` stays `MatchHUDModel.unknownValue`
    - `swift test --package-path Tests/MatchTests` passes at 124 or more
    - Existing passing tests remain passing
  status: done
  parallel-group: a

- task: Add the how-to-play screen and the menu route to it. `MenuView` currently
    offers exactly one action. Add a second that routes to a new `AppRoute` case
    rendering a rules screen: what a Pool, a Draw and a Swap are, that every tile
    must join one connected group with no invalid words before you may Draw, and
    that `Terminology.winCall` ends the match. A control returns to the menu.
  guardrails:
    - Game concepts use `Terminology`; the Bananagrams vocabulary must never appear
    - The new route carries no match state — it is reachable from the menu and returns there, and cannot be reached from inside a match
    - `AppRoute` stays a value where an unrepresentable state is unrepresentable: the new case carries nothing, because the screen renders nothing match-specific
    - Add the new View to the `Shell` target's `exclude:` list in `Tests/ShellTests/Package.swift`
  done when:
    - The menu offers a how-to-play action that moves the route to the new case, and the screen's own control returns the route to `.menu`
    - The rules copy names Pool, Draw, Swap and the win call via `Terminology`, and contains none of Bunch, Split, Peel, Dump, Bananas or Rotten
    - `xcodebuild -scheme Willagrams -destination 'generic/platform=iOS Simulator' build` succeeds
    - Existing passing tests remain passing
  status: done
  parallel-group: a

> **⚠️ AUTONOMOUS RUN — STOP HERE**

> The two items below are the bot wiring. They sit after the stop marker on
> purpose: `BotMatch` does not exist until `lane/bot` merges, so an unattended
> run must halt above this line. Resume this lane once bot is on `integration`.

- task: |
    Play against the bot instead of against silence.

    `Willagrams/Shell/MatchRun.swift` (item 1) owns the match across the three
    routes by building a `SoloMatch`, which is `#if DEBUG` because
    `FakeTransport` is — so the match screen this round composes cannot ship in a
    Release build. Replace that opponent with `Willagrams/Bot/BotMatch.swift`,
    which is the same shape without the fence: it owns the in-memory link, hands
    back the human-side transport to build this device's `MatchSession` on, and
    runs the bot's own guest session behind it.

    `MatchRun` takes a `BotDifficulty` and passes it through. Teardown and
    rematch keep the order item 1 established — the old opponent down before the
    new one is built — and `ResultsModel`'s `teardown`/`startRematch` closures
    now capture the `BotMatch`. Delete the `#if DEBUG` fence from `MatchRun` and
    everything it forced; `SoloMatch.swift` itself stays where it is, still
    fenced, still covered by `SoloMatchTests`.

    `Tests/ShellTests/Package.swift` needs a symlinked `Bot` target so the macOS
    suite can see `BotDifficulty` and `BotMatch`; follow the `MatchSrc` pattern
    already there, and exclude the bot's SwiftUI files.
  guardrails:
    - No shell file may carry `#if DEBUG` around the live match path once this lands — that fence is what this item exists to remove
    - `Willagrams/Bot/**` is another lane's `owns:` — consume it, never edit it
    - Teardown before rebuild, unchanged: repeated rematches must not leave live sessions or pumps stacked up
    - The human end stays host; nothing here may change the election `BotMatch` runs
  done when:
    - A match built through `MatchRun` runs start to finish against the bot, and the results screen names a winner that is not always the local player
    - No file under `Willagrams/Shell/**` or `Willagrams/App/**` references `SoloMatch` on the live match path, and none fences that path behind `#if DEBUG`
    - Rematching three times in a row leaves exactly one live match, proven the way `RematchTests` already proves it for `SoloMatch`
    - `swift test --package-path Tests/ShellTests` and the iOS `xcodebuild` build both pass
  status: not started

- task: |
    Give the difficulty screen a route.

    `Willagrams/Bot/BotDifficultyView.swift` is a standalone screen that reports
    a `BotDifficulty` through a closure and starts nothing. Shell owns the
    navigation into it: add an `AppRoute` case for it, a `ShellModel` transition
    from the menu, a menu action that reaches it, and a `ShellRootView` branch
    that renders it — supplying the closure that carries the chosen difficulty
    into the countdown and on into `MatchRun`.

    The route case carries the difficulty forward, so the countdown and match
    routes need it too. Keep `AppRoute` a value where an unrepresentable state
    stays unrepresentable: a difficulty reaches the match route only by having
    been chosen.
  guardrails:
    - The difficulty screen is reachable only from the menu and returns there; it cannot be reached from inside a match
    - Shell renders the bot's screen and never reimplements it — no second difficulty control anywhere under `Willagrams/Shell/**`
    - Add any new View to the `Shell` target's `exclude:` list in `Tests/ShellTests/Package.swift`
  done when:
    - The menu offers an action that moves the route to the difficulty case, and choosing a preset moves the route to the countdown carrying that preset
    - A match started after choosing `.easy` and one started after choosing `.hard` reach `MatchRun` with different `BotDifficulty` values
    - The difficulty route is unreachable from the match and results routes
    - Existing passing tests remain passing
  status: not started

## Not yet specified

- Whether the opening animation MAP names as shell's belongs to the launch screen, the menu, or the countdown — revisit after item 3, when the real routes are on screen and there is something to animate between.

## Out of scope

- Friends, profile and sign-in entry points — `friends`, `account` and `online` are all `not started`, and shell is sequenced behind every one of them. Building a button now is a promise no lane has kept.
- Sound on any shell action — `audio` is `not started` and shell is sequenced behind it. `AudioPlayer.swift` exists as a frozen contract but has no lane behind it yet.
- The host's pre-match options screen — `MatchOptionsView` is merged and reachable, but solo practice takes no options and there is no second player to show the rules in force to. It lands with the first friend match.
- A guest's view of the remaining pool count — a guest has no `hostPool` and the number would have to ride a new `MatchMessage` field, which is `protected:` and a wire break to v4. No guest exists until `online` lands.
- The device pass — deliberately not an item. No test in this repo reaches a SwiftUI view, so layout, the flash, and whether a match is actually enjoyable are Nate's to check in the simulator after the run.

---

# Round 3 plan (archived 2026-09-08, merged as PR #4)

# Willagrams — Lane: shell, round 3

## Objective

Every screen the release ships that does not need the paid Apple membership is
reachable from the menu and works against the live backend: play a friend over
the network, a profile with stats, a friends list with in-app invites, and
sound.

Lane done when:
- On two simulators running the merged branch (Debug), one player hosts from
  the menu and shows an invite code, the other joins with it, both reach the
  match screen, and a win on one shows results on both with both `profiles`
  rows advanced by `record_outcome`.
- Two players on separate simulators friend each other by code; one taps the
  other in the friends list; the second sees the invite in-app, accepts, and
  they play a match to a result; either can open the other's profile and see
  their stats, read from the real database under RLS.
- In a solo match a tile placement, a Draw, and the win call each reach the
  app's one `AudioPlayer` with the matching `SoundEffect`; the app root builds
  `SystemAudioPlayer` in a Release build; muting persists across relaunch.
- All eleven test packages are green and
  `xcodebuild -scheme Willagrams -destination 'generic/platform=iOS Simulator' build`
  succeeds.

Lane: shell — App shell: launch, opening animation, the home page and its actions (start a match, how to play), the countdown/match/results routes and the navigation between them, in-match HUD, results and rematch. Feature lanes own their own screens; shell navigates into them. **Round 3, under the MAP grant of 2026-09-03, also owns the `account` and `friends` areas and wires every merged seam the menu still does not call.**

Owned — this lane's items live inside these paths:
  Willagrams/Shell/**
  Willagrams/App/**
  Tests/ShellTests/**
  Willagrams/Account/**      (granted 2026-09-03 — this round creates it)
  Tests/AccountTests/**      (granted 2026-09-03 — this round creates it)
  Willagrams/Friends/**      (granted 2026-09-03 — this round creates it)
  Tests/FriendsTests/**      (granted 2026-09-03 — this round creates it)

Open — merged lanes. Wiring items may edit these; rebase onto `integration` first:
  Willagrams/Style/**, Willagrams/Resources/Branding/**, Willagrams/Assets.xcassets/**, Tests/StyleTests/**, docs/ip-review.md (style)
  Willagrams/Board/**, Tests/BoardTests/** (board)
  Willagrams/Match/**, Tests/MatchTests/** (match)
  Willagrams/Settings/**, Tests/SettingsTests/** (settings)
  Willagrams/Bot/**, Tests/BotTests/** (bot)
  Willagrams/Online/**, Tests/OnlineTests/**, supabase/** except supabase/migrations/** (online)
  Willagrams/Audio/**, Tests/AudioTests/** (audio)

Stop and report if an item requires changing a path outside both lists:
  protected — Sources/WillagramsRules/Contracts.swift, BoardAnalysis.swift, Pool.swift, GameState.swift, MatchMessage.swift, MatchOptions.swift, WordList.swift, Resources/dictionary.txt; Tests/WillagramsRulesTests/**; Willagrams/Match/MatchTransport.swift; Willagrams/Style/DesignTokens.swift; Willagrams/Style/Terminology.swift; Willagrams.entitlements; Package.swift; supabase/migrations/**; Willagrams/Online/BackendContracts.swift; Willagrams/Audio/AudioPlayer.swift
  an unmerged lane's — fastlane/**, docs/store/** (launch)
  unowned — `.` (repo root: MAP.md, Package.swift, README, .gitignore, Willagrams.entitlements) · `.claude/**` · docs/*.md · progress/** · Sources/WillagramsRules/** and Tests/WillagramsRulesTests/** · Willagrams.xcodeproj/**

Frozen contracts — build and test against these; they will not move:
  style — Willagrams/Style/DesignTokens.swift (key names; values may change under you), Willagrams/Style/Terminology.swift. Fixture: Tests/StyleTests (30). Already consumed by every shell screen; no new wiring item.
  board — Willagrams/Board/BoardView.swift, binding-based init. Fixture: Tests/BoardTests (253). Consumed by MatchView; no new wiring item.
  match — Willagrams/Match/MatchTransport.swift and MatchSession's public surface. Fixture: Tests/MatchTests (125) and Tests/WillagramsRulesTests/Fixtures/wire-v3.json. Consumed by MatchRun; no new wiring item.
  bot — Willagrams/Bot/BotMatch.swift, BotDifficultyMenu.swift. Fixture: Tests/BotTests (68). Consumed by SoloMatch; no new wiring item.
  settings — Willagrams/Settings/Views/MatchOptionsView.swift (`init(form: Binding<MatchOptionsForm>)`), Willagrams/Settings/Model/SettingsStore.swift (`load()`, `save(_:)`). Fixture: Tests/SettingsTests (36). Wiring item: 6.
  online — Willagrams/Online/OnlineMatch.swift (`host(options:backend:...)`, `join(code:backend:...)`, `inviteCode`, `lobby`, `start()`, `awaitStart()`), Willagrams/Online/BackendContracts.swift (`BackendClient`), Willagrams/Online/SupabaseBackend.swift (`init()` reads the anon key itself; `signInAnonymously()` is `#if DEBUG`). Fixture: Tests/OnlineTests (126; 22 live cases gated on `WILLAGRAMS_LIVE_TESTS=1` and `SUPABASE_ANON_KEY`). `Tests/OnlineTests/Cases/WholeMatchScript.swift` is the reference call sequence for a whole online match. Wiring items: 3, 4, 10.
  audio — Willagrams/Audio/AudioPlayer.swift (`AudioPlayer`, `SoundEffect`, `HapticStrength`, `SilentAudioPlayer`), SystemAudioPlayer.swift (`init(bundle:muted:)`), AudioSettings.swift (`init(defaults:)`, `isMuted`, `setMuted(_:)`). Fixture: Tests/AudioTests (19). Wiring items: 11, 12.

Test against the fixture, not the producing lane. Do not wait for it to exist.

Items scope to this lane's owned paths plus the open merged-lane paths a wiring
item reaches. An item needing a `protected:` or unowned change is not a lane
item — it is an amendment request.

## Status

Rounds 1–2 built a solo match that plays start to finish in Release against
`BotMatch`. Since then `online` and `audio` merged with zero callers: no screen
constructs a `SupabaseBackend`, an `OnlineMatch` or any `AudioPlayer`, and the
menu still offers exactly two actions. `SoloSetupView` hand-rolls the option
rows `MatchOptionsView` already provides, and `SettingsStore` has no caller in
the app. `Willagrams/Account/` and `Willagrams/Friends/` do not exist.

Identity this round is the anonymous session `online` proved live. It is
`#if DEBUG` on purpose, so every online, profile and friends criterion runs in
a Debug build (what Xcode installs on a simulator or a free-team device). The
Release criterion covers solo play and audio only. Sign in with Apple sits
below the stop marker on the Apple Developer membership.

## Global rules

- **No SwiftUI view in this repo can be tested headlessly.** Every test package
  builds for macOS and excludes every View. Every decision, transition and
  derived string lives in an observable model or a pure function; views stay
  thin. A view holding a branch that changes behavior is a defect. **Every new
  View file must be added to its package's `exclude:` list** or the suite stops
  building — `SourceGuardrailTests` in ShellTests fails first and says so; the
  two new packages carry the same guardrail from their first commit.
- **New test packages follow the symlink pattern and its hazard.**
  `Tests/AccountTests` and `Tests/FriendsTests` symlink their own source
  directory plus `Willagrams/Online` (for `BackendContracts` and `FakeBackend`)
  and `Willagrams/Match` (Online compiles against `MatchTransport`), exactly as
  `Tests/OnlineTests/Package.swift` does. Board's SwiftUI files never compile
  on macOS: never symlink `Willagrams/Board` as a directory. A path reached
  through a symlink belongs to the lane that owns its target.
- **Friends is tested against the real database, not `FakeBackend`.** RLS
  refuses a read by returning zero rows and a write by affecting zero rows,
  never an error; the fake enforces no policy. Friends items carry live-gated
  cases on the OnlineTests pattern (`WILLAGRAMS_LIVE_TESTS=1` and
  `SUPABASE_ANON_KEY` from `.env`), each on freshly signed-in anonymous users
  it creates itself. Green with the gate skipped is not green.
- **Secrets never enter git.** `.env` and `Config/Secrets.local.xcconfig` are
  gitignored and already present in this worktree. No item writes a key into
  source, a test, a fixture or a log.
- **Never `import GameKit`.** `Tests/MatchTests/Cases/SourceGuardrailTests.swift`
  asserts no file ever does.
- **`Terminology.swift` is frozen and is the IP fence.** Use its names for game
  concepts. Screen chrome it does not define ("Play a Friend", "Friends",
  "Profile", "Invite code", "Join", "Waiting for host", "Reconnecting") is
  declared local to the view that uses it, per the `BoardView.recenterLabel`
  precedent. Bananagrams vocabulary (Bunch, Split, Peel, Dump, Bananas, Rotten)
  never appears in player-facing copy.
- **`MatchSession` is at a Swift 6.3.3 toolchain limit.** One more observed
  stored property aborts MatchTests in the reconnect path. No item here adds
  state to it; consume `peerPresences`, `presence(of:)`, `isMatchOver` as they
  are.
- **`AudioPlayer.play` and `.impact` are non-async, non-throwing, called from
  the main actor.** Never wrap a cue in a `Task` or a `do/catch`.
- **Each nested test package needs its own literal `--package-path` command.**
  A shell variable does not word-split. The eleven after this round: `.` (53),
  `Tests/BoardTests` (253, XCTest — "Executed N"), `Tests/MatchTests` (125),
  `Tests/StyleTests` (30), `Tests/ShellTests` (221), `Tests/SettingsTests`
  (36), `Tests/BotTests` (68, ~5 min), `Tests/OnlineTests` (132),
  `Tests/AudioTests` (19), `Tests/AccountTests` (15), `Tests/FriendsTests`
  (43; 4 live cases gated on `WILLAGRAMS_LIVE_TESTS=1` and `SUPABASE_ANON_KEY`). Two cases are wall-clock flaky under a full parallel run and pass
  alone: BotTests' pacing case and ShellTests' countdown overlay.
- **`swift test` never compiles SwiftUI.** Only
  `xcodebuild -scheme Willagrams -destination 'generic/platform=iOS Simulator' build`
  does. Every item that touches a View runs it.
- **Two-device behavioral checks run on two simulators** booted with
  `xcrun simctl`, each holding its own anonymous session. Never two instances
  on one simulator: they would share the keychain and the session.
- Fuller context: `MAP.md` (the grants, the symlink hazard, the "Decided"
  sections on audio and the Release fence), `FOUNDATION.md` (frozen contracts
  and the open broadcast-ordering risk), `docs/design/README.md` (the comp,
  screen by screen, and what it deliberately does not build), `docs/schema.md`.

## Not yet specified

- What the guest sees between accepting an invite and the countdown when the
  host is slow to press Start — a plain waiting screen this round; whether it
  needs a cancel that also tells the host is unknown until item 10 shows how
  cancellation propagates. Revisit after item 10.

## Out of scope

- Sign in with Apple — needs the paid Apple Developer membership; below the
  stop marker, and `signInWithApple` on `SupabaseBackend` still throws.
- Lifting the `#if DEBUG` fence on anonymous sign-in — a launch-day product
  decision about guest accounts; Supabase identity linking keeps it reversible
  then. Release stays solo + audio this round.
- Online rematch — a new match row and a re-invite; solo keeps its rematch,
  online results offer Main Menu only.
- Sound asset files — none exist in the bundle, so every cue is a silent no-op
  until the audio lane's assets land. The call sites are this round's; the
  files are not code.
- Per-sender sequence number on `WireEnvelope` — `FOUNDATION.md`'s open risk,
  `online`'s to schedule; out-of-order moves are a real defect but not shell's.
- Lobbies of more than two — `OnlineMatch.start()` requires exactly two; the
  wire allows six, the façade does not, and widening it is an online item.
- Launch screen (design comp 01) — needs an `Willagrams.xcodeproj` edit,
  Reviewer-only.
- A first-launch name prompt — "Player XXXX" is the anonymous default and is
  editable on the profile screen; one fewer screen before Solo Practice.
- A standalone settings screen — no screen exists to host a mute row, so the
  control is a menu toggle; the results stat table and pool-size pickers stay
  cut per `docs/design/README.md`.
- Push notifications for invites — APNs needs the paid membership; invites
  reach a friend only while their app is open, by design.
- The friends "unfriend" action — `BackendClient` has no call for it; `block`
  is the only removal and adding one is a `/foundation` amendment.

---

- task: |
    Build the app's services once, at the root, and inject them.

    `Willagrams/App/WillagramsApp.swift` constructs one `SupabaseBackend()`
    (its `init` reads the anon key from `Info.plist` via the gitignored
    xcconfig — pass nothing), one `SystemAudioPlayer(muted:)` seeded from
    `AudioSettings(defaults: .standard).isMuted`, and one
    `SettingsStore(defaults: .standard)`, and hands them to `ShellModel` as a
    single `ShellServices` value declared in `Willagrams/Shell/`. `ShellModel`'s
    existing `init` gains the parameter with a default that ShellTests override
    with `FakeBackend`, a recording `AudioPlayer`, and an in-memory
    `UserDefaults(suiteName:)`.

    At launch, in Debug, `ShellModel` signs in with
    `SupabaseBackend.signInAnonymously()` and publishes the resulting `Profile`
    as `currentProfile: Profile?`. Sign-in is a `Task` the model owns and
    cancels on teardown; it never blocks the menu. While `currentProfile` is
    nil the menu's online actions (items 3, 7, 8 will add them) are disabled
    and a one-line reason is published as `onlineUnavailableReason: String?`
    ("Signing in…" while pending, the `BackendError` case name mapped to plain
    copy on failure). Solo Practice and How to Play never wait on it.

    `signInAnonymously` exists only on the concrete `SupabaseBackend` and only
    in Debug. Declare a small `ShellSignIn` protocol in Shell with one
    `signIn() async throws -> Profile` requirement; `SupabaseBackend` conforms
    in an extension inside `#if DEBUG` in Shell, `FakeBackend` conforms in the
    test target. In Release the services value carries no sign-in and
    `currentProfile` stays nil.
  guardrails:
    - Exactly one `SupabaseBackend`, one `SystemAudioPlayer` and one `SettingsStore` exist per process; no screen constructs its own
    - Sign-in failure is a disabled state with a reason, never an alert, never a crash, never a retry loop
    - No `#if DEBUG` around any route or screen — only around the anonymous sign-in conformance itself
    - `Willagrams/Online/**` and `Willagrams/Audio/**` are consumed, not edited, in this item
  done when:
    - `ShellModel` built with a `FakeBackend` publishes a non-nil `currentProfile` after sign-in completes, and one built with a backend whose sign-in throws `.offline` publishes a nil profile and a non-empty `onlineUnavailableReason`
    - `startSoloPractice` succeeds while sign-in is still pending
    - A Release configuration compiles with no reference to `signInAnonymously` anywhere under `Willagrams/`
    - `swift test --package-path Tests/ShellTests` and the iOS `xcodebuild` build pass
  status: done

- task: |
    Let `MatchRun` run a match it did not build.

    `Willagrams/Shell/MatchRun.swift` constructs and owns a `SoloMatch` and
    reads its `session`, `dictionary` and `leave()`. Extract what it reads into
    a `MatchOpponent` protocol in Shell (`session: MatchSession`, `leave()`,
    the human-side `PlayerID`), make `SoloMatch` conform, and give `MatchRun`
    a second initializer that accepts an already-built opponent instead of a
    difficulty. `OnlineMatch` from `Willagrams/Online/OnlineMatch.swift` will
    be adapted to it in item 3 — this item only opens the seam.

    Teardown keeps the order round 2 established: the old opponent is down
    before a new one is built, and `ResultsModel`'s closures capture the
    opponent through the protocol.
  guardrails:
    - `SoloMatch` behavior does not change; `RematchTests` and `MatchRunTests` pass unmodified except for construction
    - `MatchRun` never learns which concrete opponent it holds — no `is`/`as?` on the opponent
    - Nothing under `Willagrams/Bot/**` or `Willagrams/Match/**` is edited
  done when:
    - A `MatchRun` built from a test-double `MatchOpponent` walks countdown → match → results the same way the solo path does, proven by the existing route-transition tests run against the double
    - Rematching three times through the solo path still leaves exactly one live match
    - `swift test --package-path Tests/ShellTests` passes
  status: done

- task: |
    Host a match from the menu and show the invite code.

    Add `AppRoute.hostLobby` and a `HostLobbyModel` in `Willagrams/Shell/`.
    The menu gains a "Play a Friend" action (enabled only when
    `currentProfile` is non-nil) that moves the route there. The model calls
    `OnlineMatch.host(options:backend:dictionary:dictionaryHash:...)` with the
    options `SettingsStore.load()` returns, then publishes `inviteCode`, the
    `lobby` roster as display names resolved through `profile(id:)`, and a
    `canStart` that is true exactly when `lobby.count == 2`. Start calls
    `start()`, wraps the `OnlineMatch` as a `MatchOpponent` (item 2), builds
    the `MatchRun`, and moves to `.countdown` carrying a `MatchSetup` derived
    from the session. Cancel calls `leave()` on the `OnlineMatch`, which
    abandons the row, and returns to the menu.

    `HostLobbyView` shows the code large, a system share sheet button for it,
    the roster, Start and Cancel. Pending states (creating, starting) are
    published on the model, never inferred in the view.
  guardrails:
    - The host is `roster[0]` as `OnlineMatch` elects it; shell never decides who hosts
    - Leaving the lobby always tears the `OnlineMatch` down before the route moves — no live channel survives a cancel
    - `OnlineMatchError` and `BackendError` surface as copy on the lobby screen, never as a crash or a silent return to the menu
    - Add `HostLobbyView.swift` to the `Shell` target's `exclude:` list in `Tests/ShellTests/Package.swift`
  done when:
    - With a `FakeBackend`, "Play a Friend" moves the route to `.hostLobby`, the model publishes a six-character code, and `canStart` flips true only after a second player is present
    - Start on a two-player lobby moves the route to `.countdown` and the resulting `MatchRun` holds a session whose `roster` has two players with the local player as host
    - Cancel from the lobby returns to `.menu` and the fake's match record reads `abandoned`
    - Live, on two simulators: the host's screen shows a code, and after the guest joins the host's roster shows the guest's display name
  after: online
  caution: false
  status: done  # all four criteria met; criterion 4 verified live on two simulators during item 4

- task: |
    Join a match by invite code.

    Add `AppRoute.join` and a `JoinModel` in `Willagrams/Shell/`. The menu's
    "Play a Friend" screen — or a second action beside it; keep it one screen
    with a code field if that reads cleaner — takes a six-character code,
    uppercases and trims it, and calls `OnlineMatch.join(code:backend:...)`.
    On success the model publishes a waiting state ("Waiting for host") with
    the host's display name, then awaits `awaitStart()`, wraps the
    `OnlineMatch` as a `MatchOpponent`, builds the `MatchRun`, and moves to
    `.countdown`. A wrong code (`BackendError.notFound`), a full or started
    match (`.matchFull`, `.permissionDenied`) and offline each map to a
    one-line message beside the field. Cancel while waiting calls `leave()`
    and returns to the menu.
  guardrails:
    - The code field accepts only `[A-Z0-9]`, length 6, before the join call is made — the backend regex is the last line, not the first
    - `awaitStart()` is cancelled when the player leaves; no orphaned task keeps a channel subscribed after the route moves
    - Add `JoinView.swift` to the `Shell` target's `exclude:` list
  done when:
    - With a `FakeBackend` holding a lobby, entering its code moves the model to the waiting state, and the fake's `match_players` shows the joiner
    - A code that matches no match publishes a not-found message and the route stays put
    - When the fake host starts, the guest's route moves to `.countdown` with a `MatchRun` whose session names the host as `roster[0]` and the local player as guest
    - Live, on two simulators: the guest enters the host's code and reaches the match screen when the host presses Start
  after: online
  caution: false
  status: done

- task: |
    Show reconnecting, end on gone, and give online results a way home.

    `MatchHUDModel` already reads `session.peerPresence` to gate Draw and win.
    Add a published `overlay: MatchOverlay?` on the match-side model (`.reconnecting(name)` while any peer's `presence(of:)` is `.reconnecting`, nil otherwise) and a `ReconnectingOverlay` view in `MatchView` that dims the board and names the peer, matching design comp 10's intent (`docs/design/README.md`) without new data. Input is locked while the overlay shows — `BoardView` already takes `inputLocked`. When `session.isMatchOver` becomes true because a peer went `.gone`, `endWhenTheMatchDoes` (already armed in `ShellModel`) carries the route to results as it does for a win; `ResultsModel` names the outcome ("Opponent left") rather than a winner when `state.winner` is nil.

    For an online opponent `ResultsModel` offers Main Menu only: the rematch
    action is absent, not disabled. Solo results are unchanged.
  guardrails:
    - No state is added to `MatchSession`; presence is read, never stored again in Shell
    - The overlay never appears in a solo match — `BotMatch`'s peer is never `.reconnecting`
    - The outcome recorder attached by `OnlineMatch` is not touched; results reads what the session already finished with
  done when:
    - With a test-double session reporting a peer `.reconnecting`, the model publishes the overlay and `inputLocked` is true; when the peer returns `.present` both clear
    - With the peer `.gone`, the route moves to `.results` and the results model's headline names a departed opponent, not a winner
    - `ResultsModel` built for an online opponent exposes no rematch action; built for solo it still does
    - `swift test --package-path Tests/ShellTests` and the iOS `xcodebuild` build pass
  status: done  # all four criteria met; overlay lives on MatchBoard (MatchHUDModel carries a fence banning peerPlayerID)

- task: |
    Present the settings lane's options view and persist the choice.

    `Willagrams/Shell/SoloSetupView.swift` hand-rolls Toggle and Stepper rows
    for the same options `Willagrams/Settings/Views/MatchOptionsView.swift`
    renders from a `MatchOptionsForm` binding, and
    `Willagrams/Settings/Model/SettingsStore.swift` (`load()`, `save(_:)`) has
    no caller in the app. `SoloSetup` holds a `MatchOptionsForm` loaded from
    the injected `SettingsStore` on entry and saved on Start; `SoloSetupView`
    embeds `MatchOptionsView(form:)` in place of its own rows. The difficulty
    choice stays shell's. `HostLobbyModel` (item 3) reads the same store, so a
    host's rules are the ones last chosen for solo.
  guardrails:
    - `Willagrams/Settings/**` is consumed, not edited — the form and the view are used as they ship
    - The bot difficulty control remains shell's own list from `BotDifficultyMenu.choices`; no second options UI exists under `Willagrams/Shell/**`
    - `MatchOptions.validated` still runs on whatever the form produces before it reaches a match
  done when:
    - Changing an option in solo setup, starting, and rebuilding `ShellModel` on the same `UserDefaults` suite loads the changed option
    - The `MatchSetup` handed to `.countdown` from solo setup carries the form's options, and item 3's lobby creates its match with the same options
    - No Toggle or Stepper over a match option remains under `Willagrams/Shell/**`
    - `swift test --package-path Tests/ShellTests` and the iOS `xcodebuild` build pass
  after: settings
  status: done

- task: |
    The profile screen.

    Create `Willagrams/Account/` with `ProfileModel` (observable: the
    `Profile`, an `isEditable` flag, a display-name draft, `save()` through
    `updateDisplayName`, the four stats as labelled rows via `StatRow` from
    Style, the friend code with copy and share actions) and `ProfileView`.
    Create `Tests/AccountTests/` as its own SwiftPM package on the OnlineTests
    layout (symlinks to Account, Online and Match; excludes the View; carries a
    `SourceGuardrailTests` on the ShellTests pattern). Shell adds
    `AppRoute.profile` and a menu action "Profile", enabled when
    `currentProfile` is non-nil, rendering `ProfileView` for the local player
    with editing on. The route returns to the menu.

    The name field clamps to 1–24 characters client-side, matching the column
    check, before `updateDisplayName` is called.
  guardrails:
    - `Willagrams/Account/**` holds no navigation — shell owns the route; the screen reports back through closures
    - No stat is computed client-side; every number is the `Profile` row as read
    - The screen renders for any `Profile`, not only the local one — item 9 reuses it read-only
    - Add `ProfileView.swift` to the new package's `exclude:` list and register the package's literal `swift test` command in this file's Global rules when it exists
  done when:
    - `ProfileModel` on a `FakeBackend` saves a new name and re-reads it; a 25-character draft is refused before any call is made
    - The menu's Profile action moves the route to `.profile` and back
    - `swift test --package-path Tests/AccountTests` exists and passes, and the iOS `xcodebuild` build passes
  status: done
  parallel-group: a

- task: |
    The friends list.

    Create `Willagrams/Friends/` with `FriendsModel` (observable: loads
    `friendships()`, resolves each counterpart's `Profile` through
    `profile(id:)`, and publishes three sections — accepted, incoming pending,
    outgoing pending; `accept(_:)` and `decline(_:)` call
    `respondToFriendRequest(requesterID:accept:)`, `block(_:)` calls `block`)
    and `FriendsView`. Create `Tests/FriendsTests/` on the same package layout
    as item 7. Shell adds `AppRoute.friends` and a menu action "Friends",
    enabled when `currentProfile` is non-nil. Blocked players are hidden from
    every section.

    Live-gated cases in FriendsTests create two anonymous users through
    `SupabaseBackend.signInAnonymously()` on two backends, run request →
    accept → list on each side, and assert both lists show the other. This is
    the RLS proof; the `FakeBackend` cases cover the model's sectioning only.
  guardrails:
    - Friends is tested against the real database — a run with the live gate skipped does not satisfy this item
    - The model never writes to `friendships` except through the three seam calls; no client-side status arithmetic
    - `rls_behavior.sql` is not edited by this item — a policy the live case shows to be wrong is a `/foundation` amendment, reported not fixed
    - Add `FriendsView.swift` to the new package's `exclude:` list
  done when:
    - On a `FakeBackend` seeded with one accepted, one incoming and one outgoing friendship, the model publishes each in its own section, and accepting the incoming one moves it to accepted
    - Live: two fresh anonymous users request and accept, and each side's `FriendsModel` lists the other as accepted; a blocked user appears in neither list
    - `swift test --package-path Tests/FriendsTests` passes with `WILLAGRAMS_LIVE_TESTS=1`, and the iOS `xcodebuild` build passes
  caution: true
  status: done
  parallel-group: a

- task: |
    Add a friend by code, and open a friend's profile.

    `FriendsModel` gains `lookup(code:)` → `profile(friendCode:)` and
    `request(_:)` → `requestFriend(addresseeID:)`; `FriendsView` gains a code
    field with the same `[A-Z0-9]{8}` client-side clamp the backend enforces
    and a result row with a Request button. `.alreadyExists` and `.blocked`
    map to one-line copy. Tapping an accepted friend moves shell's route to
    `.profile` for that player with `isEditable` false, reusing item 7's
    screen unchanged; Back returns to the friends list, not the menu.
  guardrails:
    - A player cannot request themself — the model refuses its own code before any call
    - `ProfileView` is reused, never copied, for the read-only case
    - Add no new View file without its `exclude:` entry
  done when:
    - On a `FakeBackend` with a seeded profile, looking up its code publishes that profile, and requesting it creates a pending outgoing friendship in the list
    - Looking up the local player's own code publishes a refusal and makes no backend call
    - Tapping an accepted friend moves the route to a read-only profile whose stats are that friend's row, and Back returns to `.friends`
  status: done

- task: |
    Invite a friend to play, in-app.

    Add a per-user invite channel to `Willagrams/Online/`: `MatchInviteChannel`
    subscribes to a Realtime broadcast channel named for the local user id at
    sign-in and publishes an `AsyncStream<MatchInvite>` (`matchID`,
    `inviteCode`, `hostID`, `hostName`, `sentAt`); `send(_:to:)` broadcasts to
    the recipient's channel. Model it on `SupabaseMatchChannel` and its stub,
    including the frame-under-`payload` decode the first live run had to fix.
    Extend `FakeBackend`'s transport factory pattern with an in-memory invite
    bus so the offline suite can run two users.

    Shell: an accepted friend row gains "Invite to play". Tapping it runs item
    3's host flow and, once the code exists, sends the invite. The recipient's
    `ShellModel` consumes the stream from item 1's services: an invite arriving
    on the menu, friends, profile or join screens publishes a banner ("<name>
    wants to play") with Join, which runs item 4's join with that code;
    arriving during a match or a lobby it is dropped. A banner older than two
    minutes, or whose join fails with `.notFound` / `.permissionDenied`, clears
    with a one-line "That game is over".
  guardrails:
    - No migration — invites are broadcast only, never stored; `supabase/migrations/**` stays untouched
    - `Willagrams/Online/BackendContracts.swift` is `protected:` — the invite channel is a new type beside the seam, not a change to it
    - Only accepted friends can be invited; the send button never renders on a pending row
    - A double tap sends at most one invite for one lobby; the recipient shows at most one banner per `matchID`
    - The subscription is torn down on sign-out and on `ShellModel` teardown; no channel outlives the model
  done when:
    - Offline, two `ShellModel`s on the fake bus: inviting from A publishes exactly one banner on B naming A; B's Join moves B to item 4's waiting state on A's code; a second tap on A adds no second banner
    - An invite arriving while B is on `.match` publishes nothing; one arriving with `sentAt` older than two minutes publishes nothing
    - Joining a banner whose lobby was cancelled clears it with the "over" message and B stays on the menu
    - Live, on two simulators signed in as friends: A taps Invite, B's banner appears within five seconds, B joins, A starts, and both reach the match screen
  after: online
  caution: true
  status: done  # criteria 1-3 met and the transport is live-proven; criterion 4 (two-simulator tap-through) is UNRUN — no XCUITest target exists and simctl has no tap primitive, so it is a manual check a human owes before ship

- task: |
    Give every sound cue a call site.

    All nine `SoundEffect` cases through item 1's injected player, from the
    model that owns each moment: `countdownTick` per second in
    `CountdownOverlay`; `draw` and `swap` on a granted request in
    `MatchHUDModel`; `invalid` where `refuse()` counts a refused Draw or win;
    `win` and `loss` when `ResultsModel` resolves the outcome; `menuTap` from
    each `ShellModel` menu transition (`showSoloSetup`, `showHowToPlay`, and
    the actions items 3, 7, 8 added); `tilePlace` and `tileRecall` from
    `MatchBoard`'s commit bridge, which is the one place shell sees a tile
    land on or leave the table. Haptics stay where they are —
    `BoardHaptics` fires directly and `AudioPlayer.impact` is not called for
    tiles; call `impact(.medium)` on `win` only.
  guardrails:
    - Cues are played from models and the commit bridge, never from a View body or `onChange` — the test for each is the recording player in ShellTests
    - `Willagrams/Board/**` and `Willagrams/Audio/**` are not edited; the bridge in `Willagrams/Shell/MatchBoard.swift` is the seam
    - A drag that does not commit plays nothing; a swap plays `swap`, never `tileRecall` plus `draw`
    - Never introduce a `Task` or `await` around a cue
  done when:
    - With a recording `AudioPlayer`, a solo match that deals, places one tile, draws once, recalls one tile and wins records exactly `tilePlace`, `draw`, `tileRecall`, `win` for those moments in that order, with `countdownTick` once per countdown second before them
    - A refused Draw records `invalid` and no `draw`; a swap records one `swap`
    - Each menu action records one `menuTap`
    - `swift test --package-path Tests/ShellTests` and the iOS `xcodebuild` build pass
  after: audio
  status: done

- task: |
    The mute control.

    A speaker toggle on the menu, in `MenuView`, bound to a published
    `isMuted` on `ShellModel` that reads `AudioSettings.isMuted` at init and
    on change calls both `AudioSettings.setMuted(_:)` and the injected
    player's `setMuted(_:)`. Label it from a local constant per the chrome
    rule; VoiceOver reads "Sound on" / "Sound off".
  guardrails:
    - Mute is sound only; haptics are not touched, per MAP's "Decided" section on audio
    - The two writes (settings and player) happen together — no path sets one without the other
  done when:
    - Toggling mute, then rebuilding `ShellModel` on the same `UserDefaults` suite, publishes `isMuted == true` and the freshly injected player was constructed muted
    - With the recording player, toggling mute calls `setMuted(true)` on it, and `menuTap` is still recorded while muted (the player, not the model, decides silence)
  after: audio
  status: done

> **⚠️ AUTONOMOUS RUN — STOP HERE**

> The item below waits on the paid Apple Developer membership. Nothing under
> the marker runs unattended; resume once `com.apple.developer.applesignin`
> is in `Willagrams.entitlements` (a Reviewer edit) and `online` has
> implemented `signInWithApple`.

- task: |
    Sign in with Apple.

    A sign-in screen in `Willagrams/Account/` that runs
    `ASAuthorizationAppleIDProvider` with a hashed nonce and calls
    `signInWithApple(idToken:nonce:)`; shell routes to it when no session
    exists in Release and links an existing anonymous identity in Debug.
  guardrails:
    - Never ship a Release build that can create an anonymous session
    - The nonce is generated per attempt and never logged
  done when:
    - A Release build with no session shows the sign-in screen first and reaches the menu after a successful sign-in
    - Signing in on a device that previously played anonymously keeps its profile row
  status: not started
