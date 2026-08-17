# Willagrams — Lane: shell — Progress

Where we are inside `LANE.md`. LANE.md is the contract; this tracks position in
it — if the two disagree, LANE.md wins for scope and this file wins for state.

## Current position

- **Status:** finished — autonomous round, all 11 items done, none blocked
- **Next:** nothing in this plan. The lane's remaining work is the four gaps
  below plus five checks that can only be made by hand on a device.
- **Follow-up, rematch:** an end screen that is left up after its own match ends
  cannot act on the match that replaced it — but the owner does not treat
  "returned to the menu" as ending a generation, so a screen whose Main Menu was
  pressed can still start a match from the menu. Harmless today because nothing
  in the shipping app builds one, and closing it properly means simplifying how
  Rematch and Main Menu share their teardown rather than adding another guard.
- **Second open gap:** the countdown, match and results screens are all built and
  tested, but the app root still shows placeholders for those three routes —
  only the menu is reachable. No item in this plan wires them up, so the app
  cannot yet be played end to end even though every piece of it exists.
- **Amendment needed:** `Willagrams/Match/MatchSession.swift` publishes no
  count of tiles left in the pool — the real pool is private inside the host's
  actor and the session's own copy is a deliberate placeholder. The HUD shows a
  dash instead of a number until the match lane exposes one. The same change
  closes a narrow case where swapping with 1–2 tiles left can strand a tile.
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
| In-match HUD | done, except one part — Draw is genuinely unavailable until the player's words are valid, Swap exchanges a tile and is refused cleanly when too few remain, and Resign takes two deliberate steps so a stray tap cannot end a match. Nothing about the opponent is shown. The tiles-remaining count shows a dash: the match layer publishes no such number yet (see the amendment above). Still needs one check by hand: that the HUD does not cover the board's recenter button. |
| Results screen | done — The end of a match shows who won, or says plainly that there was no winner when a player vanishes — which is a real outcome, not a loss. Main Menu genuinely shuts the match down rather than leaving it running behind the menu, proved by the match object actually being freed. The final board is frozen and cannot be played on. Still needs one check by hand: that the board is visible behind the result card. |
| Rematch | done — Playing again builds a genuinely new match rather than resetting the old one: the same two players, a deal that can never repeat the one just played, and the finished match shut down before the new one exists. Ten rematches in a row leave nothing running behind them, and a message from the old connection cannot reach the new match. An end screen left over from a previous match now refuses both its buttons instead of acting on whichever match happens to be live. One part is unverifiable rather than unbuilt: the match layer publishes no count of tiles left, so "the pool starts fresh" is proved by every tile in the new match being a different tile, not by a number. |
