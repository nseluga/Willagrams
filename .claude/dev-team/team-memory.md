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
