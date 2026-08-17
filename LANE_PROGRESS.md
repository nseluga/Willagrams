# Willagrams — Lane: shell — Progress

Where we are inside `LANE.md`. LANE.md is the contract; this tracks position in
it — if the two disagree, LANE.md wins for scope and this file wins for state.

## Current position

- **Status:** running — autonomous round, 11 items, no stop marker
- **Next:** item 2 (deal the opening hand) running; then items 4-11
- **Blockers:** none
- **Last updated:** 2026-08-17

## v1 — the app shell

| Item | Status |
|------|--------|
| Shell route model and its headless test package | done — The app now has a single place that decides which screen is showing, with its own tests that run without a simulator. |
| Deal the opening hand | not started |
| Give BoardView a way to report its state to its owner | done — The board can now be handed tiles after it is on screen and can tell the rest of the app whether the player may draw. Still needs one check by hand on a real device: panning, zooming, dragging, snapping and double-tap selection. No automated test in this project can touch a gesture, so that one is genuinely unverified. |
| Author the real app root | not started |
| Main menu screen | not started |
| Construct a solo practice session | not started |
| Countdown screen | not started |
| Wire the match session to the board | not started |
| In-match HUD | not started |
| Results screen | not started |
| Rematch | not started |
