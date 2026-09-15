# Willagrams — polish / final lane progress

LANE.md is the contract; this tracks where we are in it. If they disagree, LANE.md wins for scope.

## Current position

- **Status:** round 2 run 2 (2026-09-15) — items 1, 2 and 4 done and merged; item 3 blocked, built and gate-closed but unmerged on `auto/final-a3` @ `4533ac0`; items 9 and 10 in flight; items 5–8 not started
- **Next:** Nate revises item 3's screenshot criterion (see its `status:`), then continue — merge `auto/final-a3` only with or after item 5 (Home rebuilt), or the portrait iPhone Home is cut off
- **Blockers:** item 3's iPad check needs a human-rotated Simulator or a revised criterion. Migration `0006` is live (Nate applied it 2026-09-15: 40 of 1,274 fastest wins cleared, null guard present). Never `supabase db push` here
- **Last updated:** 2026-09-15

## Round 2 — final adjustments

| Item | Status |
|------|--------|
| Fast drag never flies home | done — A tile now lands in the cell it looks like it's over, and one dropped on a taken cell slides into a free cell next to it instead of flying home. (2026-09-15) |
| Resign wins skip fastest win | done — A win because your opponent resigned or left now counts as a win but never sets your fastest-win time; winning by playing out still records it. (2026-09-15) |
| iPhone portrait except gameplay | blocked — The phone now opens upright, but the iPad landscape check can't be proven from a simulator screenshot, and the upright Home is cut off until Home is rebuilt. (2026-09-15) |
| Tighter phone margins | done — Screens on an upright phone now sit 16pt from the edge instead of 40, so they stop looking cramped; iPad and sideways phone are unchanged. (2026-09-15) |
| Home rebuilt | not started |
| One Play / Join a Friend screen | not started |
| Play a Friend match settings | not started |
| Looping loading screen | not started |
| Profile and Friends restyle | not started |
| How to Play pager + Solo setup portrait | not started |

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
