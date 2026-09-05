# shell round 3 — every screen reachable, against the live backend

Round 3 of the `shell` lane, under the MAP grant of 2026-09-03 that folded the
`account` and `friends` areas into it. Run paused after item 1 at the user's
request; items 2–12 are unbuilt.

Items done: 1 of 12. Items blocked: none.

## Harvested team-memory entries

`/merge-lane` appends these to `.claude/dev-team/team-memory.md` in merge order.

## 2026-09-04 15:12 — dev-team-auto — shell r3 item 1: build the app's services once, at the root, and inject them
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer (opus, medium) — auto/shell-r3, 6efd2c609bbadee5a5e79c7b763dd7ad3af716d8
- **What happened:** `ShellServices` (plain struct: optional `BackendClient`, `AudioPlayer`, optional `SettingsStore`, optional `ShellSignIn`) declared in `Willagrams/Shell/`, built once in `WillagramsApp.init()` and passed to a new `services:` parameter on `ShellModel.init`. `ShellModel` owns a `signInTask` cancelled in `deinit`, publishes `currentProfile` and `onlineUnavailableReason`, and never awaits sign-in on the launch path. `ShellSignInSupabase.swift` holds the only `#if DEBUG` in Shell.
- **What worked:** ShellTests grew Online/Audio/Settings WITHOUT adding supabase-swift — the two SDK-free Online files (`BackendContracts.swift`, `FakeBackend.swift`) were added as extra `sources:` of the existing `Match` target (the app compiles Match+Online into one module, so those files carry no `import Match`), and `Audio` excludes `SystemAudioPlayer.swift` (AVFoundation/UIKit), `Settings` excludes both files under `Views/`. ShellTests still runs in ~7s. The two source-scan fence tests are deliberately falsifiable: each asserts the symbols it greps are present somewhere, so a rename turns them red instead of vacuously green — respelling `"SupabaseBackend("`/`"SystemAudioPlayer("` in the scan made `onlyTheRootBuildsServices` go red on exactly that assert. Release fence proved independently by `nm` on the Release binary: all six `signInAnonymously` symbols are `4Auth…` (the SDK's own), zero from the `10Willagrams` module, and no `SupabaseBackend: ShellSignIn` witness table.
- **What failed:** Four existing ShellTests (`ResultsModelTests`, `SoloSetupTests`, `ShellModelTests`, `ShellRootViewTests`) built a `ShellModel` with the real wall-clock `sleepFor` and started a countdown that outlived the test; adding a service to `ShellModel` surfaced it as a hard process abort (signal 6, `swift_task_dealloc`) when `MatchSession.deinit` cancelled the leaked sleep. Fixed by injecting `sleepFor: { _ in }` — construction only, no assertion weakened. This was latent before this item, not caused by it.
- **Remember next run:** (1) `ShellServices` is the injection seam for every later shell item — read `services.backend` / `services.audio` / `services.settings`; never construct one, `ServiceFenceTests.onlyTheRootBuildsServices` scans all of `Willagrams/` and only `WillagramsApp.swift` is exempt. (2) Any new ShellTests case that builds a `ShellModel` and touches a route MUST pass `sleepFor: { _ in }` or the whole test process can abort. (3) `ShellSignInSupabase.swift` is fenced `#if canImport(Auth)` as well as `#if DEBUG`, so ShellTests compiles it empty — the `SupabaseBackend: ShellSignIn` conformance is only compile-checked by `xcodebuild`, so run xcodebuild after touching it. (4) `Tests/ShellTests` deliberately has NO supabase-swift dependency; keep it that way — anything needing the real client belongs in `Tests/OnlineTests`. (5) `nm <Release binary> | grep <symbol> | xcrun swift-demangle` is the cheap, real proof of a Release fence; a source grep alone is not.

## Run-level notes (top-level orchestrator, 2026-09-04)

- Baseline measured on this branch before item 1: root 53, BoardTests 253 (XCTest), MatchTests 125, StyleTests 30, ShellTests 120, SettingsTests 36, OnlineTests 126 (1 `withKnownIssue`), AudioTests 19, BotTests 68 (~202s), iOS `xcodebuild` BUILD SUCCEEDED. **Zero pre-existing failures.**
- **LANE.md's Global rules and README.md both say ShellTests is 125. It is 120.** `@Test` counts are identical on `main`, `integration` and the lane branch, so nothing was lost in a merge — the 125 is stale bookkeeping. Fix it in LANE.md/README rather than hunting five missing tests. (Post-item-1 it is 131.)
- `integration` was ahead of `lane/shell-r3` by the nine sound-effect `.wav` assets only; merged in at `8d92a49` before item 1. **LANE.md's "Out of scope — Sound asset files — none exist in the bundle" is now false**: item 11's cues will be audible, not silent no-ops.
- Items 7, 8 and 9 all carry `parallel-group: a`, but item 9 extends item 8's `FriendsModel` and reuses item 7's `ProfileView` — it cannot build before them. Planned dispatch is 7 ∥ 8, then 9 sequentially. Fix the marker in LANE.md before the next run.

### Item 2 — Let `MatchRun` run a match it did not build (`d116ced`, 1 attempt, engineer-only)

- **Inject the opponent as a closure, not a value.** `ShellModel.startMatch(_:opponent: @MainActor () -> any MatchOpponent)` takes a *builder*. A built value would be constructed before the call is entered, which makes down-before-up teardown unenforceable. With the closure, `startMatch` leaves the previous opponent first and only then calls the builder — and a test can prove the ordering.
- **A recording test-double is the only check that sees teardown *ordering*.** A double logging `build` / `leave` into a shared array caught it; the weak-reference alive-count check in `RematchTests` cannot — it only proves how many live, never in what order they died.
- **Keeping `MatchRun.match` as `public private(set) var match: SoloMatch!`** let `RematchTests`, `MatchRunTests`, `SoloMatchTests`, `SoloSetupTests` and `ShellModelTests` pass with **zero** edits. The split was a designated opponent-taking init plus a solo convenience init, so the solo call sites never changed.
- **Caveat for items 3 and 5:** `MatchRun.match` is set only by the solo init — reading it on an online run traps by design. Route through `run.opponent` / `run.session` only. Nothing in `Willagrams/` currently reads it.
- **Fast loop:** ShellTests runs in ~10s; `--filter MatchOpponentTests` is ~1s.
- **Counts:** ShellTests 131→135, root 53, MatchTests 125, `xcodebuild` BUILD SUCCEEDED.
- **Mutation checks (4, all restored byte-identical, tree verified against `d116ced`):** opponent built before `returnToMenu()` → the ordering test went red; `leave()` dropped from `endSoloPractice` → 13 named cases across `QAMatchRunTests`/`RematchTests`/`MatchRunTests` went red on `session.isMatchOver` (liveness is genuinely observed); `opponent.leave()` → `(opponent as? SoloMatch)?.leave()` → the source scan went red on both its presence assertion and its cast fence; `MatchRun.start()` no-op → the countdown→match→results walk went red.

### Item 3 — Host a match from the menu and show the invite code (`07ab41b` + `2790d07`, 1 attempt, engineer-only)

- **An ordering guardrail between two synchronous statements is invisible to any test that inspects state after the call returns.** "Tear the lobby down before the route moves" survived a mutation that reordered it — both halves land in one main-actor turn, so nothing after `cancel()` can see the intermediate state. Pinned with a `withObservationTracking` observer on `route` whose `onChange` fires on `willSet` and asserts the channel is already gone; the mutation then went red. **Items 4 and 10 have the same shape — use the same technique.**
- **`FakeTransport.pair` makes "waits for a second player" vacuously green** — it buffers a `.connected` on both endpoints before returning. The builder used a `LobbyWire` double instead, with falsifiability designed into the double rather than asserted afterwards.
- **Reversing `OnlineMatch`'s roster is caught only as a hard precondition abort** in `MatchSession.swift:428`, not a clean assertion — host election is enforced upstream of the shell, so shell tests cannot assert on it cleanly.
- **Criterion 4 (live, two simulators) is unverified and was not weakened.** Nothing in `Willagrams/` calls `OnlineMatch.join`, so a second simulator has no in-app path into the host's lobby. Item 3's criterion 4 and item 4's criterion 4 are the same run — do them once, together, after item 4.
- **Open risk, not gating:** `OnlineMatch.leave()` fires the abandon as a detached `Task` with `try?`. A failed abandon is silent and the row stays `lobby`; `abandon(matchID:)` cannot report that it matched zero rows.
- **Counts:** ShellTests 135→142, root 53, MatchTests 125, OnlineTests 126 (+1 pre-existing known issue), xcodebuild BUILD SUCCEEDED. 7 mutation checks, all restored byte-identical.
