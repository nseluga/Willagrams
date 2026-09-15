# Willagrams — polish / final lane progress

LANE.md is the contract; this tracks where we are in it. If they disagree, LANE.md wins for scope.

## Current position

- **Status:** round 2 (`final`, 10 items) set up on `lane/final`, cut from `lane/polish` @ `c1f038b`; no item started. Run paused at Nate's request before coding
- **Next:** `/dev-team-auto` from item 1 when Nate says go
- **Blockers:** none. Migration `0006` must be pushed by Nate before any build with item 2 plays online
- **Last updated:** 2026-09-15

## Round 2 — final adjustments

| Item | Status |
|------|--------|
| Fast drag never flies home | not started |
| Resign wins skip fastest win | not started |
| iPhone portrait except gameplay | not started |
| Tighter phone margins | not started |
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
