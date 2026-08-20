# Fix Report — attempt #2
**Date:** 2026-08-19 · **Branch:** item/shell-r2-matchrun (not committed)
**Findings addressed:** 5 of 5 (4 Important + 1 Minor, the Minor applied at a different site — see Disputed)

## Changes Made
- `ShellModel.swift:39-49,~150` — Important/efficiency — added `cachedDictionary` + `loadedDictionary()`; the injected closure now runs on the first match only, so a rematch reuses the ~172k-entry Set instead of rebuilding it on the MainActor.
- `MatchHUDModel.swift:59,209` — Important/reliability — `shell` is now `weak var`; `confirmResign()` uses `shell?.matchEnded(...)` and still returns whether the session resigned.
- `MatchRun.swift:81,120` — Important/reliability — `shell` is now `weak var` too (otherwise `ShellModel → run → MatchRun → shell` is still a cycle); `results(board:)` consequently returns `ResultsModel?`.
- `ShellModel.swift:~118` — Important/reliability — added `switch route { case .menu, .results: break; default: if run != nil { return false } }` before `returnToMenu()`. A start from inside a live `.countdown`/`.match` is refused again; teardown-before-construction is unchanged.
- `ShellModel.swift:~112` — Important/fault-tolerance — `#if !DEBUG return false #endif` at the top of `startSoloPractice`. Release never advances the route, so the menu's button is inert rather than a soft-lock. Release `xcodebuild` green.
- `ShellModel.swift:~180` — Minor/reliability — `generation &+= 1` added to `returnToMenu()` (not `endSoloPractice()`, see Disputed), so an end screen goes stale once the app reaches the menu.
- `MatchRunTests.swift` — 2 new tests: word list built once across a rematch; a shell dropped mid-match releases itself, its run, session and HUD. 72 → 74.
- `MatchRunTests.swift` / `RematchTests.swift` — the two tests that pinned the unconditional bounce re-expressed against the new guard: the restart from inside a live match is now asserted *refused and inert*, then asserted to succeed via the menu. No assertion dropped; both gained two.
- `QAMatchRunTests.swift` — 3 lines only, `results()` → `results()?` for the new optional return. No QA test deleted, trimmed, or weakened.

## Disputed
- Minor as prescribed (`generation &+= 1` inside `endSoloPractice()`) breaks rematch outright: `ResultsModel.rematch()` runs `teardown` — which calls `endSoloPractice()` — *before* the rematch closure's `isLiveGeneration` check, so every rematch would decline itself. Applied in `returnToMenu()` instead, which is the actual "this screen can never be live again" event and leaves the teardown-then-build path intact.
- Reviewer's "no test pins the unconditional bounce" held for `QAMatchRunTests` but not for `RematchTests.aDirectRestartStillTearsTheOldMatchDown` / `MatchRunTests.aSecondStartReplacesTheRun`. Both updated as above.
- The literal `default: return false` would also refuse `ResultsModel.rematch()`, which arrives on whatever route its screen was built over (`.countdown` in most tests). Guard admits `run == nil` for that reason — a caller that has already torn the run down cannot be the stray tap the guard exists to stop.

## Not actioned (per instruction)
Over-Engineering findings: `QAMatchRunTests.swift` untouched; `MatchRun` prose left as written.

## Gate
| package | result | floor |
|---|---|---|
| `.` | 53 pass | 53 |
| BoardTests | Executed 248, 0 failures | 248 |
| MatchTests | 124 pass | 124 |
| StyleTests | 30 pass | 30 |
| ShellTests | **74 pass** | 72 |
| SettingsTests | 36 pass | 36 |
| AudioTests | 6 pass | 6 |
| OnlineTests | 26 pass | 26 |
| **total** | **597** | 595 |

`xcodebuild -scheme Willagrams -destination 'generic/platform=iOS Simulator' build` — BUILD SUCCEEDED, Debug and Release. MatchTests/SettingsTests/OnlineTests run via the rsync-to-`Willagrams` workaround.
