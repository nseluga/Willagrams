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
| online | nate | — | not started, and **unblocked at the database and the SDK**. `0001_init.sql` and `0002_participant_lookup.sql` are applied to project `ynkayuwwrifluhhqnrjc`; both SQL fixtures pass, twice, in either order. `Willagrams.xcodeproj` already references `supabase-swift` with the Auth, PostgREST and Realtime products, so no dependency work is left. **One decision is owed before the lane starts: where the project URL and anon key live.** Neither string exists anywhere in the repo, so no client can be constructed. Constants under `Willagrams/Online/**` are lane-owned and need no amendment; an Info.plist or xcconfig route touches `Willagrams.xcodeproj/**`, which is `unowned:` and a Reviewer call. The anon key shipping inside the binary is intended, not a leak — RLS is what protects the rows, and RLS is now verified rather than assumed. Sign in with Apple is postponed (`FOUNDATION.md`), so the concrete `signInWithApple` on the real client sits **below the stop marker**; every other call is reachable and testable |
| account | nate | — | not started — sequenced behind online, and **partly gated by the postponed Apple Developer membership** (`FOUNDATION.md`, 2026-08-25). The profile page, display-name editing and the stats need only a user id and are fully buildable against `FakeBackend`. The Sign in with Apple screen may be written but cannot be exercised: `com.apple.developer.applesignin` is absent from `Willagrams.entitlements` and stays absent this round. That item belongs **below the stop marker**. **`Tests/AccountTests/` does not exist** — every other lane had its package scaffolded by `/foundation` and this one did not, so the lane's first item creates it. Read MAP's symlink-hazard section before laying it out |
| friends | nate | — | not started — sequenced behind online. **Unaffected by the Apple membership postponement.** Build against the real database, not `FakeBackend`: RLS refuses a read by returning zero rows rather than an error, and the fake enforces no policies, so a fake-green lane can still render an empty friends page in production. `rls_behavior.sql` is the fixture that proves a policy returns; extend it rather than trusting the fake. **`Tests/FriendsTests/` does not exist** — same as `account`, the lane scaffolds its own package |
| bot | nate | lane/bot | round 2 done — octopus-merged 2026-08-20 `0e25124`, items 1–6 at `457e20f`; archive `progress/bot.md` + `progress/bot-lane-plan.md`; BotTests 0 → 63 |
| audio | nate | lane/audio | **round 2 done** — merged 2026-09-01 via /merge-lane, PR #2, 4 items; archive `progress/audio.md` + `progress/audio-lane-plan.md`; AudioTests 6 → 19. Ships `AudioCatalogue` (all nine `SoundEffect` cases, `default:`-free), `AudioSettings` (persisted `audio.muted`), and `SystemAudioPlayer` (`.ambient` session so the physical silent switch always wins, 3-voice pool per asset, haptics warmed on the main actor, sound delays read live from `DesignTokens.Motion`). **Two things stay open.** No audio assets exist in the bundle, so every cue is a silent no-op until sound files land. And the seam is still `unwired:` — nothing constructs `SystemAudioPlayer` and nothing reads `AudioSettings`; that is **shell round 3** (player construction) and **settings** (the mute control), exactly as MAP's "Decided" section scoped it. `caution: true` on `SystemAudioPlayer` is unretired: the Taptic buzz and the physical silent switch were proved only by simulator proxy |
| launch | nate | — | **blocked, and it is the lane the Apple membership postponement actually stops.** App Store submission needs the paid membership, so store metadata, screenshots, App Review notes and the pre-submission audit stay parked. The privacy policy and the account-deletion checklist are writable now. Runs last regardless, after the tuning pass |

Detail lives in `progress/<lane>.md`, archived per merge. This file stays one
line per lane.

## Crossings — work that landed outside a lane round

| Date | What | Where |
|------|------|-------|
| 2026-08-20 | Solo setup screen (`Shell/SoloSetup.swift` + view) and the crossword wordmark (`Shell/Wordmark.swift` + view), plus refinements across ShellModel, SoloMatch, BotMatch, MatchHUD, BoardView. **This closed the Release fence** — `startSoloPractice` is no longer `#if DEBUG`, because `SoloMatch` now runs on a shipping `LocalMatchLink` against a real `BotMatch`. ShellTests 99 → 117. | Committed `54381fb`, merged to `main` `d1a8882` on 2026-08-24. Done directly in the integration worktree, not on a lane branch. |
| 2026-08-24 | Draw and bot retiming, and the coverage hole it left. `MatchBoard.sync()` deliberately does **not** guard on `hasPendingDraw` — Draw hands over one waiting tile per press, so a guard there would make a press with more tiles still queued do nothing and then land the whole queue at once. The obligation lives in `mirror()` instead. A ShellTests case now holds that open: it presses Draw three times with a queue behind it and asserts each press lays its own tile. Verified by mutation — putting the guard back makes it fail. ShellTests 117 → 125, MatchTests 124 → 125, BotTests 63 → 68. | Pushed to `origin/main` at `a25260f`. |
| 2026-08-24 | `supabase/tests/rls_behavior.sql` — what the row level security policies actually **return**, per reader. `schema_invariants.sql` only asserts that each table has RLS on and carries at least one policy, which cannot catch a policy that is enabled and wrong. A refused read is zero rows and a refused write is zero rows affected, never an error, so a wrong policy renders an empty friends page instead of failing. **Written but never run** — the migration is not applied to the project yet, so nothing has executed it. | Uncommitted in the integration worktree. Not a lane: it tests the frozen schema, which no lane owns. |
| 2026-08-24 | **The RLS fixture found a real bug in the frozen schema on its first real run.** `matches_select_participants` read `match_players`, whose policy read `matches`, whose policy read `match_players`; and `match_players_select_same_match` read `match_players` to decide whether a `match_players` row was visible. Postgres answered `infinite recursion detected in policy for relation "match_players"` and refused the read — so **no player could open a match at all, host included**. `schema_invariants.sql` passes on the broken schema: RLS is on and every table carries a policy, and both are true of a policy that can never return. `supabase/migrations/0002_participant_lookup.sql` cuts the circle with a `security definer` function, `public.is_match_participant(uuid)`, which runs as owner and so is not subject to the policies it is answering for. **No `/foundation` amendment:** `FOUNDATION.md:227` states these policies semantically — "`matches` selectable by its host or any row in `match_players`" — and 0002 preserves that wording exactly. No table, column or constraint moves. | Applied to `ynkayuwwrifluhhqnrjc`. All 21 `rls_behavior.sql` assertions pass. |
| 2026-08-24 | Both SQL fixtures made re-runnable. `rls_behavior.sql` used `on conflict do nothing` on its seed, so when `schema_invariants.sql` left a match holding the same invite code behind, the seed skipped in silence and the first assertion failed on a foreign key instead of on a policy — the same silent-skip disease the file exists to name. It now clears its own rows, inserts without the clause, and cleans up after. `schema_invariants.sql` had the mirror problem: it seeded `auth.users` with no on-conflict and deliberately leaves Ada and Grace standing, so a second run died on a duplicate key before asserting anything. It now clears first too. | Both pass twice, in either order, against the live project. |
| 2026-08-25 | Map and foundation refresh before the last lanes. `0002_participant_lookup.sql` entered the `FOUNDATION.md` amendment log — it had landed as a Reviewer fix and existed only as a crossing row here, which left the amendment log no longer the record of the schema. **Sign in with Apple postponed** on the paid Apple Developer membership, written up per lane: `online` and `account` keep a stop marker over their sign-in items, `friends` is unaffected, `launch` is the lane it actually stops. MAP gained "Decided — what the `audio` lane is and is not": the seam's missing call sites are shell's, mute is sound-only, the mute control is settings'. | `MAP.md`, `MAP_PROGRESS.md`, `FOUNDATION.md`. Reviewer pass, not a lane. |

Suite at `a25260f`: **719 tests, nine packages** — rules 53 · Board 250 ·
Match 125 · Style 30 · Shell 125 · Settings 36 · Audio 6 · Online 26 · Bot 68.
Counted by running every package, not carried forward — an earlier handoff
reported 720 and the real number was 718.

**Open, needs a decision:** the Supabase project URL and anon key have no home
in the repo, and `online` cannot construct a client without one. Lane-owned
constants or a Reviewer-owned Info.plist/xcconfig — see the `online` row.

**Also open:** `Willagrams/Shell/**` needs a **round 3** for the audio call
sites. `AudioPlayer` has none, and the wiring crosses shell, match and board.
Shell's `depends on:` already carries the edge, so this is an item list, not an
amendment.

**Open, needs a decision:** `design/visual-pass-r1` carries 17 unmerged commits
and its own `Willagrams/Style/WordmarkTiles.swift`, a second implementation of
the crossword wordmark that `Shell/Wordmark.swift` now also provides. Merging
that branch without reconciling the two leaves the repo with two wordmarks.

