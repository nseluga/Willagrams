# Fix Report — attempt #2, after orchestrator adjudication
**Date:** 2026-08-19 · **Branch:** item/shell-r2-matchrun · **Worktree:** `willagrams-wt/shell2run/Willagrams`
**Note:** my worktree `willagrams-wt/shell2-item1` was deleted mid-pass by another process; its committed content is on the branch, and the adjudicated corrections are present in `shell2run`. Nothing committed by me.

## Findings, as adjudicated
- Finding 1 (dictionary) — APPLIED. `ShellModel.loadedDictionary()` memoizes the injected closure, so a rematch reuses the ~172k-entry Set. A degraded (empty) list is deliberately *not* cached, so a bad bundle read is retried next match.
- Finding 2 (cycle) — APPLIED with `unowned let` on BOTH edges: `MatchRun.shell` and `MatchHUDModel.shell`. `results(board:)` is back to non-optional `ResultsModel`; the escaping closures inside it keep `[weak shell]`.
- Finding 3 (route guard) — DECLINED per adjudication. The `case .menu, .results` guard is gone; `startSoloPractice` bounces through `returnToMenu()` unconditionally. `RematchTests.aDirectRestartStillTearsTheOldMatchDown` and `MatchRunTests.aSecondStartReplacesTheRun` are restored to their baseline names, prose and assertions.
- Finding 4 (Release soft-lock) — APPLIED. `#if !DEBUG return false` fences the whole method: Release never advances the route.
- Minor (generation bump) — applied in `returnToMenu()`, not `endSoloPractice()`; the prescribed site would make `ResultsModel.rematch()` decline itself, since teardown runs first.

## Gate (run in `shell2run/Willagrams`, stale `.build` caches cleared first)
| package | result | floor |
|---|---|---|
| `.` | 53 pass | 53 |
| BoardTests | Executed 248, 0 failures | 248 |
| MatchTests | 124 pass | 124 |
| StyleTests | 30 pass | 30 |
| ShellTests | **75 pass** | 72 |
| SettingsTests | 36 pass | 36 |
| AudioTests | 6 pass | 6 |
| OnlineTests | 26 pass | 26 |
| **total** | **598** | 595 |

`xcodebuild -scheme Willagrams -destination 'generic/platform=iOS Simulator' build` — BUILD SUCCEEDED in Debug and Release. No test deleted, trimmed or weakened; `QAMatchRunTests.swift` untouched apart from matching the non-optional `results()`.
