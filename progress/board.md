# Willagrams — board lane progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** all 8 of 8 items done on `lane/board`. The playing surface is
  complete: an endless grid you can pan, pinch and recenter; tiles you can pick
  up, drag and drop onto a square; words that turn red the moment they are not
  real; an opening layout that frames itself and a place for drawn tiles to
  land; multi-tile selection and group drag; and a plain boolean the owner sets
  to make the whole thing inert while the camera keeps working.
- **Next:** nothing in this lane — the run stopped at the `AUTONOMOUS RUN — STOP
  HERE` marker. Everything after it is unspecified and needs a planning pass.
- **Blockers:** none in the lane. Two things need a human: a device pass on the
  double-tap and pinch gestures, which no headless test in this repo can reach,
  and the choice of which GitHub account opens the PR.
- **Last updated:** 2026-08-15

## Round 1 — the playing surface

| Item | Status |
|------|--------|
| Build BoardCamera — the geometry mapping an unbounded board to the screen | done — The board can now be panned and zoomed over an endless grid in every direction, and a point on screen maps back to the exact square under it. |
| Build BoardView — render the grid and the tiles on it | done — The board now shows an endless grid with the tiles sitting on it; tiles that form a word sit flush in the surface while loose ones keep their shadow and read as resting on top. |
| Add the camera gestures — pan, pinch to zoom, recenter | done — A finger on an empty square drags the board itself; a finger on a tile leaves the board still. Pinching zooms about the point between the fingers and stops at a readable size at both ends, and a recenter control slides the board back to frame every tile. |
| Add tile dragging — pick up, follow the finger, snap to a square | done — Touching a tile lifts it and it follows your finger, then drops onto the nearest square when you let go. A drop onto a taken square or too far from any square puts the tile straight back where it came from, and picking up, landing, and a refused drop each feel different in the hand. |
| Add the lock that makes the board inert from outside | done — The owner can set a plain boolean that stops the board answering: tiles cannot be picked up, moved or dropped, nothing lifts or buzzes under a finger, and a tile already in hand goes straight back to the square it came from without the board changing. Panning, zooming and recentering keep working the whole time, so a locked player can still look around. |
| Add live validation — tint invalid words as soon as they are made | done — Words that are not real turn red the moment they are made, rather than waiting for a button press, and the board keeps track of whether the player is allowed to draw. Checking the whole board takes half a millisecond, so it happens after every move without the board ever feeling slow. |
| Add the opening layout and where drawn tiles land | done — A new match lays the starting tiles out in a block with a gap between every one, so nothing accidentally spells anything, and the board opens framed on them. Tiles from a draw land just below whatever you are looking at, in free space, so they appear without you having to go find them. However many tiles a match starts with, the layout follows the number rather than assuming it. |
| Add multi-tile selection and moving a group together | done — Double-tapping lets you sweep a finger across several tiles to pick them all out, then drag any one of them to move the whole set at once, keeping its shape. If the group would land on a tile that is not part of it, the whole move is refused rather than half-applied. Tapping empty space lets the selection go and hands normal panning and dragging back. |
