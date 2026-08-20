# Willagrams — shell lane progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** round 2 complete — all 7 items above the stop marker are done, none blocked.
- **Next:** the two bot-wiring items below the stop marker, once lane/bot reaches integration.
- **Blockers:** none blocking the run. One amendment request for the board lane: `BoardView` takes a camera but publishes no read-back, so after a pan the shell's stored camera is stale and a mid-match delivery can land off-screen.
- **Last updated:** 2026-08-19

## Round 2 — a playable match

| Item | Status |
|------|--------|
| Own the match run across countdown, match and results (`MatchRun`) | done — Starting solo practice now builds one match that the countdown, match and results screens all share, and leaving or starting a rematch fully shuts the old one down first. |
| Compose the match screen (`MatchView`) | done — The match screen now shows the real board with the controls over it, sized to the actual screen. |
| Wire ShellRootView's three placeholder routes to the real screens | done — Pressing Solo Practice now walks through the real countdown, board and results screens instead of stopping at placeholder text. |
| Give the invalid-run flash a caller | done — A Draw press the game refuses now flashes the offending words red instead of doing nothing. |
| Add the win claim | done — You can now call "Willagrams!" from the match screen; a valid board ends the match and shows results, an invalid one flashes the offending words instead. |
| Publish the host's remaining pool count | done — The Pool counter on the match screen now shows how many tiles are actually left and ticks down as you draw, instead of always reading "—". |
| Add the how-to-play screen | done — The menu has a second button opening a rules screen that explains Pool, Draw, Swap, the connected-board requirement and the win call, with a Back button to the menu. |
