# Willagrams — board lane progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** all 8 of 8 items done on `lane/board`. The playing surface is
  complete: an endless grid you can pan, pinch and recenter; tiles you can pick
  up, drag and drop onto a square; bad words that flash red when the player
  claims to be done; an opening layout that frames itself and a place for drawn tiles to
  land; multi-tile selection and group drag; and a plain boolean the owner sets
  to make the whole thing inert while the camera keeps working.
- **Next:** nothing in this lane — the run stopped at the `AUTONOMOUS RUN — STOP
  HERE` marker. Everything after it is unspecified and needs a planning pass.
- **Blockers:** none in the lane. Two things need a human: a device pass on the
  double-tap and pinch gestures, which no headless test in this repo can reach,
  and the choice of which GitHub account opens the PR.
- **Last updated:** 2026-08-17

## Round 1 — the playing surface

| Item | Status |
|------|--------|
| Build BoardCamera — the geometry mapping an unbounded board to the screen | done — The board can now be panned and zoomed over an endless grid in every direction, and a point on screen maps back to the exact square under it. |
| Build BoardView — render the grid and the tiles on it | done — The board now shows an endless grid with the tiles sitting on it; tiles that form a word sit flush in the surface while loose ones keep their shadow and read as resting on top. |
| Add the camera gestures — pan, pinch to zoom, recenter | done — A finger on an empty square drags the board itself; a finger on a tile leaves the board still. Pinching zooms about the point between the fingers and stops at a readable size at both ends, and a recenter control slides the board back to frame every tile. |
| Add tile dragging — pick up, follow the finger, snap to a square | done — Touching a tile lifts it and it follows your finger, then drops onto the nearest square when you let go. A drop onto a taken square or too far from any square puts the tile straight back where it came from, and picking up, landing, and a refused drop each feel different in the hand. |
| Add the lock that makes the board inert from outside | done — The owner can set a plain boolean that stops the board answering: tiles cannot be picked up, moved or dropped, nothing lifts or buzzes under a finger, and a tile already in hand goes straight back to the square it came from without the board changing. Panning, zooming and recentering keep working the whole time, so a locked player can still look around. |
| Add live validation — flash invalid words when the player claims to be done | done — **Amended 2026-08-17, see below.** The board checks itself after every move and keeps track of whether the player is allowed to draw, but shows nothing while they are still laying tiles out. Pressing Draw or calling the win flashes every bad word red for about half a second and then fades it away. Checking the whole board takes half a millisecond, so it happens after every move without the board ever feeling slow. |
| Add the opening layout and where drawn tiles land | done — A new match lays the starting tiles out in a block with a gap between every one, so nothing accidentally spells anything, and the board opens framed on them. Tiles from a draw land just below whatever you are looking at, in free space, so they appear without you having to go find them. However many tiles a match starts with, the layout follows the number rather than assuming it. |
| Add multi-tile selection and moving a group together | done — Double-tapping lets you sweep a finger across several tiles to pick them all out, then drag any one of them to move the whole set at once, keeping its shape. If the group would land on a tile that is not part of it, the whole move is refused rather than half-applied. Tapping empty space lets the selection go and hands normal panning and dragging back. |

## Amendment — 2026-08-17: red is a flash, not a state

Landed on `lane/shell-r2` after the board lane closed, at Nate's request. The
lane `owns:` fence was crossed deliberately for it; nothing `protected:` moved.
Written 2026-08-17 against the pre-`eb39f9e` tree and replayed onto
`integration` on 2026-08-19 — see "What did not survive the replay" below.

**What changed.** Laying a word down no longer turns anything red. The board
still checks itself on every commit — `validation`, `canDraw` and
`invalidCoords` are all unchanged — but the surface draws a new, usually empty
set instead:

- `BoardModel.flashedInvalid` — the coords tinted right now. Written only by
  `attemptedCompletion()`, cleared by `clearFlash()` and by every `revalidate`,
  so a flash can never outlive the board it answered about.
- `BoardModel.attemptedCompletion() -> Bool` — "the player says they are done".
  Returns `canDraw`; on `false` it lights every bad run. No completeness rule is
  restated, it reads the same published gate the button does.
- `BoardView(completionAttempts:)` — a counter the owner increments on a Draw
  press or a win call. `.task(id:)` on it flashes and then fades, so two refused
  presses read as two flashes rather than one long red. Hold 0.45s, fade 0.35s,
  named in `BoardView` because `DesignTokens` is frozen.

**What did not survive the replay.** The 2026-08-17 work also gave
`BoardHarness` a throwaway Draw button so the flash was drivable by hand. That
harness was deleted on `integration` by `eb39f9e` when `shell` authored the real
root, so the hunk was dropped rather than replayed. The flash currently has no
caller in the app at all — only the previews and the tests drive it.

**Who has to do something.** The shell lane owns the real Draw and win buttons:
whatever calls `MatchSession.draw()` or `claimWin()` must also increment the
counter it passes to `BoardView`, or a refused press explains nothing.

**Verified on replay, 2026-08-19.** 53 engine, 248 board, 124 match, 30 style,
61 shell, 36 settings, 6 audio, 26 online tests pass, and the iOS app target
builds. Three new cases in `BoardValidationTests` cover the flash; the
`BoardSourceTests` grep now pins the view to `flashedInvalid` and fails if the
standing tint comes back.
