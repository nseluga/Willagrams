# Willagrams — board lane progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** item 1 of 6 done on `lane/board`. The board lane now has its own
  test target and the geometry everything else sits on.
- **Next:** item 2 — build BoardView, the grid and tile rendering.
- **Blockers:** none.
- **Last updated:** 2026-08-14

## Round 1 — the playing surface

| Item | Status |
|------|--------|
| Build BoardCamera — the geometry mapping an unbounded board to the screen | done — The board can now be panned and zoomed over an endless grid in every direction, and a point on screen maps back to the exact square under it. |
| Build BoardView — render the grid and the tiles on it | not started |
| Add the camera gestures — pan, pinch to zoom, recenter | not started |
| Add tile dragging — pick up, follow the finger, snap to a square | not started |
| Add live validation — tint invalid words as soon as they are made | not started |
| Add the opening layout and where drawn tiles land | not started |
