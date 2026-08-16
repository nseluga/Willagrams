# Willagrams — board lane progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** items 1-5 of 8 done on `lane/board`. The board draws itself, moves
  under the finger, lets you move the tiles on it, and can be made inert from
  outside: an endless grid, a camera you can pan, pinch, and recenter, tiles you
  can pick up and drop onto a square, and a plain boolean the owner sets to stop
  the tiles answering while the camera keeps working.
- **Next:** item 6 — live validation, tinting invalid words as soon as they are
  made.
- **Blockers:** none.
- **Last updated:** 2026-08-15

## Round 1 — the playing surface

| Item | Status |
|------|--------|
| Build BoardCamera — the geometry mapping an unbounded board to the screen | done — The board can now be panned and zoomed over an endless grid in every direction, and a point on screen maps back to the exact square under it. |
| Build BoardView — render the grid and the tiles on it | done — The board now shows an endless grid with the tiles sitting on it; tiles that form a word sit flush in the surface while loose ones keep their shadow and read as resting on top. |
| Add the camera gestures — pan, pinch to zoom, recenter | done — A finger on an empty square drags the board itself; a finger on a tile leaves the board still. Pinching zooms about the point between the fingers and stops at a readable size at both ends, and a recenter control slides the board back to frame every tile. |
| Add tile dragging — pick up, follow the finger, snap to a square | done — Touching a tile lifts it and it follows your finger, then drops onto the nearest square when you let go. A drop onto a taken square or too far from any square puts the tile straight back where it came from, and picking up, landing, and a refused drop each feel different in the hand. |
| Add the lock that makes the board inert from outside | done — The owner can set a plain boolean that stops the board answering: tiles cannot be picked up, moved or dropped, nothing lifts or buzzes under a finger, and a tile already in hand goes straight back to the square it came from without the board changing. Panning, zooming and recentering keep working the whole time, so a locked player can still look around. |
| Add live validation — tint invalid words as soon as they are made | not started |
| Add the opening layout and where drawn tiles land | not started |
| Add multi-tile selection and moving a group together | not started |
