# Willagrams — polish / final lane progress

LANE.md is the contract; this tracks where we are in it. If they disagree, LANE.md wins for scope.

## Current position

- **Status:** round 3 (2026-09-15) — the hand-test round. Nate installed the build on his real iPhone 13 mini and iPad Air and played it for the first time; he found eight functional bugs and four visual breakages. Round 2's shutdown sequence has now been run and closed out (see below), so `lane/final` is at `4fa9b70` and `auto/final` is level with it. Twelve round-3 items are written into `LANE.md`, none started
- **Round 2's shutdown sequence — run and green (2026-09-15):** full serial suite at or above every floor; `xcodebuild` BUILD SUCCEEDED; `scripts/scratch-verify.sh` green (6 migrations, 55 assertions, 0 leftover rows); lane acceptance `dt-review` returned MET on all three round-2 criteria; `auto/final` merged into `lane/final` as a clean fast-forward to `4fa9b70`
- **A reproducible iPad launch crash was found after that merge, and it changes round 2's criterion 1 from met to UNMET on the iPad half.** A cold launch on an iPad Air 11-inch (M4) Simulator writes a crash report within ~15s, twice out of two attempts (`Willagrams-2026-09-15-225441.ips`, `-225705.ips`). `EXC_BREAKPOINT`/SIGTRAP on `com.apple.root.default-qos`; the faulting frame is the orientation `requestGeometryUpdate` error handler in `ShellRootView.swift` (~70-75), which is `@MainActor`-isolated but called by UIKit on a background queue. iPhone SE is unaffected. **This is an App Store blocker and is round 3's item 1**
- **Next:** round-3 item 1 (the iPad launch crash), then items 2-12 in `LANE.md` order
- **Per-item floors now (counts are floors):** rules 53 · Board 271 · Match 128 · Style 34 · Shell 263 · Settings 36 · Bot 68 · Online 147 (1 known pre-existing issue at `WholeMatchScript.swift:98`) · Audio 19 · Account 16 · Friends 49
- **Owed to Nate, carried from round 2, none blocking:** item 2's `elapsedIsMeasuredFromPlaying` driver change wants sign-off; item 6's text self-conflicts on the Join button (code follows "disabled only when empty or in flight"); item 8 left a white system launch-screen flash its `done when:` did not cover
- **Round-3 scope decisions Nate made:** invites stay live-only broadcasts, so no new table, no migration and no production SQL — a friend with the app closed misses the invite, accepted. The lock-screen bug is not a crash: the app stays responsive and only Draw and Swap die. "PvP special match rules" is dropped — solo and Play a Friend already render the same options and he had not found the gear
- **Blockers:** none open. Three round-2 follow-ups are deliberately out of scope this round and live in `LANE.md`'s `## Out of scope`: app-wide Dynamic Type, the white launch flash (needs the protected `project.pbxproj`), and the `HostLobbyLayout.swift` orphan
- **Standing constraints:** migration `0006` is live (Nate applied it 2026-09-15: 40 of 1,274 fastest wins cleared, null guard present). Never `supabase db push` here — the live migration history is empty. `Config/Secrets.local.xcconfig` is gitignored and missing from 29 of 32 worktrees; a device build from one of them silently ships an empty Supabase key and every sign-in fails. `.git/info/exclude` now protects it and `.env` in every worktree
- **Last updated:** 2026-09-15

## Round 3 — hand-test fixes

| Item | Status |
|------|--------|
| iPad launch crash | not started |
| Buttons and codes stop wrapping | not started |
| Friend row fits a phone | not started |
| Solo stops saying HOST | not started |
| A saved name reaches the whole app | not started |
| Joining says it worked | not started |
| Invite a friend from the open seat | not started |
| Decline a match invite | not started |
| A screen lock no longer kills the match | not started |
| A dead match says so | not started |
| Double tap works on a letter | not started |
| Letters draw when they should | not started |

## Round 2 — final adjustments (shipped 2026-09-15)

| Item | Status |
|------|--------|
| Fast drag never flies home | done — A tile now lands in the cell it looks like it's over, and one dropped on a taken cell slides into a free cell next to it instead of flying home. (2026-09-15) |
| Resign wins skip fastest win | done — A win because your opponent resigned or left now counts as a win but never sets your fastest-win time; winning by playing out still records it. (2026-09-15) |
| iPhone portrait except gameplay | blocked — The phone now opens upright, but the iPad landscape check can't be proven from a simulator screenshot, and the upright Home is cut off until Home is rebuilt. (2026-09-15) |
| Tighter phone margins | done — Screens on an upright phone now sit 16pt from the edge instead of 40, so they stop looking cramped; iPad and sideways phone are unchanged. (2026-09-15) |
| Home rebuilt | done — Home now opens upright as a single column: the wordmark up top, then Multiplayer (marked coming soon), Play a Friend, and a tidy grid of Solo Practice, Profile, Friends and How to Play, with the old tagline gone. (2026-09-15) |
| One Play / Join a Friend screen | done — Play a Friend and Join a Friend are now one screen: two chips switch between them, the code shows as six tiles, and hosting still copies, shares and starts exactly as before. Switching chips now properly leaves the game you were in, which it previously did not. (2026-09-15) |
| Play a Friend match settings | done — Playing a friend now has its own settings: a gear on the host's screen opens starting tiles, shortest word, Swap and word list, and the guest's game is dealt with whatever the host chose instead of a fixed 21. The gear closes once you press Start. (2026-09-15) |
| Looping loading screen | done — The app now opens on the wordmark tiles flying together over a dark ground with a "Shuffling the Pool" caption, looping until sign-in and the dictionary are ready and then finishing its cycle before Home appears. One flaw left: the system's own first screen is still white for an instant before the dark one takes over. (2026-09-15) |
| Profile and Friends restyle | done — Profile and Friends now match the final design: an avatar card, stat cards with a win-rate bar, and friend rows as tiles, with Fastest win, Block and Unfriend all kept. (2026-09-15) |
| How to Play pager + Solo setup portrait | done — How to Play is now one rule per page with Back and Next and a Done on the last page, and Solo setup fits an upright phone in a single column. (2026-09-15) |

## Round 1 — phone polish (shipped 2026-09-15)

| Item | Status |
|------|--------|
| One sizing mechanism, proven on Menu | done — The home screen now fits a landscape phone without scrolling, with the logo centered and sized to the screen and smaller buttons on phones. |
| Apply sizing to remaining fixed-size screens | done — The lobby's invite code and buttons, the results and countdown cards, and solo setup all tighten up on a phone. |
| HUD bag legible on a phone | done — The bag in the match HUD is smaller on a phone and its count never truncates. |
| Typing screens keep the field visible | done — Profile, Friends and Join scroll the field you're typing in above the keyboard, and Join's button now sits beside its code field. |
| Reachable validation messages | done — A too-long name, a short friend code or a short join code now shows its message instead of silently greying out the button, and Return submits. |
| Unfriend | done — Each friend's row has an Unfriend button that asks first; unfriending never removes a block. |
| Zoom further out | done — You can pinch the board out further, to smaller tiles, so big boards fit on screen. |
| No drag snap-back | done — A tile you let go of stays where it lands, even on a fast drag; only an occupied cell sends it back. |
| Recenter frames every tile | done — Recenter now fits every tile on screen, clear of the bag and buttons, zooming out as far as needed. |
| No fly-in on pan | done — Tiles already on the board no longer fly in from the bag when you pan them back into view; new tiles still do. |
| Drawn tiles land near the board | done — Tiles from a Draw now land just below or beside your largest group of tiles. |
| Early start fix | done — An online match now starts only when the lobby creator presses Start. |
| Guest bag count | done — Both players now see how many tiles are left in the bag. |
| WILLA word + flourish | done — WILLA now counts as a word, and spelling it tints the tiles with a one-time sparkle. |
