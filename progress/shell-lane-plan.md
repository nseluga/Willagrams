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
