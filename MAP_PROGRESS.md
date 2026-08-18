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
| shell | nate | lane/shell | round 1 done — merged 2026-08-17 `ec9d186`, items 1–11; no archive; round 2 not started (placeholder routes + board-commit bridge) |
| online | nate | — | not started — blocked on /foundation (schema) and a live Supabase project |
| account | nate | — | not started — blocked on online, and on the Apple Developer membership |
| friends | nate | — | not started — blocked on online and account |
| bot | nate | lane/bot | not started — branch cut at `8f3a4da`, no items |
| audio | nate | — | not started — blocked on /foundation (playback seam) |
| launch | nate | — | not started — runs last, after the tuning pass |

Detail lives in `progress/<lane>.md`, archived per merge. This file stays one
line per lane.
