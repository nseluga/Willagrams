# Willagrams — final lane

## Objective

Willagrams feels finished on an iPhone: it opens on a loading animation into a portrait Home, every non-game screen matches the final comp in portrait, a match turns landscape, playing a friend is one screen with its own match settings, a fast drag never flies home onto a free cell, and a resign win never sets the fastest-win record.

Lane done when:
- On an iPhone 13 mini (or SE 3rd gen) Simulator, a cold `xcrun simctl launch` screenshotted at ~1s shows the loading wordmark in portrait, and at ~10s shows Home in portrait with no "shared Pool" line, a disabled Multiplayer button and no Join button. On an iPad Simulator the same launch lands on a landscape Home. All screenshots attached to the run summary.
- Every package suite is green run serially, no count below its floor, and `xcodebuild` reports BUILD SUCCEEDED on the merged branch.
- `supabase/migrations/0006_fastest_win_skips_null.sql` exists, is NOT applied to the live project, and the run summary tells Nate to push it before installing this build on a device that plays online.

Status: cut 2026-09-15 from `lane/polish` @ `c1f038b` (polish 14/14 done, not yet merged to `integration`). Plan: `~/.claude/plans/willagrams-final-scalable-crescent.md`. Nate's decisions: iPad stays landscape everywhere; the drag symptom is "tile follows the finger, then flies back home on release"; restyle all six comp screens while keeping every feature the comp omits; reset every `fastest_win_seconds` to null.

Lane: final — The final-adjustments pass after the polish hand test — iPhone portrait outside gameplay, a looping loading screen, Home without the Join button or the shared-pool line, one Play/Join a Friend screen with match settings, restyled Profile/Friends/How to Play, the fast-drag fly-home fix, and resign wins skipping fastest win.

Owned — this lane's items live inside these paths:
  none of its own (a pass, like `polish`), plus two scoped grants from MAP.md "Tuning":
  Willagrams.xcodeproj/project.pbxproj — ONLY the `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` value (items 3) and the launch-screen background colour (item 8)
  supabase/migrations/0006_fastest_win_skips_null.sql — new file only (item 2)

Open — merged lanes. Wiring items may edit these; rebase onto `integration` first:
  Willagrams/Style/**, Willagrams/Resources/Branding/**, Willagrams/Assets.xcassets/**, Tests/StyleTests/**, docs/ip-review.md
  Willagrams/Board/**, Tests/BoardTests/**
  Willagrams/Match/**, Tests/MatchTests/**
  Willagrams/Settings/**, Tests/SettingsTests/**
  Willagrams/Shell/**, Willagrams/App/**, Tests/ShellTests/**
  Willagrams/Online/**, Tests/OnlineTests/**, supabase/** (except supabase/migrations/**, protected — 0006 above is the one grant)
  Willagrams/Account/**, Tests/AccountTests/**
  Willagrams/Friends/**, Tests/FriendsTests/**
  Willagrams/Bot/**, Tests/BotTests/**
  Willagrams/Audio/**, Tests/AudioTests/**

Stop and report if an item requires changing a path outside both lists:
  protected — Sources/WillagramsRules/** (Contracts, BoardAnalysis, Pool, GameState, MatchMessage, MatchOptions, WordList, Resources/dictionary.txt), Tests/WillagramsRulesTests/**, Willagrams/Match/MatchTransport.swift, Willagrams/Style/DesignTokens.swift (key names — values may change and keys may be added), Willagrams/Style/Terminology.swift, Willagrams.entitlements, Package.swift, supabase/migrations/** (except the new 0006), Willagrams/Online/BackendContracts.swift, Willagrams/Audio/AudioPlayer.swift
  an unmerged lane's — fastlane/**, docs/store/** (launch)
  unowned — repo root files, .claude/**, docs/*.md, progress/**, Willagrams.xcodeproj/** (except the two pbxproj edits above)

Frozen contracts — build and test against these; they will not move:
  Sources/WillagramsRules/MatchMessage.swift + Tests/WillagramsRulesTests/Fixtures/wire-v4.json — `.start` already carries hand size and `MatchOptions`; no wire change this round
  Willagrams/Match/MatchTransport.swift
  Willagrams/Online/BackendContracts.swift — a new backend call goes on a side protocol, as `Willagrams/Online/FriendRequestForgetting.swift` does
  Willagrams/Style/DesignTokens.swift key names

## Global rules

- **Tests.** Run each package serially on an idle machine, never while `xcodebuild` is running (a parallel run produced 22+ spurious timeouts):
  `swift test` (rules 53) · `swift test --package-path Tests/BoardTests` (265) · `Tests/MatchTests` (128) · `Tests/StyleTests` (31) · `Tests/ShellTests` (227) · `Tests/SettingsTests` (36) · `Tests/BotTests` (68, ~5 min) · `Tests/OnlineTests` (142, 1 known issue, live cases skip without a key) · `Tests/AudioTests` (19) · `Tests/AccountTests` (15) · `Tests/FriendsTests` (49).
  **These counts are floors.** A count may only go up. Never delete a passing test to hold a number; a test pinning behaviour this round changes is rewritten to the new rule, not deleted.
- **Stale builds lie.** After changing any type in `Sources/WillagramsRules` or `Willagrams/Match`, run `swift package --package-path Tests/<pkg> clean` before trusting a red.
- **Views are not compiled by `swift test`.** After any SwiftUI or project edit, run `xcodebuild -project Willagrams.xcodeproj -scheme Willagrams -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/willagrams-dd-final build`. The item isn't done until it says BUILD SUCCEEDED.
- **Nested-package symlinks.** `Tests/ShellTests/BoardSrc` and `Tests/ShellTests/StyleSrc` are directories of per-file symlinks. A new file under `Willagrams/Board/` or `Willagrams/Style/` stays invisible to ShellTests until it is symlinked there. Every other `*Src` is a directory symlink. The app target uses file-system synchronized groups, so a new source file needs no project-file entry.
- **Size decisions live in plain structs** (not `View`s), so ShellTests/StyleTests can assert on them. Landscape phone stays `verticalSizeClass == .compact`; portrait phone is `horizontalSizeClass == .compact` with a regular vertical class. **One exception to "no idiom checks":** the orientation lock in `Willagrams/App/` may read the idiom, because iPad must stay landscape while iPhone rotates, and no size class distinguishes them at launch. Nowhere else.
- **`MatchSession` is at a Swift 6.3.3 toolchain limit.** One more *observed* stored property aborts MatchTests with `swift_task_dealloc`. New storage is `@ObservationIgnored`. Run MatchTests after every edit to that file.
- **Never touch the live backend.** No `supabase db push`, no `supabase link`, and no Supabase MCP `execute_sql`/`apply_migration` against any project. `0006` is written and tested offline; Nate pushes it. Gated live OnlineTests may run with `WILLAGRAMS_LIVE_TESTS=1` only for cases that do not depend on 0006. Never print or commit `.env` or `Config/Secrets.local.xcconfig`.
- **Behavioral checks.** The Simulator can be booted, launched (`xcrun simctl launch`), rotated only by the app itself, and screenshotted (`xcrun simctl io booted screenshot`), but nothing can tap it (AXe cannot drive this Xcode). A screen reachable only by tapping is Nate's hand test: name it in the run summary with what to look at, and never claim it verified.
- **The comp.** `docs/design/willagrams-final.dc.html` is the visual truth for Home, Loading, Play/Join, Profile, Friends and How to Play: layout, type, colour, spacing, radii, copy. The repo is the truth for behaviour, and **this LANE.md wins over the comp** where they disagree (the comp still shows the shared-Pool line and a separate Join button — both go). Map comp values onto existing `DesignTokens` keys; add a key only when none fits. The comp's Replay button and the loading footer line are mock-only — do not build them.
- Player-facing game vocabulary comes from `Terminology.swift` (protected). No new game term may be inlined. Menu labels ("Solo Practice", "Play a Friend", "Multiplayer", "Coming soon") are screen copy, not game terms; they live beside the existing `title` constants in the Shell models.
- Context: `MAP.md` (lanes, the 2026-09-15 amendment, the toolchain note), `docs/design/README.md`, the plan file above.

## Out of scope

- Real Multiplayer (three or more players, matchmaking). Home gets a disabled placeholder only.
- iPad portrait and iPad multitasking. Nate: iPad stays landscape.
- Applying `0006` to the live project. Nate runs `supabase db push` from his terminal; his account is passkey-only and the CLI cannot log in from an agent shell.
- A blocked player can delete their own block row (`friendships_delete_own`). Still a separate `/foundation`.
- Sign in with Apple and the `launch` lane. Both wait on the paid Apple Developer membership.

---

- task: Stop a fast drag from flying home. Nate's symptom — the tile follows the finger, then flies back to its origin on release — means `TileDrag.landing` (`Willagrams/Board/BoardDrag.swift` ~142–240) refused the drop; the only live refusals are an occupied target (~line 220) and bad geometry. Prime cause, to be proven by a failing test first: the held tile is DRAWN lifted by `DesignTokens.Motion.tileLift` (-8pt, `DesignTokens.swift` ~173) but `landing` measures the drop from the un-lifted centre (~178–184). At the zoomed-out cell sizes a phone uses (16–24pt, so half a cell is 8–12pt) the cell the eye aims at resolves one row low, usually onto an occupied cell, and is refused. Confirm in `BoardView` that the lift is really applied to the dragged tile's drawn position (and in which direction and units) before building on it. Fix in two parts. (1) Measure from the lifted centre: `drop`/`landed`/`landing` take a `lift: CGFloat` (default 0, so the ~100 existing call sites compile), and `BoardView`/`BoardModel.commit` pass `DesignTokens.Motion.tileLift` — the same value the renderer draws with, never a second literal. (2) One-cell forgiveness for single-tile drags: when the target is occupied, land on the free cell within one cell (8-neighbourhood) whose centre is nearest the release point; refuse only when none is free. Group drags keep all-or-nothing. While here, delete the dead `threshold` parameter only if doing so is mechanical; otherwise leave the ponytail comment.
  guardrails:
    - A group drag lands only if every target cell is free; forgiveness never applies to a group
    - A release with no free cell within one cell of its target still returns the tile to its origin with the `.reject` haptic, and the board value is untouched
    - No change to how a drag starts (hit-testing, long-press, pan disambiguation) or to pinch
    - `BoardDrag.swift` stays host-compilable (no SwiftUI/UIKit import); the lift is injected, not read from `DesignTokens`
  done when:
    - The item report states whether the lift hypothesis held, citing the `BoardView` line that applies the lift and the test that failed before the fix
    - A BoardTests case, run at cell sizes 16, 24 and 48: a single-tile drag whose translation puts the tile's LIFTED drawn centre inside empty cell X lands in X, including when the cell directly below X is occupied. It fails with the lift removed from `landing` (mutation-checked)
    - A BoardTests case: a single tile released onto an occupied cell with one free neighbour lands on that neighbour; with all eight neighbours occupied it returns to its origin and fires `.reject`; a two-tile group released partly onto an occupied cell is refused whole. Each fails with its rule removed (mutation-checked)
    - BoardTests and ShellTests remain green at or above their floors; any existing case pinning "occupied → origin" for a single tile is rewritten to the forgiveness rule, not deleted
  caution: true
  parallel-group: a
  status: not started

- task: Resign wins stop counting toward fastest win. Today `MatchOutcomeRecorder` (`Willagrams/Online/MatchOutcomeRecorder.swift` ~250) sends `elapsedSeconds` for any win, and SQL `record_outcome` (`supabase/migrations/0004_record_outcome.sql`) folds it into `fastest_win_seconds`. Write `supabase/migrations/0006_fastest_win_skips_null.sql`: `create or replace function public.record_outcome(won boolean, tiles integer, elapsed_seconds integer)` — same signature, same `security definer` and `search_path`, same grants re-stated as 0004 has them — whose update sets `fastest_win_seconds = case when won and elapsed_seconds is not null then least(fastest_win_seconds, greatest(1, elapsed_seconds)) else fastest_win_seconds end`; then `update public.profiles set fastest_win_seconds = null;`. Note that under 0004, `greatest(1, null)` is 1, so a build that sends null before 0006 is applied would record a 1-second win — say so in the migration's header comment. Swift: `recordOutcome(..., elapsedSeconds: Int?)` on `MatchOutcomeStore` (a Willagrams/Online protocol — confirm it is not in `BackendContracts.swift`; if it is, stop and report); the recorder passes nil when the match did not end by the winner's own win claim (`MatchSession.winningPlacements == nil` — verify every `finish(winner:placements:)` caller in `MatchSession.swift` to confirm nil means exactly resign/abandon); `ProfileStats` mirrors it (nil → fastest unchanged); `SupabaseBackend+Outcome.swift` encodes an explicit JSON `null` for the key (a missing key would fail the RPC, which has no default); `FakeBackend` and every test double follow. Extend `supabase/tests/rls_behavior.sql` with a null-elapsed case; run it on a throwaway database via `scripts/scratch-verify.sh` if that works on this machine, else report it unrun.
  guardrails:
    - No applied migration (0001–0005) is edited; 0006 is additive and re-creates the function with an identical signature
    - Nothing is applied to the live project — no `supabase db push`, no MCP SQL
    - A win by the winner's own claim still records its elapsed time exactly as today; played/won/tiles counters are unchanged for every outcome
    - `BackendContracts.swift` does not move
  done when:
    - An OnlineTests case: a match the local player wins because the opponent resigned leaves `fastestWinSeconds` unchanged (nil stays nil, 42 stays 42) while played and won each go up by 1. It fails if the recorder's nil-for-resign branch is removed (mutation-checked). The existing resign case that expected 7 (`MatchOutcomeRecorderTests` ~162–172) is rewritten to this rule
    - An OnlineTests case: a win by claim in 30s still sets `fastestWinSeconds` to 30 from nil and to 30 from 42
    - An OnlineTests case on the Supabase RPC params encoding: nil elapsed produces JSON containing `"elapsed_seconds":null` (key present), 30 produces `"elapsed_seconds":30`
    - `0006` exists with the header warning; the run summary quotes `scratch-verify.sh`'s result or states it did not run and why
  caution: true
  parallel-group: a
  status: not started

- task: iPhone plays portrait everywhere except the game. Add `AppRoute.isGameplay` (`Willagrams/Shell/AppRoute.swift`): true for `.countdown`, `.match`, `.results`, false for every other route. Add `Willagrams/App/OrientationLock.swift`: a `UIApplicationDelegate` adopted via `@UIApplicationDelegateAdaptor` in `WillagramsApp.swift`, whose `application(_:supportedInterfaceOrientationsFor:)` returns a static mask. A plain `OrientationPolicy.mask(isGameplay:isPad:) -> UIInterfaceOrientationMask` decides it: iPad → `.landscape` always; iPhone → `.landscape` in gameplay, `.portrait` otherwise. `ShellRootView` (`Willagrams/Shell/ShellRootView.swift`) observes `route.isGameplay` with `.onChange(of:initial: true)`, sets the mask, calls `setNeedsUpdateOfSupportedInterfaceOrientations()` on the key window's root view controller, and `windowScene.requestGeometryUpdate(.iOS(interfaceOrientations:))`. In `project.pbxproj` change only `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` (Debug and Release, ~lines 208/235) to add `UIInterfaceOrientationPortrait`; the iPad key is untouched. The app keeps its pure SwiftUI `App` lifecycle — the adaptor is the only delegate, and it does nothing else.
  guardrails:
    - iPad orientation behaviour is unchanged: landscape left/right on every route
    - No navigation container is introduced (ShellTests' guardrail stays green); routing is untouched
    - The only pbxproj change is the iPhone orientation key's value; no other project setting moves
  done when:
    - A ShellTests case: `isGameplay` is true exactly for countdown, match and results (every `AppRoute` case enumerated, so a new case forces a decision), and `OrientationPolicy.mask` returns `.portrait` for (false, iPhone), `.landscape` for (true, iPhone), `.landscape` for iPad either way. Mutation-checked
    - `xcodebuild` BUILD SUCCEEDED; a cold launch on an iPhone 13 mini Simulator screenshots portrait (image height > width) and on an iPad Simulator landscape; both attached
    - "start solo practice — the countdown turns landscape; finish or resign — Home returns to portrait" is named as Nate's hand test
  caution: true
  ui: true
  parallel-group: a
  status: not started

- task: Tighter margins on a portrait phone. `.screenPadding()` (`Willagrams/Style/DesignTokens.swift` ~199–218) picks 12 when `verticalSizeClass == .compact`, else 40, so a portrait phone (vertical regular) gets 40 on every screen. Add `Space.screenMarginPhone = 16` (new key; no rename) and choose through a plain function `ScreenMargin.value(horizontal:vertical:)`: vertical compact → `screenMarginCompact` (12), horizontal compact → `screenMarginPhone` (16), else `screenMargin` (40). `.screenPadding()` reads both size classes and calls it. One change covers every screen that already uses `.screenPadding()`.
  guardrails:
    - No existing DesignTokens key is renamed or removed; StyleTests' token guardrails stay green
    - iPad (regular/regular) keeps 40; landscape phone keeps 12
  done when:
    - A StyleTests case: `ScreenMargin.value` returns 16 for (compact, regular), 12 for (compact, compact) and (regular, compact), 40 for (regular, regular); and `screenMarginCompact < screenMarginPhone < screenMargin`
    - `xcodebuild` BUILD SUCCEEDED
  ui: true
  status: not started

- task: Home, rebuilt from comp screen 01 plus Nate's list. `Willagrams/Shell/MenuView.swift` + `MenuLayout.swift`. On a portrait phone: a single column — mute control top-right, the `WordmarkTiles` crossword near the top sized from the available width, a flexible gap, then the PLAY mono label and the buttons anchored to the bottom. **No tagline**: delete the `"One shared \(Terminology.pool)…"` string (~249–250) and its render site (~127–131). Button slots, in order: **Multiplayer** — primary style, disabled, with a small "Coming soon" caption; **Play a Friend** — primary, opens the merged screen (item 6) via the existing `shell.playAFriend()`; then the quiet two-column grid **Solo Practice · Profile · Friends · How to Play**. Solo Practice moves into the grid slot Join used to hold and keeps its action. Join a Friend leaves Home (it is reached from the Play a Friend screen, item 6). Put the slot list in a plain value (e.g. `MenuLayout.actions`) that ShellTests can read. `MenuLayout` gains a portrait mode (width < height); the iPad landscape two-column layout keeps its structure with the same slot changes. `onlineUnavailableReason`'s caption stays under the online buttons. Fix the stale doc comment (~3–14).
  guardrails:
    - iPad keeps its landscape two-column structure; only the slot contents change there
    - The Menu still scrolls under the largest accessibility Dynamic Type sizes rather than clipping (`ViewThatFits` fallback stays)
    - Every action Home had still reaches its screen — Join through the Play a Friend screen — nothing is orphaned
  done when:
    - A ShellTests case: the menu's action list is exactly [Multiplayer (disabled), Play a Friend, Solo Practice, Profile, Friends, How to Play] in that order, with no Join entry; and `MenuLayout(size: CGSize(width: 375, height: 812))` reports portrait mode with a total content height that fits 812 minus portrait safe-area insets
    - No Swift file under `Willagrams/` contains "One shared" (grep), and the Multiplayer button is disabled in the view (a ShellTests case on the slot's `isEnabled`)
    - `xcodebuild` BUILD SUCCEEDED; an iPhone 13 mini Simulator launch screenshot shows the portrait Home with every slot and no scroll indicator; attached
  ui: true
  status: not started

- task: One Play / Join a Friend screen, from comp screen 03. New `Willagrams/Shell/TwoPlayerView.swift` renders both `.hostLobby` and `.join` (ShellRootView points both routes at it with a mode). Layout: top bar Cancel · "TWO PLAYER" mono label · a trailing slot (the gear from item 7 — leave a same-width spacer here); hero title "Play a Friend" / "Join a Friend" (the models' existing `title` constants) and subtitle "Share the code below. One friend, one seat." / "Enter the code from your friend’s screen."; "Host a game" / "Join a game" chips; the six-character code as six tiles (host: the invite code, last tile accent; join: the typed characters, empty slots dashed); join mode's text field "Type the six characters"; host mode's Copy/Share row and roster rows (a seated player "Ready", a dashed "Open seat — Waiting for your friend to join."); one bottom primary button, Start (host) or Join (join, styled disabled until six characters). Chips call `shell.playAFriend()` / `shell.showJoin()`, which already tear down the other model. `joinInvite()` and `invitePlay()` still land in the right mode. Move the polish work across intact: join's `@FocusState` + `scrollTo` on focus + `.scrollDismissesKeyboard(.interactively)`, validation messages reachable (Join disabled only when empty or in flight), host code/roster/Start behaviour from `HostLobbyView`, error/status messages from both models. Then delete `HostLobbyView.swift` and `JoinView.swift`.
  guardrails:
    - No change to `HostLobbyModel`/`JoinModel` online behaviour in this item — lobby creation, joining, Start, cancel and teardown work exactly as today; only who renders them changes
    - Switching chips never leaves two live lobbies: the model being left is torn down (its backend cancel/leave happens) before the other starts
    - Invalid join input still never reaches the backend
  done when:
    - A ShellTests case: from `.hostLobby`, the Join chip's action leaves the route at `.join` and the host model's teardown recorded its backend cancel; from `.join`, the Host chip's action leaves the route at `.hostLobby` and the join model is torn down. Each fails with its teardown removed (mutation-checked)
    - A ShellTests case on a plain value backing the code tiles: host mode yields six filled tiles with the last marked accent; join mode with "AB1" yields three filled and three empty
    - `HostLobbyView.swift` and `JoinView.swift` no longer exist; `xcodebuild` BUILD SUCCEEDED
    - "Play a Friend: switch Host/Join, type a code with the keyboard up, Start with a friend joined" is named as Nate's hand test
  ui: true
  status: not started

- task: Play a Friend gets the solo match settings, minus the CPU. In `TwoPlayerView`'s trailing slot, host mode only, a gear button opens a sheet with `MatchOptionsForm` (`Willagrams/Settings/Model/MatchOptionsForm.swift`, the form solo uses — swap on/off, minimum word length, dictionary) plus the starting-tiles stepper (`SoloSetup.handSizeRange` 5…40, `SoloSetup.handSizeLabel`), seeded from and saved to `SettingsStore`. No bot/difficulty control. The gear is disabled once Start is pressed. `HostLobbyModel` (`Willagrams/Shell/HostLobbyModel.swift`) holds mutable `options` and `handSize`; `start()` (~222) passes them to `OnlineMatch.start(...)` (`Willagrams/Online/OnlineMatch.swift`), which sends them in `.start` in place of the hard-coded `startingHandSize` (~64, used ~394) and `record.options` (~396). The `.start` message already carries both — no wire change. Confirm the guest reads options and hand size only from `.start` (grep every read of `matches.options`/`record.options`); if anything a guest shows before the start reads the row, report it.
  guardrails:
    - No wire, `MatchMessage` or `BackendContracts` change; the dictionary-hash gate at start still refuses a mismatched dictionary
    - Solo practice's settings and its bot controls are unchanged
    - Settings cannot change after Start is pressed; a second `.start` is still ignored
  done when:
    - An OnlineTests (or ShellTests) case over the fake transport: the host sets starting tiles to 10 and swap off, starts, and the guest's session has `startingHandSize == 10`, swap disabled, and both racks hold 10 tiles. It fails with the hard-coded 21 restored (mutation-checked)
    - A ShellTests case: after `start()` the settings action is unavailable, and changed settings persist through `SettingsStore` to the next lobby
    - MatchTests, OnlineTests and ShellTests are green at or above their floors; `xcodebuild` BUILD SUCCEEDED
    - "host sets 10 tiles + swap off via the gear; the guest deals 10 and sees no Swap" is named as Nate's two-device hand test
  caution: true
  ui: true
  status: not started

- task: A loading screen that loops until the app is ready, from comp screen 02. `ShellModel` (`Willagrams/Shell/ShellModel.swift`) gains launch state: `launch()` awaits `signInTask` (capped at 6s — on timeout Home shows its existing signing-in state) and `loadedDictionary()` (~64–77), then marks ready. New `Willagrams/Shell/LaunchView.swift`: the nine wordmark tiles (the `WordmarkTiles` crossword — WILLA across, GRAMS down through the accent A) start scattered and rotated at the comp's per-tile offsets (G 13,-86,18° · R -119,-126,-27° · W -29,36,24° · I 157,-18,-21° · L -25,138,30° · L -195,-178,-31° · A -125,-28,14° · M 11,70,-26° · S -263,32,28°; delays 0/.05/.1/.15/.2/.25/.4(A)/.3/.35s), fly into place with the comp's overshoot, then the whole mark clicks (scale 1→1.04→.99→1), a ring expands from 0.72 to 1.25 at half opacity, and six small squares burst from the accent A — one 4.2s cycle, keyframes as in the comp's `wg-fly`/`wg-click`/`wg-ring`/`wg-spark`. Below it a thin looping bar (1.5s) and the mono caption "Shuffling the Pool" (Pool via `Terminology.pool`). The loop policy lives in a plain testable driver: at the end of every cycle, not ready → replay; ready → this is the final cycle, then transition to Home. Readiness arriving mid-cycle never cuts the animation short. Shown on cold launch only, gated in `ShellRootView`. Reduce Motion → the static wordmark and bar, exiting as soon as ready. Launch background #1A1710 (the comp's ground) through an `Assets.xcassets` colour and the generated launch screen's background colour setting in `project.pbxproj`, so there is no white flash; if the generated launch screen offers no such setting, leave the project file alone and report it.
  guardrails:
    - Sign-in and the dictionary load start exactly when they do today — the loading screen waits on them, it does not delay or re-trigger them
    - Launch can never hang: sign-in failure or timeout still exits the loop to Home
    - Invite deep links arriving during launch still route once Home is up (the invite banner path is untouched)
  done when:
    - ShellTests cases on the loop driver: not ready at a cycle end → replays; ready mid-cycle → exits exactly at that cycle's end and not before; sign-in timing out at 6s → exits at the next cycle end; Reduce Motion + ready → exits immediately. Each mutation-checked
    - `xcodebuild` BUILD SUCCEEDED; an iPhone 13 mini Simulator cold launch screenshotted at ~1s shows the loading tiles in portrait and at ~10s shows Home; both attached
    - "watch a cold launch — tiles come together, click and spark, repeat until ready, finish the cycle, then Home" is named as Nate's hand test
  ui: true
  status: not started

- task: Restyle Profile and Friends from comp screens 04–05, portrait. `Willagrams/Account/ProfileView.swift`: top bar PROFILE label · Done; a card with the accent avatar tile (initial of the display name), the name as an inline field with its Save button, the friend code in mono under it; three stat cards (Played, Won, Tiles placed) **plus the existing Fastest win** (keep it — the comp omits it); a Win rate card with a bar (won ÷ played, shown as a whole percent; hidden or "—" at zero played); a Friend code card with Copy and Share. `Willagrams/Friends/FriendsView.swift`: large "Friends" title · Done; a Your code card with a Share code button; Add a friend with the 8-character lookup field and Look up button and its hint line; the empty state (three tiles spelling ADD over "No friends yet. Share your friend code to add one."); friend rows as tiles with a Play button, **keeping the existing Block and Unfriend actions** and pending requests. Keep the polish work intact: `@FocusState`, `scrollTo` on focus, `.scrollDismissesKeyboard(.interactively)`, `.onSubmit`, reachable validation messages.
  guardrails:
    - No behaviour changes: every action both screens have today still exists and calls the same model method
    - Validation still happens in the models before any backend call; message strings unchanged
  done when:
    - An AccountTests case on a plain win-rate value: 2 won of 3 played → 67; 0 played → no rate; mutation-checked
    - Both views still declare `@FocusState` and `.scrollDismissesKeyboard(.interactively)`, and Friends rows still offer Block and Unfriend (grep)
    - AccountTests and FriendsTests green at or above floors; `xcodebuild` BUILD SUCCEEDED; "Profile and Friends in portrait against the comp" is named as Nate's hand test
  ui: true
  parallel-group: e
  status: not started

- task: How to Play as a pager, from comp screen 06, and Solo setup fitting portrait. `Willagrams/Shell/HowToPlayView.swift`: Back · "N OF M" mono label; one rule per page — accent number tile, large title, body — with dots and Back / Next buttons at the bottom; Next on the last page reads Done and returns to Home. Rule titles and bodies stay verbatim from `Willagrams/Shell/HowToPlay.swift` (M is however many rules it has). Page state lives in a plain `HowToPlayPager` value. `Willagrams/Shell/SoloSetupView.swift`: lay its existing controls out as a single portrait column with the start action anchored at the bottom, using item 4's margins, so it fits a 375×812 phone without clipping.
  guardrails:
    - Rule copy is not edited; `Terminology` titles stay `Terminology` references
    - Solo setup's options and its start behaviour are unchanged
  done when:
    - A ShellTests case: `HowToPlayPager` starts at page 1 of M, Next advances, Back at page 1 stays, the last page's primary label is "Done", and its label reads "1 OF M" in the format the comp shows. Mutation-checked
    - `xcodebuild` BUILD SUCCEEDED; "How to Play paging and Solo setup in portrait" is named as Nate's hand test
  ui: true
  parallel-group: e
  status: not started
