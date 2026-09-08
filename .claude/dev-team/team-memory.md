# Team memory — Willagrams

Cross-run notes from `/dev-team` and `/dev-team-auto`. Project-specific only —
general process lessons live in `~/os/knowledge/memory/dev-team-learnings.md`.

> Items 1-4 of the 2026-08-15 match-lane run have no entry here. Their
> orchestrators were not asked to return one and their contexts were discarded
> at item end, so those entries are gone rather than merely unwritten. From
> item 5 on, every orchestrator returns its entry and the session writes it.

## 2026-08-15 15:20 — dev-team-auto — match item 5: terminal states (win, resign, peer-disconnect freeze)

- **Outcome:** DONE — 4 attempts — caution: no — team: dt-engineer opus (fix), dt-qa opus, dt-review opus, dt-engineer opus (review-fix), dt-review opus (delta), dt-engineer opus (flush-loss fix) — branch item5/terminal-states, commit c225552
- **What happened:** A prior run of this item had crashed mid-loop leaving branch item5/terminal-states at 448c8da plus an UNCOMMITTED red audit test. Resumed rather than rebuilt: the audit test was right and the implementation wrong — the enqueue chain's execution-time gate consulted only `isFrozen`, never `isFinished`, so work queued before a match ended still drained into HostPool and the rack afterward. Fixed by gating on `isLocked`, then two review rounds closed a split-brain in this device's own outbound terminal message. 74 → 100 tests.
- **What worked:** Checking `git worktree list` before spawning anything — the crashed run's branch and its red test would otherwise have been silently rebuilt from scratch. Reviewing the DELTA of a fix pass separately: the second review found an Important the first review could not have seen (flush clears `owesTerminalMessage` synchronously but sends later on the chain, so a `transport.send` throw loses the message with the flag already false) — it would have shipped green. Requiring every negative assertion to be mutation-proven RED: 14 mutations across the passes, several of which exposed real defects rather than confirming intent.
- **What failed:** QA PASSed at 016d629 with a test pinning OBSERVED behavior ("a win still on the chain when the peer leaves is swallowed") that the reviewer correctly called a bug — a green QA gate and a valid review finding directly contradicted each other on the same code path. Resolved by orchestrator ruling for the reviewer and narrowly authorizing an amendment of that one assertion, with an explicit instruction to stop and report if the engineer disagreed rather than split the difference.
- **Remember next run:** (1) A crashed dev-team run leaves a real branch — ALWAYS `git worktree list` and diff candidate branches against the lane before creating a new worktree, and back up untracked files before any agent touches the tree. (2) When a fix pass materially changes behavior AFTER QA passed, QA's green no longer covers HEAD — run a delta review scoped to `git diff <qa-commit>..<fix-commit>`; it is cheap and it caught a shipping Important here. (3) A QA test can pin observed rather than required behavior and then block a correct fix — the orchestrator must adjudicate explicitly and authorize amendment narrowly, never let the engineer resolve it unsupervised (that is exactly how item 4 lost a whole test file). (4) TOOLCHAIN LANDMINE in Willagrams/Match: adding a stored `MatchMessage?` field to MatchSession — even an unused `@ObservationIgnored` one — aborts the Match suite with `swift_task_dealloc` "freed pointer was not the last allocation", signal 6, inside peerDropped()'s reconnect task, 3/3 reproducible. `Int`/`Bool`/`PlayerID?`/`[Tile]`/`[Placement]` are fine, and the same field WITHOUT `@ObservationIgnored` is fine. Layout-sensitive, so a future edit to this class can re-detonate it; current code works around it by holding a Bool and rebuilding the message from `winner`/`winningPlacements`.

## Carried findings — below the stop marker, need real devices

Both belong to `GKMatchTransport.swift` (item 7), surfaced during item 2's codec review:

- The wire version gate only binds callers that go through `MatchCodec.decode`. The GameKit adapter must be the SOLE reader of peer bytes and must call `decode` exclusively — any second path around it silently skips the version check.
- No payload size or nesting-depth cap is applied before `JSONDecoder`. A hostile or corrupt peer payload is decoded unbounded. Item 5 notes the codec's 16KB limit bounds `winningPlacements` in practice, but the cap is not enforced at the decoder.

## 2026-08-25 13:45 — dev-team-auto — Build the effect catalogue (AudioCatalogue.swift)
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer (opus/medium) — branch `item/audio-catalogue` off `lane/audio`, commit 11bd3795d778bf97fa32f249906d18c6ae9477a2
- **What happened:** Added `Willagrams/Audio/AudioCatalogue.swift` (`AudioCue` value + `AudioCatalogue.cue(for:)` over an exhaustive `default:`-free switch, Foundation only) and `Tests/AudioTests/Cases/AudioCatalogueTests.swift` (7 tests). Gate went 6 → 13 passing, the six seam tests unchanged. Self-verified by re-running the gate myself, not by reading the engineer's account.
- **What worked:** `Tests/AudioTests/AudioSrc` is a directory symlink to `Willagrams/Audio`, so a new source file joins the test target with zero `Package.swift` edits — MAP.md's "Decided — what the `audio` lane is and is not" section already documented this and every other seam surprise, which is why the item needed no dt-analyze. Read that section first on any audio item.
- **What failed:** The engineer's first pass shipped the source file only — no test file, no `.claude/dev-team/engineer-report.md`, and its report never reached me. One `SendMessage` follow-up naming the three missing artifacts by absolute path recovered all of them in the same agent, no re-spawn and no attempt burned.
- **Remember next run:** Before treating a dt-engineer completion as the attempt's result, `git status --short` the worktree and `ls` the report path — a completed agent can return nothing and leave deliverables unwritten, and resuming it via SendMessage is far cheaper than a second spawn. On the audio lane, never import AVFoundation/UIKit anywhere under `Willagrams/Audio/**`: the whole directory compiles on the macOS test host through the AudioSrc symlink, so one platform import breaks `swift test --package-path Tests/AudioTests` for every audio item at once. `AudioCue.init` does not clamp `volume`; the `0...1` guarantee is tested on catalogue output only — worth enforcing if a lane outside the catalogue ever constructs cues.

## 2026-08-25 13:45 — dev-team-auto — Build mute state and persistence (AudioSettings.swift)
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer (opus, medium) — branch item/audio-mute, commit 9aeccffc6cb4a1e7c896688583d30fb4d1d62322
- **What happened:** New `Willagrams/Audio/AudioSettings.swift` — `public final class AudioSettings: @unchecked Sendable`, Foundation only, one injected `UserDefaults` suite, key `audio.muted` exposed as `public static let mutedKey`. Reads straight through via `bool(forKey:)` (no cache, no lock), so fresh-install-unmuted needs no registered default. Four tests added in `Tests/AudioTests/Cases/AudioSettingsTests.swift`; suite went 6 → 10 pass, first attempt green.
- **What worked:** Per-test scratch suites via `UserDefaults(suiteName:)` torn down with `removePersistentDomain(forName:)`, plus an explicit test asserting `UserDefaults.standard` has no `audio.muted` before AND after — it fails loudly if an earlier run polluted the host rather than silently passing. `Tests/AudioTests/AudioSrc` being a directory symlink to `Willagrams/Audio` means a new file in the app dir compiles into the test target with no `Package.swift` edit.
- **What failed:** none.
- **Remember next run:** Class over actor was the right call — an actor makes every `isMuted` read `await` and the call sites are main-actor UI handlers. The audio test package declares `.macOS(.v14)` and compiles the whole `Willagrams/Audio` directory, so any future file there must stay Foundation-only or sit behind `#if canImport(UIKit)`. The mute *control* is still unbuilt by design: it belongs to `Willagrams/Settings/**` (merged lane) and is a shell round-3 / settings amendment item; `mutedKey` is public so that lane needn't retype the string. `.claude/dev-team/analyze-report.md` did not exist for this run and wasn't needed for this surface.

## 2026-08-25 14:35 — dev-team-auto — Build SystemAudioPlayer (real playback, respects silent switch)
- **Outcome:** DONE — 3 attempts — caution: yes — team: dt-engineer opus (build + 2 fix passes), dt-qa opus, dt-review opus (initial + 2 delta reviews) — lane/audio, commit ee3d4f6 (reports 2a08fc0)
- **What happened:** Built `SystemAudioPlayer` wholly inside `#if canImport(UIKit)` — lazy `.ambient` session, 3-voice `AVAudioPlayer` pool per catalogue asset so overlapping cues overlap, warmed static main-actor `UIImpactFeedbackGenerator`s copied from `TileFeedback`. QA PASSed on first build; review then found 4 Important, and the fix for those introduced 2 more, caught only because a delta review ran on the fix diff.
- **What worked:** A real iOS Simulator smoke harness (`Tests/AudioTests/SimulatorSmoke/run.sh` — `swiftc` for the simulator triple + `simctl spawn`) verified session category, mute-silence and voice overlap that no macOS unit test can reach. QA rebuilt the engineer's harness against a *real generated WAV* in a second bundle and caught that the engineer's empty-bundle-only smoke could not have covered the session or overlap criteria at all. Non-vacuity checks (disable the branch, confirm the assertion FAILs) caught nothing but cost nothing.
- **What failed:** Engineer's first `sessionReady = true` latched before the `try?` calls — twice: fixed for `setCategory`, re-introduced for `setActive`. A blanket 200ms stale-cue drop added in fix 1 silently dropped `countdownTick` (the one cue with `haptic: nil`); gated on `cue.haptic != nil` in fix 2. Engineer's self-reported "verified" in the build report was not evidence for two criteria.
- **Remember next run:** (1) `canImport(UIKit)` is false for a plain macOS SwiftPM target (true only under Mac Catalyst), so `Tests/AudioTests` parses but never compiles a UIKit-guarded file — the guard genuinely fences the host gate, and the gate stayed 17/17 throughout. (2) `xcrun simctl` + `swiftc -target arm64-apple-ios17.0-simulator` is a cheap, reliable behavioral gate for iOS-only code in this repo — reuse the SimulatorSmoke pattern for any later hardware-touching lane. (3) A `#if DEBUG` `queue.sync` closure accessor beats `Mirror` reflection for asserting on queue-confined state; `run.sh` needs `-D DEBUG` for it. (4) When a fix pass rewrites a guard ordering or adds a timing threshold, ALWAYS delta-review the fix diff — both of this item's second-round Importants lived only in the fix, not the build.

Flagged for human review per `caution: true`: the accepted residue is that `win`/`loss` cues (haptic-paired) remain droppable if the audio queue is backed up past 200ms; the reviewer downgraded this to acceptable because the only real backlog is the cold decode in the first seconds after launch, when neither cue can occur.

## 2026-08-25 15:05 — dev-team-auto — Wire the placement sound to the snap it belongs to
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer (opus, medium) — lane/audio, 684ca00
- **What happened:** Added `private static func delay(for:)` inside `SystemAudioPlayer`'s `#if canImport(UIKit)` block returning `DesignTokens.Motion.snapDuration` for tilePlace/tileRecall, `dealDuration` for draw, 0 for the rest; delayed cues go through `queue.asyncAfter`, zero-delay cues keep the plain `async` enqueue that preserves ordering behind `preload`. One pass, no rework.
- **What worked:** Naming the stale-cue interaction in the builder prompt up front rather than letting it be discovered — the engineer re-anchored the staleness measurement to the cue's due time instead of bolting `asyncAfter` onto the existing stamp. The `xcodebuild` iOS build is the only execution proof that a `Motion` reference inside the UIKit guard resolves; `swift test` cannot see that file at all.
- **What failed:** none.
- **Remember next run:** `grep '0\.45'` under `Willagrams/Audio/` will always hit `AudioCatalogue.swift:45  volume: 0.45` — a loudness, not a timing. A future criterion phrased as a bare literal grep needs `| grep -v 'volume:'` or it reads as a false failure. Also: anything guarded by `#if canImport(UIKit)` is invisible to the AudioTests gate, so a green `swift test` proves nothing about it — pair it with the iOS build every time.



<!-- harvested from lane/online PR #3, merge order -->

## 2026-09-02 00:05 — dev-team-auto — online item 1: concrete Supabase client + session
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer (opus/medium) — branch `item/online-client`, merged into `lane/online` at `e061e4a`
- **What happened:** Built `SupabaseBackend` (actor, `BackendClient`) + `SupabaseConfig` + the `WILLAGRAMS_LIVE_TESTS` gate and 5 live cases. Converged in one engineer pass; the orchestrator mutation-checked all 12 guards itself. Live criteria 1–3 deferred — no anon key is reachable in this session, so the live cases are written for real but report as skipped.
- **What worked:** Factoring the three offline-provable pieces out as pure statics (`friendCodeAlphabet`, `randomFriendCode()`, `backendError(from:hasSession:)`, `firstProfile(fromRows:)`) — named in the spawn prompt as a testability requirement — made every guard mutable and every mutation red without a single injectable-fetch abstraction. Forcing `LiveProject.isEnabled` to `true` is the cheap proof that skipped live cases are real: they returned a genuine 401 from the project URL rather than passing.
- **What failed:** none.
- **Remember next run:** `Tests/OnlineTests` is no longer SDK-free — it now pins `supabase-swift` `exact: "2.55.1"` and links Auth/PostgREST/Realtime, because `Willagrams/Online/**` is symlinked in whole. Any future `AccountTests`/`FriendsTests` package that symlinks `Willagrams/Online` inherits the same dependency and the same multi-minute first build; that is a consequence of LANE.md's file layout, not of this item. There is no `Supabase` umbrella product in the xcodeproj (only Auth/PostgREST/Realtime), so `SupabaseClient` does not exist in this codebase — compose the three clients over one token source instead. `SupabaseConfig.anonKey` reads `SUPABASE_ANON_KEY` from the environment, so every live run needs `WILLAGRAMS_LIVE_TESTS=1 SUPABASE_ANON_KEY=... swift test --package-path Tests/OnlineTests`. `supabase projects api-keys` is blocked by the permission classifier — get the key from the dashboard or an `.env` before promising a live verification pass. New offline gate baseline for items 2–7: 41 tests, 4 suites, 36 passed, 5 skipped.
- **Worktree naming (lane-level, found at preflight):** SwiftPM derives package identity from the directory name, and `Tests/OnlineTests/Package.swift` depends on `.package(path: "../..")`. Any worktree whose last path component is not literally `Willagrams` fails to resolve. Create item worktrees as `<dir>/Willagrams`.

## 2026-09-02 00:20 — dev-team-auto — Friendships on the real client (SupabaseBackend+Friends)
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer (opus/medium); orchestrator self-verified — branch `item/online-friends`, commit `50b0947`
- **What happened:** `SupabaseBackend+Friends.swift` implements `friendships()`, `requestFriend`, `respondToFriendRequest` and `block` against `public.friendships`. Suite went 41/36 passed/5 skipped → 58/49/9. All four `done when:` criteria are live and DEFERRED (no anon key this run); the offline core was extracted, executed and mutation-checked instead.
- **What worked:** Naming each guard to break in the spawn prompt, then breaking all five: pair normalisation, rows-concerning-me filter, decline→blocked, the status/responded_at biconditional, zero-rows-is-[]. Forcing the live gate with a bogus `SUPABASE_ANON_KEY` produced a real HTTP 401 from `/auth/v1/signup` — the only cheap proof the deferred live cases are not silent no-ops, and it also proves the project is reachable and only the key is missing. `pairFilter` sorting the two uuidStrings so both argument orders yield the *identical* string is what made the unordered-pair rule offline-testable at all.
- **What failed:** The parallel group was not disjoint. Both group-b items had to edit `SupabaseBackend.swift` — their placeholder stubs sit in the actor body, and Swift cannot re-declare a method in an extension. Both also need `rest` and `mapping` relaxed from `private` (Swift `private` is file-scoped, so a `+Friends.swift` extension cannot see them). The plan's "stay strictly inside your own files" rule was unsatisfiable as written.
- **Remember next run:** In this repo, an item that fills in a `// item N` stub in `SupabaseBackend.swift` MUST edit that file — plan it as a serialisation point, or have `/foundation` put the stubs in per-item extension files from the start. Any `SupabaseBackend+*.swift` extension needs `rest` and `mapping` internal, not `private`. `LiveProject.isEnabled` + `LiveProject.fresh()` is the one live gate — reuse it, never build a second. Verify a deferred live case with `WILLAGRAMS_LIVE_TESTS=1 SUPABASE_ANON_KEY=not-a-real-key swift test` and look for a 401; make it a standing step for every live-deferred item. First `swift test` in a fresh worktree compiles supabase-swift and takes minutes — always pass a 600000 ms timeout. Still unmapped and live-only: sqlstate `23514` (`friendships_not_self`) and `23503` (FK to a missing addressee profile, where `FakeBackend` throws `.notFound`).

## 2026-09-02 00:22 — dev-team-auto — online item 3: Matches on the real client
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer (opus/medium) — branch `item/online-matches`, commit `ee4c64d`, plus a wiring patch applied by the run orchestrator at merge
- **What happened:** Built `Willagrams/Online/SupabaseBackend+Matches.swift` (insert `matches` + the host's own `match_players` row, `rpc("join_match")`, roster ordered by `joined_at`) plus an offline suite and 5 real live cases. Suite went 41→57→75 tests across the merge, 0 failures, 14 skips. The item shipped UNWIRED — the three protocol methods still held placeholder bodies — because the parallel sibling owned `SupabaseBackend.swift`; the run orchestrator applied the four-line patch after merging both branches and added a scan test so it cannot silently revert.
- **What worked:** Factoring every offline-provable decision into pure statics (`randomInviteCode`, `shouldRetryInsert`, payload builders, row decoders) — item 1's pattern — made all 7 mutation checks land on a named test. A `#filePath`-rooted scan of `Willagrams/Online/*.swift` holds the "never select `matches` by `invite_code`" guardrail open against future edits. Forcing the live gate on with a deliberately bogus `SUPABASE_ANON_KEY` proved the gated cases are not silent no-ops — all 5 hit the real host and 401'd.
- **What failed:** `error: 'rest' is inaccessible due to 'private' protection level` — a Swift extension in another file cannot see `private` members, so the actor's PostgREST client was unreachable from the extension. Worked around with a `SupabaseMatchQueries` value taking the client as a parameter, leaving one unwired factory that threw a distinct non-`BackendError` type until the orchestrator's patch landed.
- **Remember next run:** Any `SupabaseBackend+*.swift` extension item hits the same wall — `auth`, `rest` and `mapping` must be internal, not `private`, and the `// item N` stub bodies in the actor shadow the protocol methods so an extension cannot redeclare them. Make the visibility change a `/foundation`-style amendment BEFORE splitting the online lane into a parallel group, or serialize the `SupabaseBackend+*` items. The round-2 parallel-group split was not actually disjoint. Wiring a stub is invisible to a green suite because no offline test can call the protocol method — add a source-scan test asserting the placeholder body is gone (`SupabaseMatchesTests.theProtocolMethodsAreWired`), mutation-checked both ways. Also: `swift test --filter "Suite Name"` does not match on a `@Suite` display string — filter on the type name.

## 2026-09-02 01:15 — dev-team-auto — item4: the realtime transport
- **Outcome:** DONE — 4 attempts — caution: yes — team: dt-engineer opus/medium (x4), dt-qa opus/medium (x4), dt-review opus/medium (x3) — branch item/online-transport, commit e0d9040
- **What happened:** Built `RealtimeMatchTransport` (public actor, `MatchTransport`) over one `match:<uuid>` Supabase Realtime channel, behind an injectable `MatchChannel` seam so the stream contract is provable offline; `SupabaseMatchChannel` is the only SDK-facing file; `transport(for:as:)` wired in the `SupabaseBackend` actor body. Four attempts, every re-attempt driven by dt-review — QA passed all four times.
- **What worked:** The injectable channel seam. Criteria 2/3/4 (buffer-and-replay, finish-on-leave, lossy==reliable, no-backpressure) were all proven against a stub bus with zero network, and QA mutation-checked each one both ways (12–14 mutations per pass). Body-slicing `#filePath` source guards closed properties the stub genuinely cannot observe (`retrack.close()`/`peers.cancelGrace()` inside `leave()`), and QA proved the slice is fail-closed by respelling `func leave() {` and watching it go red. Deriving the live-test deadline from `RealtimeMatchTransport.defaultPeerGrace` instead of a literal made a whole defect class non-recurring. The standing check (`WILLAGRAMS_LIVE_TESTS=1 SUPABASE_ANON_KEY=not-a-real-key` → genuine HTTP 401) kept the deferred live cases honest.
- **What failed:** Four rounds of offline-invisible SDK-lifecycle defects, all found by reading the pinned supabase-swift 2.55.1 source, none catchable by any stub: (1) `unsubscribe()` without `removeChannel` leaks a channel entry and never tears the socket down; (2) `connect` leaked the channel when `subscribe` threw; (3) `.seconds(5)` peer grace was an unmeasured guess, shorter than `MatchSession.reconnectGraceSeconds = 30`, making `MatchSession.peerReturned` dead code; (4) the SDK does not re-`track` presence on socket rejoin (`ChannelStateManager.resetForReconnect`), so a reconnect left the endpoint invisible and the peer ended the match. Attempt 3 also broke the deferred live case by raising the grace past its literal 30 s deadline. One engineer test initially passed for the wrong reason — a 5 s window with a 200 ms sleep meant the timer never fired inside the case; he caught it himself, but only after writing it.
- **Remember next run:** For anything touching supabase-swift, tell the engineer to read the pinned SDK source for every lifecycle call before writing the fix — `removeChannel` is the only path that clears `RealtimeClientV2.channels` and the only disconnect-on-empty trigger; `RealtimeClientV2.channel(topic)` returns the *existing* instance for a live topic (hence the `PendingRemovals` sequencing); `onStatusChange` replays only the current status at registration; `track` is not re-sent on rejoin. Never size a test deadline as a literal against a production constant — derive it. A timing-sensitive test must be mutation-checked before it is trusted: a window the timer never enters is a green non-test. dt-review earned its place here four times over while dt-qa never once failed the item — on SDK-integration items the reviewer is the gate that actually bites, so budget for review rounds, not QA rounds. The live gate stayed unavailable all run (`supabase projects api-keys` denied by the permission classifier, no `.env`) — criterion 1 remains DEFERRED and must be run by hand once an anon key exists; expect the criterion-3 live case to cost up to 60 s of wall clock then.

## 2026-09-02 09:35 — dev-team-auto — item5: recording the match outcome
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer opus/medium — branch `item/online-outcome`, commit ea9bf08
- **What happened:** `MatchOutcomeRecorder` observes a `MatchSession` and records the outcome: the creator closes the `matches` row (`playing`+`started_at`, then `finished`+`finished_at`+`winner_id`), every player bumps their own `profiles` row exactly once. The database sits behind a three-method SDK-free `MatchOutcomeStore` (`updateMatch`/`profile`/`updateProfile`), with the Supabase conformance in a separate `SupabaseBackend+Outcome.swift`. One engineer pass, green first try; the orchestrator ran nine independent mutation checks on top of the engineer's twelve.
- **What worked:** Factoring the whole rule set into pure statics (`ProfileStats.after`, `ProfileStats.fastestWin`) plus a recording actor double made every false-negative-shaped guardrail decidable offline — "exactly once", "the guest writes nothing", "never decrements" all became assertions on calls that did *not* happen. Latches set *before* the `await`, not after, is what makes re-entrant observation safe. Seeding the monotonicity test's profile at 7/4/61/25 rather than 0/0/0/0 is what makes a blind `matches_played = 1` write distinguishable from a real increment — a fresh profile would have passed either way. The fake-anon-key run remains the cheapest proof that gated live cases are not silent no-ops.
- **What failed:** none. The orchestrator's first mutation-check harness silently no-op'd (`git diff --quiet` on an untracked file gated the run), which would have reported nine vacuous green passes as nine mutation checks — caught only because it printed an explicit "MUTATION DID NOT APPLY" branch.
- **Remember next run:** Always give a mutation-check harness an explicit "did the edit actually land" assertion (`diff -q` against the backup) that prints loudly — a mutation that fails to apply looks exactly like a mutation the suite caught. `git diff --quiet` is useless for this on untracked files. PostgREST reports an RLS-hidden row on an UPDATE as *zero rows patched* (200, empty body), never 42501 — so a "only X may write this row" rule must be gated on the client; the database cannot signal the refusal. `PostgrestQueryBuilder.update` defaults to `returning: .representation`, which costs a second policy check — pass `.minimal` when the row is not wanted. New files under `Willagrams/Online/` need no `.xcodeproj` edit (fileSystemSynchronized group); confirm inclusion by finding the `.o` under DerivedData rather than trusting BUILD SUCCEEDED. The `theProtocolMethodsAreWired` source scan now also covers `SupabaseBackend+Outcome.swift`; extend it for every new network-facing file, since offline tests all run against doubles.

## 2026-09-02 10:05 — dev-team-auto — item6: the OnlineMatch façade
- **Outcome:** DONE — 2 attempts — caution: no — team: dt-engineer (opus/medium, both attempts) — branch item/online-facade, commit ffa8cfe
- **What happened:** Built `OnlineMatch` over `BackendClient` + `MatchTransport`, SDK-free. Attempt 1 was green with 9/9 mutations but threw `notPoolHost` whenever the creator did not sort first, dead-locking half of real pairings; it reported this as needing a lane amendment though the fix lived in an OWNED file. Attempt 2 elected the opener from `roster[0]` in both `start()` and `awaitStart()` and deleted the dead error case.
- **What worked:** Deepening `FakeBackend` with `setTransportFactory(_:)` and `matchRecord(_:)` instead of building a second `BackendClient` — the stock `FakeBackend.transport` returns `FakeTransport.pair(...).first` and drops the peer, so no presence can be staged and no send counted. Constructing the oversized-lobby refusal with a third id above both others, so the count guard rather than the host rule is what must stop it. Mutation-checking `record.hostID` substituted for `roster[0]`.
- **What failed:** A `severity: high` finding phrased as a scope refusal masked an in-scope defect for a full attempt. And electing via `record.hostID` was a silent false-negative: `MatchSession.startMatch` carries its own `HostPool.host` guard and no-ops, so the wrong device opening sent nothing and every wire assertion still passed; now caught by asserting the receiving side's `session.lastNote == nil`.
- **Remember next run:** When an engineer proposes a lane amendment, check the path against the lane's `owns:` globs before accepting it — an amendment request for an owned path is a re-derive signal, not a blocker. Any guard that a downstream production type ALSO enforces is a false-negative candidate: mutate it and confirm a NAMED test fails, because the downstream guard will silently absorb it. `MatchSession.startMatch`'s host guard, `MatchSession.init`'s roster preconditions (a process trap, no summary) and `MatchMessage.validatedStart` all absorb façade-level mutations this way; scope such mutations narrowly or the run aborts with no output at all. `Int64.random(in: 0...Int64.max)` is the right draw — `matches.seed` is a signed bigint. `outcomeStore()` lives on `SupabaseBackend`, not on the frozen `BackendClient`, so inject it and keep the `as?` cast as a default only.

## 2026-09-02 10:30 — dev-team-auto — item7: wiring — a whole match through real MatchSessions (LiveMatchTests)
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-engineer (opus/medium) — branch item/online-live-match, be67ecf
- **What happened:** Two new test files, no production code touched: `Tests/OnlineTests/Cases/WholeMatchScript.swift` (shared script + assertions + `MemoryOutcomeStore` + the offline suite) and `Tests/OnlineTests/Cases/LiveMatchTests.swift` (the real live case). The live half cannot execute without an anon key, so the value is in the shared script: live and offline differ only in what they are wired to and how they wait.
- **What worked:** Factoring criteria 1 and 2 into one `@MainActor enum WholeMatchScript` with an injected `Waiter` closure — live derives its deadline from `MatchSession.reconnectGraceSeconds`, offline counts scheduler turns. Deriving the draw ledger from `hand.count + pendingDrawTiles.count` rather than a transport spy, since `HostPool` deals a round to every player or to none — that makes "granted on one side, observed on the other" decidable from session state, which the live case has and a spy does not. Seeding offline profile rows 5/2/77/120 and 3/1/40/90 and asserting deltas, so the same helper reads correctly against a fresh live anonymous profile. Forcing the gate open with a junk key is a cheap, decisive proof that a live case is not a silent no-op — do this on every live item.
- **What failed:** none. Mutation results: 7 engineer mutations + 3 independent orchestrator mutations, 10/10 caught by a named test. Two of my three landed on the new whole-match case (`matches` row never goes through `.playing` → `row.startedAt == nil`; `matches_played + 2` → the delta assertion). The third — dropping `isCreator` from the recorder's `.finished` write so the guest also writes the `matches` row — was caught only by item 5's `SpyOutcomeStore` test, not by the new case: one shared `MemoryOutcomeStore` makes a duplicate write idempotent and therefore invisible. That is the right division of labour (item 5 owns that rule), but it is a real blind spot in the whole-match double.
- **Remember next run:** (1) `.claude/dev-team/analyze-report.md` is gitignored, so it does NOT travel into a fresh worktree — a spawn prompt that promises one is often wrong; check before briefing an agent to read it, and note that sibling worktrees' reports cover other lanes. (2) Never `pgrep -fl` a swift build to poll for completion — the full compiler command lines are enormous and will flood context; poll the background task's output file for non-emptiness instead. (3) `swift test --filter` matches the *type* name, not the `@Suite` display string: `--filter LiveMatchTests` works, `--filter 'whole match, live'` silently runs 0 tests and reports green — a real vacuous-pass trap when using a filter to prove a live case fires. (4) A test whose guardrail is "leaves no dangling subscription" must put teardown in a `defer`, not in trailing calls — a throwing `try` above them skips the cleanup, and the guardrail then only holds on the happy path. (5) When grepping a mutation run for failures, do not `head -N` the output: a truncated failure list made one mutation look uncaught when it was caught.

## 2026-09-08 — /merge-lane — lane shell round 3 merged to integration (PR #4)

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

### Item 4 — Join a match by invite code (`b66aafe` + `4c874d1`, 1 attempt, engineer-only)

- **A test that exercises a pure mapping function is not coverage of the screen that calls it.** The error-copy test asserted only `HostLobbyModel.message(for:)` as a pure function and never drove `JoinModel` — so a probe that swallowed every non-`.notFound` error stayed green. Closed with a parameterized model-level test over `.matchFull` / `.permissionDenied` / `.offline` driven through a `RefusingJoin` decorator; the mutation then went red on all three arguments.
- **9 mutation checks all went red**, covering every `done when:` criterion and all three guardrails, including the orphan-task and cancel-before-route ordering pair (using item 3's `withObservationTracking` technique) and the `JoinView` `exclude:` source fence.
- **Live, two simulators — both deferred criteria MET.** Host on iPhone 17 Pro showed invite code `M24Z8A`; after the guest joined on iPhone 17 Pro Max the host roster named both players; the guest reached `Waiting for host: …` and both devices reached the match screen when the host pressed Start. This closes **item 3's criterion 4** as well as item 4's. The anon key was sourced from the gitignored `.env` only and reached no source, test, fixture or log.
- **Counts:** ShellTests 142→153, root 53, MatchTests 125, OnlineTests 126 (+1 pre-existing known issue), xcodebuild BUILD SUCCEEDED.

**Four findings the live run surfaced — no code changed, carried for later items and the lane review:**
1. **`OnlineMatch.awaitStart()` returns as soon as `match_players` has two rows** and opens the match itself when the guest sorts as `roster[0]` — which makes the host's Start a no-op in roughly half of pairings. This is an Online-lane issue, not shell's, and **item 10 will hit it.**
2. `JoinView`'s `TextField` transiently renders characters the sanitiser rejects (a typed `-` showed as `M24Z-`). SwiftUI does not re-sync the field when `didSet` normalises to a value equal to the last observed one. The *model* clamp held — the live join used exactly `M24Z8A` — so the guardrail is intact; display-only, one-line polish fix.
3. `HostLobbyModel.message(for: .permissionDenied)` reads "You can't host a match right now." — host-voiced copy now shown on the guest's join screen. Reusing that mapping was mandated by item 4's prompt, so it was left as-is.
4. The Join button renders at full primary strength while `disabled(!canJoin)` — no disabled affordance.

### Item 5 — Reconnecting overlay, end on gone, online results home (`d68bc41` + `dc03b70`, 1 attempt, engineer-only)

- **`MatchHUDModel` is fenced against `peerPlayerID`** by `MatchHUDTests.hudNamesNoOpponent`. The item's literal wording ("the match-side model") pointed there, but putting the overlay on `MatchBoard` instead satisfied it without editing an existing assertion. **Put peer-identity work on `MatchBoard`, not the HUD.**
- **A protocol requirement with a default beat both a stored flag and an `is OnlineOpponent` cast.** `MatchOpponent.offersRematch: Bool` (default `true`, `false` on `OnlineOpponent`) lets `MatchRun.results()` omit the rematch closure while keeping item 2's fence that `MatchRun` never learns its concrete opponent type.
- **"No new stored state" guardrails are invisible to behaviour tests by construction.** Mirroring presence into a stored `MatchBoard.overlay` refreshed from `track()` passed all 159 tests — the "presence is read, never stored again in Shell" guardrail was unpinned. Closed with a falsifiable source-shape test asserting the *computed* spellings are present; the mutation then went red. This is the third run of the same lesson: a fence needs its own test that asserts what it greps is actually there.
- **A new overlay view inside an already-excluded View file needs no new `exclude:` entry** — `ReconnectingOverlay` landed inside `MatchView.swift`, already excluded. Check before adding one.
- The Swift 6.3.3 `MatchSession` toolchain limit was **not** tripped — MatchTests stayed at 125.
- **Counts:** ShellTests 153→160, root 53, MatchTests 125, OnlineTests 126 (+1 pre-existing known issue), xcodebuild BUILD SUCCEEDED. 9 mutation checks, all restored byte-identical.

**Contract for later items:**
```
MatchOpponent.offersRematch: Bool — default true; false from any far end that
  cannot be rebuilt from the end screen. MatchRun.results() omits the rematch
  closure when it is false.
MatchBoard.overlay: MatchOverlay? (.reconnecting(peer: String)),
MatchBoard.inputLocked: Bool, MatchBoard.reconnectingTitle
  — all computed off MatchSession; do not store presence.
ResultsModel.noWinnerHeadline == "Opponent left"
```

### Item 6 — Present the settings lane's options view and persist the choice (`2fa2198` + `e4c64b7`, 1 attempt, engineer-only)

- **`#expect(x == x.transform())` is always a tautology when `x` is already the transformed value.** The pre-existing `#expect(setup.options == setup.options.validated)` looked like it pinned the `MatchOptions.validated` guardrail; deleting `.validated` from production left the suite green. Closed with a test driving `startSoloPractice(options:)` with `minimumWordLength: 99`. **Grep new and inherited assertions for both sides deriving from the same expression before trusting them.** Fourth consecutive item shipping with exactly one vacuous check.
- **A source fence needs a presence half as well as an absence half.** The fence asserts `MatchOptionsView(form:` really appears in `SoloSetupView.swift` alongside banning the four `MatchOptions` field names. Mutation 6 re-added a real banned `Toggle` to production and the fence caught it, proving it is not vacuous.
- **Scoping the fence to the four `MatchOptions` field names** (rather than "any Toggle/Stepper") keeps `startingHandSize` — which lives on `MatchSetup`, not `MatchOptions` — and item 12's mute toggle legal without weakening it. Note for a human: a `Stepper` therefore does remain under `Willagrams/Shell/**`, deliberately.
- **`MatchOptionsForm()` hashes the whole ENABLE word list** (~2.2 s in a debug macOS test build). Build it once per `SoloSetup` on screen entry, never at `ShellModel.init`, or every ShellTests case that constructs a model pays for it.
- **`Willagrams/Settings/**` was consumed, not edited** — verified independently: `git diff --stat` over `Willagrams/Settings` and `Tests/SettingsTests` is empty. SettingsTests 36 before and after.
- **Counts:** ShellTests 160→164, SettingsTests 36, root 53, MatchTests 125, xcodebuild BUILD SUCCEEDED. 7 mutation checks, all restored byte-identical.
- **Cosmetic, unfixed (Settings is consume-only):** `MatchOptionsView` ships its own `"HOST"` mono label, `"Match options"` title and full-bleed gradient canvas, which reads wrong embedded in a solo screen. A settings-lane or dt-ui item, not shell's.

**Contract for later items:**
```
SoloSetup(store: SettingsStore?) — optionsForm: MatchOptionsForm? (settable; nil
  until entry), loadOptions(), saveOptions(_:), options: MatchOptions (always
  .validated). Go through optionsForm, not the removed scalar properties.
ShellModel.soloSetup is a `let` assigned in init from services.settings.
HostLobbyTests.make(sleepFor:settings:) — new optional settings: SettingsStore? = nil.
```

### Item 7 — The profile screen (`20b3fe8` + `71a100c`, 1 attempt, engineer-only)

- **Any UIKit/AppKit-fenced injection is unobservable to `swift test` and needs a source-level assertion that the wiring exists.** Deleting `pasteboard: Self.pasteboard` from `ShellModel.showProfile()` left the whole suite green: `ProfileModel` fell back to its no-op default, so the app's Copy button would have silently copied nothing, invisibly on macOS where UIKit is absent. Closed with `ProfileRouteTests."The shell hands the screen a clipboard that really writes"`. The same trap waits for a share sheet or haptics. Fifth consecutive item shipping with exactly one vacuous check.
- **A new test package consumes `Willagrams/Online` file-by-file, not as a directory.** `AccountTests` symlinks `OnlineSrc -> ../../Willagrams/Online` but lists only `BackendContracts.swift`, `FakeBackend.swift`, `MatchOutcomeRecorder.swift` and `OnlineMatch.swift` as extra `sources:` of its `Match` target. That is ShellTests' approach, not OnlineTests' whole-directory one, and it keeps the Supabase SDK out: no `supabase-swift` dependency and no `Package.resolved` (verified — zero `supabase` references in the manifest). Copy this shape for `Tests/FriendsTests`.
- **A model that `ShellModel` constructs needs a mirror target in `Tests/ShellTests/Package.swift`** with the same source symlink and the same View `exclude:` — otherwise ShellTests stops building the moment the shell references it.
- **No stat is computed client-side.** `ProfileModel.stats` is exactly four `ProfileStat`s read off the row as returned, so a server-side scoring change needs no app change.
- **Counts:** ShellTests 164→173, AccountTests 15 (new), root 53, xcodebuild BUILD SUCCEEDED. 12 mutation checks, all restored byte-identical.

**Contract for later items:**
```
AppRoute.profile · ShellModel.profile: ProfileModel? · @discardableResult showProfile() -> Bool
  (guards case .menu + non-nil currentProfile; torn down in returnToMenu() before the route moves)
ProfileModel(profile:isEditable:backend:pasteboard:) — draftName, trimmedDraft, canSave,
  message, isSaving, didCopyCode, stats: [ProfileStat] (exactly 4), save() async,
  copyFriendCode(), shareMessage, static nameLength = 1...24.
Item 9 reuses it read-only: ProfileModel(profile: friend, isEditable: false).
ProfileView(model:) takes its onward action as a closure — the view holds no route.
```

### Item 8 — The friends list (`b80db6a` + `f0f1f9a` + `1b3737f`, 4 attempts, **`caution: true`** — full engineer + QA + review team)

QA VERDICT **PASS** at attempt 3 (mutation-tested, no surviving mutant, live gate confirmed load-bearing). Re-review closed all five prior Important findings and raised one new Important — a missing `generation == mine` check on the `friendships()` catch branch — fixed in `1b3737f` and pinned with a mutation-RED regression case. Final review: 0 Critical, 0 open Important, 6 Minor.

- **A live-gated RLS test proves nothing unless you also run the gate-off control.** RLS refuses by returning zero rows, never an error, so a fake-only pass and a real pass look identical. QA confirmed the gate was load-bearing by checking that gate-off skips exactly the four live cases. Verified independently at the merge commit: gate on, 29 tests in 1.93 s; gate off, the same 29 pass in 0.019 s with those four skipped.
- **Three separate vacuously-green tests shipped in this item before mutation testing caught them.** (1) A `sorted(by:)` was deletable because the fake returned rows already in name order — fixed by renaming a fixture friend so row order and name order disagree. (2) A guardrail scanning the whole of `MenuView.swift` for `.disabled(...)` was already satisfied by a pre-existing row — fixed by bounding the scan to the Friends row and asserting the scoping held. (3) A spinner assertion armed only the write gate and so never observed the write→reload seam. **Grepping a whole file for a string is not a guardrail; scope the scan and assert the scope.**
- **`.timeLimit` cannot interrupt a parked `withCheckedContinuation`** — a swift-testing case that waits on a gate hangs forever rather than failing. Bound it with an arrival-count poll and a ceiling.
- **`withObservationTracking` re-armed inside its own `onChange` fires in `willSet`**, which is the only way to pin an ordering guardrail between two synchronous statements. It was the sole killer of the `end(); await load(); begin()` mutant.
- **A stale-publish guard applied to the success path and not the failure path is a live bug**: the losing load's error message overwrites the winner's sections. Guard every branch that publishes, including `catch`.
- **`Tests/FriendsTests` had to diverge from the `Tests/AccountTests` layout**: the live cases need `SupabaseBackend.signInAnonymously()` and therefore the Supabase SDK, so it follows OnlineTests' declaration (and does carry a `Package.resolved`) while keeping the module named `Match` so `#if canImport(Match)` still resolves.
- **Correction to an earlier note:** `ProfileView` does *not* call a `showFriends()` closure — it takes only `onBack`. Friends is reachable from the menu only.
- **Counts:** FriendsTests 29/5 (new, live), ShellTests 173→182, AccountTests 15, OnlineTests 126, root 53, xcodebuild BUILD SUCCEEDED. Anon key absent from every commit; `supabase/**` byte-identical to `6c49764`.

**AMENDMENT REQUEST (reported, not fixed — `supabase/migrations/**` is protected):** `respondToFriendRequest(accept: false)` sets `status = blocked` in both `FakeBackend` and `rls_behavior.sql`, and no seam call unblocks. **Declining a request therefore permanently blocks the person.** This needs either an unblock seam call or a `declined` status distinct from `blocked`, via `/foundation`.

**Two caveats for a human:** `profilesAreReadTogether` polls `Gate.arrivalCount` with a 2 s ceiling — the one timing-dependent case in the suite. And the profile cache never expires within a screen visit, so a name changed elsewhere mid-visit shows stale; bounded, because `ShellModel` builds and tears down a `FriendsModel` per visit.

**Contract for later items:**
```
AppRoute.friends · ShellModel.friends: FriendsModel? · showFriends() — menu action
  "Friends", enabled when currentProfile != nil; torn down in returnToMenu()
  before the route moves.
FriendsModel publishes three sections (accepted / incoming pending / outgoing
  pending), resolves each counterpart through profile(id:), and writes only
  through respondToFriendRequest(requesterID:accept:) and block(_:) — no
  client-side status arithmetic. Blocked players are hidden from every section.
FriendsView holds no route; onward actions are closures. Item 9 adds lookup by
  code and opens ProfileModel(profile:isEditable: false) from a row.
```

### Item 9 — Add a friend by code, and open a friend's profile (`08e3490`, 1 attempt, engineer-only + 7 orchestrator mutation checks)

**The first item in this lane where no check stayed green under mutation** — 7 independent orchestrator mutations on top of the engineer's 14, all caught, all restored byte-identical per `diff -q`. Two of the three `done when:` criteria were refusals ("cannot request themself", "makes no backend call"), which look identical to a clean run once they stop firing, so a green suite alone would have proved nothing about them.

- **The pattern that made the refusals provable: every "refuses / makes no call" assertion is paired with a positive test asserting the same recorder is non-empty**, so the recorder itself cannot silently stop recording. Mutation MY-3 neutered `GatedBackend.friendCodeLookups.append` and turned the positive cases red, which is what proves the `.isEmpty` no-call assertions are load-bearing rather than vacuous.
- **`FriendsModel.init` takes the whole `Profile`, not `me: UUID`.** The own-code refusal is impossible without the code client-side; 21 test call sites was the cheap price.
- **Scoping a source fence to one `@ViewBuilder private var` body** via a `body(of:in:)` helper, with `#require` on the property being found, caught both a wiring change (MY-6) and a rename (MY-7). This is the corrected form of item 8's whole-file grep.
- **`ProfileView` reused unchanged**, no new View file, so no `exclude:` change. Back-destination is carried by a private `profileReturn: AppRoute` on `ShellModel` plus `dismissProfile()`, not by the view.
- **`ProfileRouteTests.rootRendersTheScreen` legitimately went red** because it asserted the old `returnToMenu()` wiring; it was updated to `dismissProfile()` rather than weakened.
- **Counts:** ShellTests 182→188, FriendsTests 29→41 (live gate on), AccountTests 15, root 53, xcodebuild BUILD SUCCEEDED. Verified independently at the merge commit. One ShellTests run failed with a single issue and three subsequent runs passed at 188 — consistent with the wall-clock flakiness this file already documents for the countdown overlay case, not a regression from this item.
- **Bookkeeping note:** the agent committed its team-memory entry to `.claude/dev-team/team-memory.md` (`da55379`). Lane mode forbids that on a lane branch — `/merge-lane` appends from this PR body in merge order, and a shared file written per-lane conflicts on every merge. Reverted in `2cafdb6`; the entry lives here instead.

**Still open, deliberately not fixed here (both belong elsewhere):**
- `respondToFriendRequest(accept: false)` still sets `blocked` with no unblock seam call, so **a declined player can never be re-added by code.** The `.blocked` copy is an honest dead end until the filed `/foundation` amendment lands.
- **A read-only profile still offers Copy/Share of the *friend's* friend code**, because `ProfileView` gates copy on nothing but the button existing. That fix belongs in `Willagrams/Account`, not the shell.

### Item 10 — Invite a friend to play, in-app (`0c30d05` → `915e14a` → `77b6ae6` → `7894b1e`, 3 attempts, **`caution: true`** — full engineer + QA + review team)

QA VERDICT **PASS** at attempt 3, gate mode `tests+behavioral`. Review ran three times and ended **0 Critical / 0 Important**. Attempt 1 passed QA but review found 4 Important; attempt 2 closed those and introduced 2 new ones; attempt 3 closed those. **A fix pass is a new diff and needs a real re-review, not a rubber stamp** — that is what caught the second round.

- **A recipient-side trust check is where the real security lives on a broadcast feature.** The "only accepted friends can invite you" guardrail was enforced only on the *sender's* client until review caught it; a sender's client is not a trust boundary. It is now checked on receipt.
- **QA disproved the engineer's own mutation claim.** The engineer reported the `.accepted` half of the sender check as covered; QA re-derived it and showed the stranger test *structurally cannot* isolate the status predicate, because a stranger has no friendship row at all. QA added the missing pending-sender test. **Making QA re-derive rather than accept engineer mutation claims is what earned this item its coverage.**
- **The clock is injected.** `sentAt` staleness uses an injected `now`/`sleepFor`, never a real clock, so the two-minute expiry case is deterministic.
- **Telling the engineer up front that `Tests/ShellTests/Package.swift` lists Online files by name** decided the whole file layout at zero rediscovery cost: `MatchInvite` + an SDK-free channel protocol + `FakeInviteBus` in one file listed by name, and `SupabaseMatchInviteChannel` (Realtime) in a second file only the whole-directory packages compile.
- **Counts (verified independently at `7894b1e`):** ShellTests 188→**207**, OnlineTests 126→**132** (offline and live), FriendsTests 41→**43** live, AccountTests 15, root 53, xcodebuild BUILD SUCCEEDED. `supabase/migrations/**`, `BackendContracts.swift` and `team-memory.md` all untouched, confirmed by name in the diff. No key in any commit.

**⚠️ Criterion 4 is UNRUN, not met.** "Live, on two simulators: A taps Invite, B's banner appears, B joins, A starts, both reach the match screen" **was not executed.** This repo has no XCUITest target and `simctl` has no tap primitive, so no agent here can tap a button on a simulator. What *is* live-proven is the transport half: `MatchInviteChannelLiveTests` runs two real users against the live project and delivers an invite in ~1.1 s against the 5 s budget. **A's real tap, B's banner on device, and both reaching the match screen remain unverified and are a manual check a human owes before ship.**

This also casts doubt on how items 3 and 4 recorded their own two-simulator criteria. Those were reported as live-proven end to end, and the transport work plainly was; whether the on-device tap-through was ever actually performed is not something this run can now confirm. **Recorded as an open question rather than resolved in either direction.** The durable fix is either an XCUITest target, or writing such criteria as "a live transport test plus a named manual check" instead of as something an agent can claim.

**⚠️ SECURITY — needs a `/foundation` amendment, could not be fixed here.** Supabase Realtime broadcast channels are **public by default**. Invite topics are named for the recipient's user id, so anyone who resolves a friend code to a UUID can subscribe with the shipped anon key and read live `inviteCode`s — and join that lobby ahead of the invited friend. Spoofing is shut by the new recipient-side check; **eavesdropping is not.** The real fix is `config.isPrivate` **plus** a `realtime.messages` policy — `isPrivate` alone breaks the channel outright — and that policy is a migration, which this item's own guardrail forbids. **Any lane item that forbids migrations cannot fully secure a broadcast topic; the migration has to be planned in the same round.**

**Contract for later items:**
```
MatchInvite(matchID, inviteCode, hostID, hostName, sentAt) + an SDK-free channel
  protocol + FakeInviteBus — one file, listed by name in Tests/ShellTests/Package.swift.
SupabaseMatchInviteChannel — Realtime; only whole-directory packages compile it.
ShellModel — an invite pump, a banner with injected now/sleepFor, and a
  recipient-side accepted-friend gate. At most one banner per matchID.
Invite code is 6 chars; the friend code is 8. Do not conflate them.
```

### Item 11 — give every sound cue a call site

**A default value on an injected dependency converts a wiring regression from a
compile error into a silently-green one.** When a seam is injected, make the
parameter REQUIRED and pay the mechanical call-site churn (15 sites here, all in
tests) rather than covering it with a test. Also: at least one test per feature
must build the object graph the way production builds it, not by hand; per-model
tests prove the mapping and miss the wiring.

This was found by mutation check M10, the most serious find of the run.
`MatchBoard.init` and `MatchHUDModel.init` each carried
`audio: any AudioPlayer = SilentAudioPlayer()`, so deleting both `audio:`
arguments from `MatchRun` **muted the entire shipping match while all 216 tests
passed** — every cue test built its models by hand, so nothing covered the
production assembly. Fixed structurally: the defaults were removed, making it a
compile error, and `aRealRunIsWiredToTheShellsPlayer` was added driving a real
`MatchRun`.

The same shape survived one seam further out and was closed during verification.
`ShellServices.init` still defaults `audio:` (load-bearing —
`ShellModel.init` takes `services: ShellServices = ShellServices()`), and the
existing fence asserted only that `WillagramsApp.swift` *constructs* a
`SystemAudioPlayer`, not that it *hands it over*. Deleting `audio: audio` at the
root shipped a silent app with 218 green. `ServiceFenceTests.theRootInjectsItsPlayer`
now asserts the argument itself; mutation-checked RED.

Where the cues live — each fired from the model that owns the moment, never a
view, and never wrapped in a `Task`:

```
countdownTick   ShellModel's countdown re-arm
draw/swap/invalid   MatchHUDModel
win/loss + impact(.medium)   ShellModel.matchEnded
menuTap   six menu actions, AFTER their guards
tilePlace/tileRecall   MatchBoard.mirror()
```

Disclosed survivor, kept deliberately: `ShellModel:932`'s
`card.secondsRemaining != lastTick` guard. No test can drive it in either
direction.

### Item 12 — the mute control

`ShellServices` gained `audioSettings`, defaulted to `AudioSettings(defaults: .standard)`.
That default is production-correct rather than a hidden seam — the root already
uses that suite — but it means **any future test that asserts on mute MUST inject
a named `UserDefaults(suiteName:)` and `removePersistentDomain` it**, or it reads
and writes the test host's real preferences.

`ShellModel.setMuted(_:)` is the sole funnel: settings write, then player write,
then the `.menuTap` cue. `toggleMute()` delegates to it. The only two `setMuted`
call sites in `Willagrams/**` are that adjacent pair, so no path sets one without
the other. `isMuted` is seeded from `services.audioSettings.isMuted` *before* the
`guard let signIn` early return.

`MenuView` is SwiftUI and therefore excluded from ShellTests, so the only
coverage of the toggle actually being on the menu is the scoped source scan
`ServiceFenceTests.theMenuCarriesTheMuteToggle`. Keep it in sync if the labels or
the method name change.

Mute is sound only. Suppressing haptics while muted is the concrete player's own
behavior, documented in the protected `AudioPlayer` protocol; the one
`services.audio.impact(.medium)` in `ShellModel` is item 11's win haptic and is
untouched.

---

## Known risks not covered by the criteria

1. **Silent lobby-abandon failures** — `OnlineMatch.abandonTask` discards the
   result with `try?`. A network blip while cancelling a lobby can leave a
   `matches` row stuck in `lobby` indefinitely, with nothing surfaced and no
   retry.
2. **Realtime invite topics are public** (filed via `/foundation`, needs a
   migration this lane was forbidden to make) — anyone who resolves a friend
   code to a UUID can subscribe with the shipped anon key and read live invite
   codes. Spoofing is shut by the recipient-side check; eavesdropping is not.
   The fix needs `config.isPrivate` **plus** a `realtime.messages` policy —
   `isPrivate` alone breaks the channel.
3. **Declining a friend request blocks permanently** with no undo (filed).

## Disclosed mutation survivor

`ShellModel:932`'s `card.secondsRemaining != lastTick` guard. No test can drive
it in either direction; kept deliberately rather than covered with a vacuous
test.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01BBbKTHe1pVkpgTvdunykC3
