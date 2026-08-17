# Willagrams — Lane: shell — Progress

Where we are inside `LANE.md`. LANE.md is the contract; this tracks position in
it — if the two disagree, LANE.md wins for scope and this file wins for state.

## Current position

- **Status:** running — autonomous round, 11 items, no stop marker
- **Next:** item 9 (in-match HUD)
- **Open gap:** nothing carries a player's own board move back into the match's
  record of the board. After the first move the two disagree, and every later
  delivery of drawn tiles is refused whole — safe (no tile is lost) but wrong.
  Closing it needs a shell-side commit bridge that no item in this plan covers.
- **Blockers:** none
- **Last updated:** 2026-08-17

## v1 — the app shell

| Item | Status |
|------|--------|
| Shell route model and its headless test package | done — The app now has a single place that decides which screen is showing, with its own tests that run without a simulator. |
| Deal the opening hand | done — Both players now start a match holding their opening tiles instead of an empty rack, and the hand still arrives correctly if someone's connection drops at the exact moment the tiles are dealt. |
| Give BoardView a way to report its state to its owner | done — The board can now be handed tiles after it is on screen and can tell the rest of the app whether the player may draw. Still needs one check by hand on a real device: panning, zooming, dragging, snapping and double-tap selection. No automated test in this project can touch a gesture, so that one is genuinely unverified. |
| Author the real app root | done — The app now launches into its own root screen, which shows whichever screen the app says it is on. The throwaway board test harness is gone. The four screens behind it are placeholders until the later items build them. |
| Main menu screen | done — The app opens on a title screen with one button, Solo Practice, which starts a match. Host and Join are deliberately absent until there is something behind them. Still needs one check by hand: that the screen lays out cleanly in both landscape directions on a phone and on an iPad. |
| Construct a solo practice session | done — A single player can now be set up in a full-length practice match against a silent stand-in opponent, with enough tiles to play to the end rather than running dry half way. Note: this is built on the debug-only fake connection, so practice mode cannot ship to the App Store until a real single-device connection exists. |
| Countdown screen | done — Before a match starts, a card counts down over the board, showing the seconds the match itself reports rather than a timer of its own, and it disappears cleanly at zero — including when a match ends mid-countdown. Still needs one check by hand: that the board really is visible behind the card on a device. |
| Wire the match session to the board | done — Tiles dealt at the start now appear spread across the board rather than butted together, drawn tiles land where the player is looking, and whether the player may draw follows the board's own verdict on their words. No tile is ever in two places, including when a delivery is interrupted. See the open gap above: a player's own move is not yet carried back to the match record. |
| In-match HUD | not started |
| Results screen | not started |
| Rematch | not started |
