# Delta Review — item 1 (ba7182d..3351b6a)
**Scope:** 7 files in `git diff ba7182d..3351b6a`. No re-review of the item.
**Dimensions:** efficiency — clean · scalability — clean · reliability — 1 · fault tolerance — 1 · security — clean · lane scope — clean · over-engineering — 2 (non-gating)

## Deviations — verdict
1. weak `shell` — SOUND. Only consumer of `results()` in `Willagrams/` is none (routes are placeholders); every test site uses `try #require` or `?.x == expected`, so nil fails rather than passes. Both weak uses (`MatchRun.results` guard, `MatchHUDModel.confirmResign`) are only nil while the shell is deallocating.
2. `generation` bump site — CLAIM VERIFIED. `ResultsModel.swift:178` runs `teardown?()` before `start()`, and the closure's `isLiveGeneration` check is at `MatchRun.swift:136`, i.e. after teardown. A bump in `endSoloPractice()` would decline every rematch. `returnToMenu()` covers both real exits (`ResultsModel.mainMenu` → `returnToMenu`; a direct start → `returnToMenu`), so no reachable path leaves a live-generation screen over a nil run.
3. route guard — SOUND. Cannot refuse a legitimate rematch (teardown always nils `run` first, so `.countdown`/`.match` arrivals hit `run == nil`); cannot admit a leaking start (`returnToMenu()` still runs before construction on every admitted path). Release no-op returns before any mutation — no half-built state.

## Findings

### Important
- `Willagrams/Shell/ShellModel.swift:44-50` — fault tolerance — `loadedDictionary()` memoizes whatever the closure returned, including the `?? EnableWordList(words: [])` fallback at line 62; a one-off bundle-read failure used to be retried on the next match and is now cached for the process lifetime, making every match of the session unwinnable — fix: cache only a non-fallback load (return the fallback without assigning `cachedDictionary`), or add the `assertionFailure` the prior Minor offered.

### Minor
- `Willagrams/Shell/MatchHUDModel.swift:210-216` — reliability — `confirmResign()` returns `true` after `shell?.matchEnded(...)` silently no-ops on a nil shell, so a caller is told the screen advanced when it did not — fix: `return shell != nil` or document the return as "the session resigned", not "the match ended".
- `Willagrams/Shell/ShellModel.swift:33-37,134,157` — reliability — `generation` now increments twice per start (`returnToMenu()` plus the explicit bump), so the doc "Counts matches started" is false; harmless because only equality is read, but it misleads the next reader — fix: reword the doc to "a monotonic token, not a count".
- `Willagrams/Shell/MenuView.swift:34` — fault tolerance — in Release the button discards the new `false` and gives no feedback, so the soft-lock became a dead control — fix: fence the button with `#if DEBUG` (the prior review's alternative), or leave with a one-line comment pointing at item 3.
- `Willagrams/Shell/ShellModel.swift:44` — reliability — the cache is never invalidated, so once the injected closure becomes settings-backed (`Willagrams/Settings/Model/DictionaryCatalogue.swift:8` already models a chooser) a mid-session dictionary change will not take effect — fix: nothing now; note the invalidation point when the closure is wired to settings.

### Over-Engineering (non-gating)
- `Willagrams/Shell/ShellModel.swift:44-50` — a 6-line `loadedDictionary()` for a one-shot memo; `cachedDictionary ?? { let l = dictionary(); cachedDictionary = l; return l }()` inlined at the single call site is the same behavior in two lines.
- `Willagrams/Shell/ShellModel.swift:101-110,120-125,199-204` — the delta added ~22 lines of prose defending three ~4-line changes; the engineer report already records the reasoning.

## STANDARDS.md Updates
none — scoped re-review.
