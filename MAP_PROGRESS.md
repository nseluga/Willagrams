# Willagrams — Lane Progress

One row per lane in `MAP.md`. Written during a merge by `/merge-lane`.

**This file was reconstructed from git history on 2026-08-18.** `/merge-lane`
had never run to completion in this repo — it requires a pushed branch and an
open PR, and nothing has been pushed. Round-1 lanes landed through
`/octopus-merge`; `shell` and `settings` landed through bare `git merge`. Item
counts come from the `progress/<lane>.md` archives; lanes without an archive
are counted from their merge commit message.

| Lane | Assignee | Branch | Status |
|------|----------|--------|--------|
| style | nate | lane/style | done — merged 2026-08-14 `6836bc4`, 9 items, archived `progress/style.md` |
| board | nate | lane/board | done — merged 2026-08-15 `22d6c22` via /octopus-merge, 10 items, archived `progress/board.md` |
| match | nate | lane/match | done — merged 2026-08-15 `22d6c22` via /octopus-merge, 10 items, archived `progress/match.md`; reopens for the wire v3 amendment |
| settings | nate | lane/settings | done — merged 2026-08-17 `68cb22d`; no archive, /merge-lane was skipped |
| shell | nate | lane/shell-r2 | round 2 done — octopus-merged 2026-08-20 `0e25124`, items 1–7; archive `progress/shell.md` + `progress/shell-lane-plan.md`; ShellTests 61 → 99. Round 1 merged 2026-08-17 `ec9d186`, items 1–11 |
| online | nate | — | not started — the schema and the `BackendClient` seam are frozen and done. Needs a live Supabase project, plus a `/foundation` amendment adding a sign-in method that is not Sign in with Apple — `signInWithApple` is currently the protocol's only route to a session |
| account | nate | — | not started — sequenced behind online. The profile page and stats need no Apple membership; only the Sign in with Apple item does, and it belongs below the stop marker |
| friends | nate | — | not started — sequenced behind online. Build against the real database, not `FakeBackend`: RLS refuses a read by returning zero rows rather than an error, and the fake enforces no policies, so a fake-green lane can still render an empty friends page in production |
| bot | nate | lane/bot | round 2 done — octopus-merged 2026-08-20 `0e25124`, items 1–6 at `457e20f`; archive `progress/bot.md` + `progress/bot-lane-plan.md`; BotTests 0 → 63 |
| audio | nate | — | not started, and **no longer blocked** — the playback seam landed in `/foundation` as `Willagrams/Audio/AudioPlayer.swift` (`protected:`) with `Tests/AudioTests/` scaffolded at 6 tests. Depends only on style, which merged. Runnable at any time |
| launch | nate | — | not started — runs last, after the tuning pass |

Detail lives in `progress/<lane>.md`, archived per merge. This file stays one
line per lane.

## Crossings — work that landed outside a lane round

| Date | What | Where |
|------|------|-------|
| 2026-08-20 | Solo setup screen (`Shell/SoloSetup.swift` + view) and the crossword wordmark (`Shell/Wordmark.swift` + view), plus refinements across ShellModel, SoloMatch, BotMatch, MatchHUD, BoardView. **This closed the Release fence** — `startSoloPractice` is no longer `#if DEBUG`, because `SoloMatch` now runs on a shipping `LocalMatchLink` against a real `BotMatch`. ShellTests 99 → 117. | Committed `54381fb`, merged to `main` `d1a8882` on 2026-08-24. Done directly in the integration worktree, not on a lane branch. |

Suite at `d1a8882`: **699 tests, nine packages** — rules 53 · Board 250 ·
Match 124 · Style 30 · Shell 117 · Settings 36 · Audio 6 · Online 26 · Bot 63.

**Open, needs a decision:** `design/visual-pass-r1` carries 17 unmerged commits
and its own `Willagrams/Style/WordmarkTiles.swift`, a second implementation of
the crossword wordmark that `Shell/Wordmark.swift` now also provides. Merging
that branch without reconciling the two leaves the repo with two wordmarks.

