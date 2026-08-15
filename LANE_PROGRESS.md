# Willagrams — board lane progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** items 1-3 of 8 done on `lane/board`. The board draws itself and
  now moves under the finger: an endless grid, the tiles on it, each tile
  reading as either part of a word or loose, and a camera you can pan, pinch,
  and recenter.
- **Next:** item 4 — tile dragging: pick up, follow the finger, snap to a square.
- **Blockers:** none.
- **Last updated:** 2026-08-15

## Round 1 — the playing surface

| Item | Status |
|------|--------|
| Build BoardCamera — the geometry mapping an unbounded board to the screen | done — The board can now be panned and zoomed over an endless grid in every direction, and a point on screen maps back to the exact square under it. |
| Build BoardView — render the grid and the tiles on it | done — The board now shows an endless grid with the tiles sitting on it; tiles that form a word sit flush in the surface while loose ones keep their shadow and read as resting on top. |
| Add the camera gestures — pan, pinch to zoom, recenter | done — A finger on an empty square drags the board itself; a finger on a tile leaves the board still. Pinching zooms about the point between the fingers and stops at a readable size at both ends, and a recenter control slides the board back to frame every tile. |
| Add tile dragging — pick up, follow the finger, snap to a square | not started |
| Add the lock that makes the board inert from outside | not started |
| Add live validation — tint invalid words as soon as they are made | not started |
| Add the opening layout and where drawn tiles land | not started |
| Add multi-tile selection and moving a group together | not started |
