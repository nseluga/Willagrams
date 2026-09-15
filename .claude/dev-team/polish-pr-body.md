# polish lane — returned team-memory entries

## 2026-09-14 — dev-team-auto — One sizing mechanism for landscape phone, proven on Menu
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-ui (sonnet, high), dt-qa (sonnet, high) — auto/polish, commit 6706a34
- **What happened:** Added `Typography.buttonCompact` and `Space.screenMargin`/`screenMarginCompact` tokens, taught the three `ButtonStyle` structs to read `verticalSizeClass` for compact sizing, added `.screenPadding()`, and replaced MenuView's hand-tuned layout with a plain `MenuLayout(size:)` struct that drives wordmark height, spacing, and quiet-action column count.
- **What worked:** Builder's own ShellTests/StyleTests cases covered every criterion; dt-qa's fresh re-run confirmed them.
- **What failed:** The top-level screenshot review found the letter met but the intent missed — wordmark ~50pt on phone, a dead middle gap, not centered — so a follow-up Menu pass ran.
- **Remember next run:** `MenuLayout` must stay SwiftUI-free to compile in ShellTests' macOS target, so it uses `size.height < 500` as the compact proxy. `StyleSourceTests` requires every DesignTokens key to appear in `StyleGallery.swift` — a new token needs a gallery row. Judge layout items from the screenshot, not the struct's numbers.

## 2026-09-14 — dev-team-auto — Remaining fixed-size screens (HostLobby/Results/Countdown/SoloSetup)
- **Outcome:** DONE (top-level verified after orchestrator hand-back) — caution: no — team: dt-ui (sonnet, high); dt-qa not run — auto/polish-b2, commit 7e3c6af
- **What happened:** New `HostLobbyLayout` struct drives the invite-code font (44/32) and button height (36/32); Results/Countdown card padding goes `.xl`→`.l` under compact; HostLobby/SoloSetup use `.screenPadding()`. No new tokens.
- **What failed:** Orchestrator ran out of turn budget waiting for a contention-free xcodebuild window — three worktrees built at once all session.
- **Remember next run:** Never run parallel-group UI items that each need xcodebuild concurrently on one machine; give each a distinct `-derivedDataPath` or serialize builds.

## 2026-09-14 — dev-team-auto — HUD bag legible on a phone
- **Outcome:** DONE (top-level verified; builder stalled "waiting on background work" and was stopped) — caution: no — team: dt-ui (sonnet, high) — auto/polish-b3, commit c1ef2ad
- **What happened:** `MatchHUDLayout` holds bag size (96 regular / 72 compact) and the pool-count formatter (nil → `—`); the count Text is monospaced-digit with minimumScaleFactor 0.5. Mutation check: nil guard → "0" turns the new test red.
- **Remember next run:** A shared-DerivedData "database is locked" BUILD FAILED is contention, not a code error. Don't wait on a subagent reporting "waiting on its own background work" with no process running — take over.

## 2026-09-14 23:04 — dev-team-auto — Keep typed field visible above keyboard (Profile/Friends/Join)
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-ui (sonnet, high), dt-qa (opus, high) — auto/polish, commit a3ce6f0
- **What happened:** @FocusState + ScrollViewReader/scrollTo(.center) + .scrollDismissesKeyboard(.interactively) on ProfileView, FriendsView, JoinView; Join moved into the code field's row; `.screenPadding()` on all three.
- **What worked:** dt-ui caught that analyze-report's "Join sits below Cancel" note was stale and fixed to the real requirement, reporting the discrepancy.
- **Remember next run:** Moving a button beside a field can leave a lone button stretching full-width on iPad (maxWidth: .infinity) — check sibling buttons in the row it left.

## 2026-09-14 23:23 — dev-team-auto — Make the validation messages reachable
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer (opus, high) — auto/polish, commit 72fcb64
- **What happened:** canSave/canLookup/canJoin gate only on empty-after-trim + in-flight; the actions keep their length guards and messages, so bad input shows the message with zero backend calls. .onSubmit on Profile and Friends fields. 6 mutation checks (3 length guards, 3 empty-disables) all went red.
- **What failed:** A new isolated Join fixture tipped a pre-existing SoloMatchTests timing case into timeout in full-suite runs; folding the step into the existing short-code case fixed it.
- **Remember next run:** In ShellTests (227+), extend an existing case over adding a new fixture-heavy @Test — extra parallel fixtures tip timing-sensitive tests.

## 2026-09-14 23:39 — dev-team-auto — Let the board zoom further out
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer (opus, high) — auto/polish, commit 0a84844
- **What happened:** BoardCamera.minCellSize 24→16; floor-hardcoded assertions updated (BoardGestureTests pinch-out, BoardDragGateTests zoom 0.5→0.25 and derived offsets). Mutation: reverting to 24 turns the pinch-out case red.
- **Remember next run:** For a constant change, grep the symptom (`== minCellSize`, `cellSize ==` near zoom literals) too — a derived collision like `zoom: 0.5` reaching the old floor won't show in a literal grep.

## 2026-09-14 23:55 — dev-team-auto — Unfriend (item 6)
- **Outcome:** DONE — 1 attempt — caution: yes — team: dt-engineer opus/high, dt-qa opus/high, dt-review opus/high — auto/polish, 7efea2e
- **What happened:** FriendForgetting side protocol (Supabase + Fake), accepted-only delete, FriendsModel.unfriend, FriendsView Unfriend button + confirm dialog. QA re-ran all three mutations plus the live case (ynkayuwwrifluhhqnrjc, passed); review 0/0/3 Minor.
- **What worked:** Mutation-checking the status filter on both backends — live M2 red on the real project — proved the filter is the only thing protecting a block, since RLS allows deleting any status.
- **Remember next run:** A new protocol FakeBackend conforms to must be listed in Tests/ShellTests and Tests/AccountTests Package.swift. Open Minors: reload on notFound in unfriend, live-test cleanup on a throw, `.lineLimit(1)` on row buttons (three buttons now on accepted rows).

## 2026-09-14 — dev-team-auto — item 8 remove drag snap-back
- **Outcome:** DONE — 2 attempts — caution: yes — team: dt-engineer opus/high→xhigh, dt-qa opus/high→xhigh, dt-review opus/high→xhigh — auto/polish-c8, 4e46e3a (merged into auto/polish)
- **What happened:** Repro proved a lost onEnded (system edge gesture cancels the DragGesture; the next touch's began() dropped the held tile). Deleted the dead distance guard, added cancel-path landing via @GestureState, deferred edge gestures while input is live. Attempt 1 passed QA but review caught the leftover tile landing after the new touch's hit test; attempt 2 fixed it.
- **What failed:** QA can't drive BoardView's gesture wiring; only review caught the guardrail break.
- **Remember next run:** Removing the occupied check in BoardDrag alone fails no test (`Board.place` also refuses) — bypass both. `threshold` is now dead but threaded through ~100 test call sites. BoardSourceTests pins BoardView source; new modifiers naming `inputLocked` need an exact-line exemption. Merge with item 7 conflicted in BoardDragGateTests (resolved to zoom 0.25).

## 2026-09-15 00:30 — dev-team-auto — Make recenter actually frame every tile (item 9)
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer (opus, high) — auto/polish, 395cbce
- **What happened:** `BoardInsets` plain struct threaded through `BoardLayout.framing` / `BoardCamera.recenter`; both recenter sites go through one `recentered(in:)`; `MatchHUDLayout.boardInsets` derives from the real bag/control tokens and is symlinked into BoardTests. Mutations (insets ignored, 16pt clamp removed, zoom-in cap removed) all red. Top-level re-run: Board 256, Shell 227.
- **Open:** the recenter button's own footprint (top-right) is not in chromeInsets — a tile can sit under it.
- **Remember next run:** ShellTests timing cases (countdown/deal waits) flake under concurrent agent load; compare against a clean-HEAD run before calling it a regression. BoardSourceTests' networking-word guard scans doc comments too.

## 2026-09-15 00:26 — dev-team-auto — Item 10: no re-animation of panned-back tiles
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-ui (sonnet/high) + dt-qa (opus/high) — auto/polish, 645eaa9 — QA PASS
- **What happened:** Pure `BoardRender.arrivalTransition(for:arriving:)` (`.fromBag`/`.none`); BoardSurface's transition gated on token-scoped `activeArriving`, so an arriving tile culled through its flight doesn't fly in later. Culling untouched. BoardTests 258; hand test done live in an iPad mini Simulator.
- **Open (unfixed):** the swap put-back fly-to-bag animation is likely lost — `.transition` covers removal too and now resolves `.identity` for non-arriving ids. An `.asymmetric` always-on removal would NOT be safe: recenter animates the camera inside `withAnimation`, so culled tiles would fly to the bag on every recenter. A real fix needs a "departing" signal from the swap path.
- **Remember next run:** Conditioning a tile `.transition` changes both insertion AND removal; check both directions.

## 2026-09-15 01:30 — dev-team-auto — item 11 drawn tiles land near the board
- **Outcome:** DONE — 1 attempt — caution: yes — team: dt-engineer opus/high, dt-qa opus/high, dt-review opus/high — auto/polish, a12e037 + c6f0ca5 — QA PASS, review 0/0/2
- **What happened:** `BoardView.onCameraSettled` → `MatchBoard.cameraSettled` (pan/pinch end, first framing, recenter — not per frame); `BoardLayout.delivered` anchors below (else beside) the largest ≥2-tile cluster, clamped to item 9's inset rect when the cluster is on screen; old rule kept as `viewportDelivered` fallback. Mutations a–d red.
- **Open:** (1) cluster off screen → tiles land beside it, off screen (spec allows; pulls against "forgiving"); (2) L-shaped cluster can take the empty bbox corner; (3) `MatchBoard.camera` could be `@ObservationIgnored` to skip MatchView redraws on settle.
- **Remember next run:** Overwrite mutations must bypass `Board.place` too. Shared no-adjacency test helper flags a cluster's own tiles — use `assertLandedClear` for cluster fixtures.

## 2026-09-15 — dev-team-auto — item 12 Fix the early start
- **Outcome:** DONE — 1 attempt — caution: yes — team: dt-engineer opus/high, dt-qa opus/high, dt-review opus/high — auto/polish-d12, f661834 (fix d9133f5)
- **What happened:** `awaitStart()` no longer opens the match; the creator's `start()` always opens; `startMatch` guard is `roster.contains`; pool stays on `roster[0]` via `applyStart`. Old-rule tests rewritten in place. QA PASS first try, review 0/0/4 (2 stale comments fixed).
- **What worked:** two-device OnlineMatchTests case where the guest sorts first — `startingHandSize` 0 after `awaitStart`, pool on the guest after `start()`; a second `.start` during play, followed by a grant, as the `hasStarted` mutation test.
- **Mutation checks:** auto-open restored → red; guard back to pool-host-only → red; `hasStarted` removed → red.
- **Remember next run:** TerminalAudit:292 can't catch a missing `hasStarted` guard (`isMatchOver` drops it first) — test second-start during play. The Online known issue now reports at WholeMatchScript.swift:98 (same test as :471). The `roster.contains` guard can't refuse; only the UI stops a joiner sending `.start` (a modified client could, as before).

## 2026-09-15 — dev-team-auto — item 13 guest pool count
- **Outcome:** DONE — 1 attempt — caution: yes — team: dt-engineer opus/high, dt-qa opus/high, dt-review opus/high — auto/polish-d12, 00a49e0 — QA PASS, review 0/0/2
- **What happened:** HostPool.answer gained `broadcastingCount:` at deal/draw round/swap; MatchSession receive handles `.poolCount` with 3 guards (no pool here, in range, keep min). New MatchSessionPoolCountTests; 7 wire-exact MatchTests files updated for the trailing `.poolCount` (QA: none weakened). Mutations a, b-lo, b-hi, c, d×3 red.
- **Note for Nate:** `MatchHUDModel.poolCanServeASwap` now reads the guest's received count, so the guest's Swap disables below 3. The received count only lags high, so it never blocks a swap the host would allow.
- **Remember next run:** Any new host→peer message breaks the exact-message asserts in HostPool/Adversarial/Stress/MatchSession/TerminalAudit/Hardening tests. Check `uptime` before counting ShellTests timeouts. Test "host ignores X" with a sentinel (`.drawRequest` from a stranger), not a sleep (open Minor: a 200ms wait in MatchSessionPoolCountTests:92).

## 2026-09-15 01:26 — dev-team-auto — item 14 WILLA word + flourish
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer (opus, high), dt-qa (opus, high) — auto/polish-e14, 1b2e6e6 — QA PASS
- **What happened:** `WillaWordList` (Match/) wraps any WordList, forwards the base's hash; wrapped in `ShellModel.loadedDictionary()` and inside `MinimumLengthWordList` in `MatchSession.applyStart`. `BoardModel.willaRuns` + a `willaSparkles` counter that bumps only on a new run; BoardView tints and sparkles off `onChange(of: willaSparkles)` (no `initial`), so pan re-insertion can't replay it. 4 mutations red.
- **Open:** no Simulator screenshot — visual is Nate's hand test; lifting and re-dropping a WILLA tile replays the sparkle (a new run per spec); several runs in one move share one sparkle.
- **Remember next run:** Key one-shot board effects on a model-side counter, never on view appearance (BoardSurface culls).
