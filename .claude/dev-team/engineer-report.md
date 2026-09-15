# Engineer Report
**Task:** LANE item 8 attempt 2: apply the review findings on top of 04bb6a8 (remove drag snap-back)
**Branch:** auto/polish-c8
**Date:** 2026-09-14
**Gates:** BoardTests 253/0 fail · ShellTests 227 passed · xcodebuild BUILD SUCCEEDED

## Proven cause (unchanged from attempt 1)
- The system takes the touch (an edge swipe), so SwiftUI cancels the DragGesture and `onEnded` never fires. The next touch's `began` then discards the stale hold, and the tile snaps home. Reproduced on unmodified code by `testReproALostReleaseThenTheNextTouchSnapsTheTileHome`, which failed with "tile snapped back to its origin". It was then replaced by the interrupted-path cases.

## Findings applied (all view-only; no model logic changed)
- Important 1, BoardView onChanged: `landInterrupted()` now runs BEFORE `BoardGesture.Drag(at:in:offsets:)`, so the new touch is hit-tested against the settled board and offsets. Guardrail 3 is restored.
- Important 2, BoardView onEnded: `model.moved(to: value.translation)` runs first, and `commit` reads `model.dragTranslation`. A release and a lost release now use the same number. Residual: if the `touching` reset ever runs before `onEnded`, the final touch-up delta is still lost, because it never reached the model.
- Minor 3, BoardView onChange(of: touching): also sets `drag = nil`.
- Minor 4, BoardView: `.defersSystemGestures(on: inputLocked ? [] : .all)`. The BoardSourceTests "body names the lock once" pin exempts exactly this line, with a comment explaining why.
- Over-engineering, partial: renamed `testAtTheCellSizeFloorTheThresholdCanNeverRefuseADistantDrop` to `…ACornerReleaseLandsAndOnlyAnOccupiedCellRefuses`, and the refusal row "a generous reach" to "a non-indexable column".

## Disputed / Deferred
- Removing the `threshold` parameter is deferred. It would churn about 100 test sites and the BoardSourceTests pins that assert its injection (lines 344-378 and 1006-1149).
- Disputed that `interrupted`'s `threshold: 0` is a trap. The value is ignored, so it does not affect landing. A comment now says 0 is deliberate: a restored guard refuses there, and the interrupted test goes red (confirmed by mutation A).
- No new BoardTests case. All four fixes are view-only: gesture callback ordering, `@GestureState`, and a system-gesture modifier.

## Files Changed
- `Willagrams/Board/BoardView.swift`: findings 1-4.
- `Willagrams/Board/BoardModel.swift`: comment on `interrupted`'s threshold.
- `Tests/BoardTests/Cases/BoardDragGateTests.swift`: one test renamed, one row renamed.
- `Tests/BoardTests/Cases/BoardSourceTests.swift`: the lock-once pin exempts the `defersSystemGestures` line.

## Mutations (re-run, both reverted)
- A, reach guard restored: red on FastDragAcrossTwentyFiveCells, FastGroupDragLandsWhole, DragWhoseReleaseNeverArrives, and gate RawZoom.
- B, occupied rule removed (with overwrite): 15 red, including FastDragReleasedOnAnOccupiedCell, FastGroupDragIsRefusedWhole, and InterruptedDragOverAnOccupiedCell.

## Nate's hand test (not verified)
- Landscape iPhone 13 mini: drag fast and far, release on an empty cell, and the tile stays. Release on a tile, and it returns with the reject buzz.
- Swipe from the bottom edge mid-drag, then touch the tile where it landed: it lifts rather than panning.
- Pinch mid-drag: the tile returns home. On a locked board (countdown or results), one edge swipe opens the home indicator or Control Center.
