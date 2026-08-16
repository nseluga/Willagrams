Autonomous `/dev-team-auto` run of the **match lane**. All five items above the
`⚠️ AUTONOMOUS RUN — STOP HERE` marker are done; items 6-8 need two physical iOS
devices and two Game Center accounts and were not attempted.

`/merge-lane` owns everything downstream of this PR. The item worktrees are left
in place per lane mode.

## What landed

| # | Item | In plain terms |
|---|------|----------------|
| 1 | Transport seam (`MatchTransport` + `FakeTransport`) | One agreed way for two devices to pass messages, plus a stand-in that lets the whole match be tested on one machine with no second device and no Game Center account. |
| 2 | Wire codec (`MatchCodec`) | Messages turn into bytes and back, and a match from an app version speaking a different wire format is refused instead of played. |
| 3 | Host authority over the pool (`HostPool`) | One device owns the real tile pool and answers both players from it, so a draw gives each player exactly one tile and a swap with too few tiles left is refused without disturbing the pool. |
| 4 | Client state machine (`MatchSession`) | The match runs on each player's device: counts down to the start, applies tiles as they arrive, and holds the opponent's drawn tile until the player presses Draw. |
| 5 | Terminal states | A match can end: win or resign, both devices agree who won; a dropped opponent locks the board and runs a countdown; if they never return the match ends naming nobody. |

## Test results

- Match package (`swift test --package-path Tests/MatchTests`): **100 tests / 18 suites**, green
- Root (`swift test`): **36 tests / 6 suites**, green
- Item 5 verified at 10 consecutive green runs by its orchestrator, plus 6 more; both gates re-run on the merged lane tip by the session.

This repo is **mixed-runner** — `BoardTests` is XCTest, the Match and Style packages are swift-testing. Neither runner's output line alone is a safe gate anchor, and a runner-detection grep only describes the branch you are standing on.

## Carried findings — for item 7, needs real devices

Both belong to `GKMatchTransport.swift`:

1. The wire version gate only binds callers going through `MatchCodec.decode`. The GameKit adapter must be the **sole** reader of peer bytes and must call `decode` exclusively — any second path around it silently skips the version check.
2. No payload size or nesting-depth cap before `JSONDecoder`. A hostile or corrupt peer payload decodes unbounded. The codec's 16KB limit bounds `winningPlacements` in practice, but the cap is not enforced at the decoder.

## Latent toolchain landmine

Adding a stored `MatchMessage?` field to `MatchSession` — even an unused `@ObservationIgnored` one — aborts the Match suite with `swift_task_dealloc` "freed pointer was not the last allocation" (signal 6) inside `peerDropped()`'s reconnect task, 3/3 reproducible. `Int`/`Bool`/`PlayerID?`/`[Tile]`/`[Placement]` are fine, and the same field *without* `@ObservationIgnored` is fine. It is layout-sensitive, so an unrelated future edit to this class can re-detonate it. Current code works around it by holding a `Bool` and rebuilding the message from `winner`/`winningPlacements`.

## `integration` rewind — declined, on purpose

`7485e0a` (the Match test harness) landed on `integration` one step earlier than
intended. I did not rewind it: it is an ancestor of `lane/match` so `/merge-lane`
fast-forwards cleanly over it, `lane/board` forked before it and is uncontaminated,
and the content belongs in the project regardless. Mutating a shared branch tip is
riskier than the cosmetic gain.

Note: `integration` did not exist on the remote before this PR; it was pushed at
`7485e0a` to serve as the base.

## Deferred

The reviewer's Minor on `winningPlacements` validation — already bounded by the
16KB codec limit; dedupe belongs at the consumer when the end screen lands in the
shell lane.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
