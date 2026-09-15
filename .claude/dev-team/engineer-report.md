# Engineer Report
**Task:** LANE item 8: remove drag snap-back (a tile stays where it's released unless the cell is occupied)
**Branch:** auto/polish-c8
**Date:** 2026-09-14

## Proven cause (code-path trace + model-level reproduction; not device-reproduced)
- CAUSE: suspect 3. The system takes the touch (an edge swipe; nothing defers system gestures), so SwiftUI cancels the DragGesture and `onEnded` never fires. The hold (`model.tileDrag` / `dragTranslation`) stays stale. On the next touch, `onChanged` calls `model.began(...)`, which replaces the hold and zeroes the translation, so the tile is drawn back at its origin.
- REPRO (written first, run on unmodified code): `BoardModelTests.testReproALostReleaseThenTheNextTouchSnapsTheTileHome` (began → moved 21 cols → no commit → began(.pan)). Red: `XCTAssertNotEqual failed: ("Optional((0.0, 0.0))") is equal to ("Optional((0.0, 0.0))") - tile snapped back to its origin`. It was then replaced by the final cancel-path cases below.
- RULED OUT, distance guard: dead in the app. The target is the cell containing the drop point, so reach is at most half a cell's diagonal, about 51pt at the 72pt max cell, under 96. It only fired in tests using the fixture threshold of 22.
- RULED OUT, pinch: `BoardPinchReporter` only reports with 2 or more touches (`numberOfTouches >= 2`), so a one-finger drag cannot reach `cancel()`.
- RULED OUT, sync(): it writes only on arrivals (not tied to drag speed), and `var next = model` carries the hold across.

## Design Decisions
- Deleted the reach guard. `threshold` stays as an ignored parameter (ponytail note), so about 100 test call sites and the source-pin tests don't churn.
- Added `BoardModel.interrupted(on:camera:against:)`, which commits at the last reported `dragTranslation`: same occupied-cell and group rules, same haptics.
- BoardView: a `@GestureState touching` flag, which SwiftUI resets on cancel too, calls `landInterrupted()` when it resets. `onChanged` also lands any stale hold before `began`. `.defersSystemGestures(on: .all)` on the board.
- Pinch (a second finger) still calls `cancel()` and returns the tile home. That is not a release, and landing there would buzz on every pinch that starts on a tile.
- The lock cancel is unchanged: it still returns the tile home.

## Files Changed
- `Willagrams/Board/BoardDrag.swift`: reach guard and threshold finiteness check deleted.
- `Willagrams/Board/BoardModel.swift`: new `interrupted()`.
- `Willagrams/Board/BoardView.swift`: GestureState reset hook, stale-hold landing before `began`, `.defersSystemGestures`.
- `Tests/BoardTests/Cases/BoardDragTests.swift`: new cases for a 25-cell single update onto an empty cell, the same onto an occupied cell, and a 30-cell group landing (all free) or refused (one taken). Removed 4 tests that asserted distance refusals.
- `Tests/BoardTests/Cases/BoardModelTests.swift`: new interrupted-lands-at-last-cell and interrupted-onto-occupied-returns-to-origin cases.
- `Tests/BoardTests/Cases/BoardDragGateTests.swift`: removed 2 threshold-boundary tests and 2 distance-only refusal rows; the raw-zoom test now asserts col 67, not a refusal.

## Mutations (both reverted)
- A, guard restored (at the fixture threshold): red: FastDragAcrossTwentyFiveCells, FastGroupDragLandsWhole, DragWhoseReleaseNeverArrives, and the gate raw-zoom test.
- B, occupied-cell rule removed (guard bypassed and the sitter overwritten): red: FastDragReleasedOnAnOccupiedCell, FastGroupDragIsRefusedWhole, InterruptedDragOverAnOccupiedCell, plus 2 existing occupied tests. Bypassing the guard alone stayed green, because `Board.place` throws on an occupied cell too.

## Gates
- BoardTests: 253 tests, 0 failures. ShellTests: 227 passed. xcodebuild: BUILD SUCCEEDED.

## Flags for Reviewer
- The GestureState reset may fire before `onEnded` on a normal release. If it does, the landing uses the last `onChanged` translation, and `onEnded` then finds no hold and does nothing. It is idempotent.
- `.defersSystemGestures(on: .all)` means edge swipes (home indicator, Control Center) need two swipes while the board is on screen.
- Nate's hand test (not verified): on the iPhone, drag fast and far and release on an empty cell: the tile stays. Release on a tile: it returns. Swipe off the bottom edge mid-drag: the tile lands where the finger last was.
