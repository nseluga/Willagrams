# Willagrams — Lane: board

Lane: board — The playing surface — tile rack, drag/drop/snap to grid, pan/zoom, rearrange, invalid-placement feedback, haptics, tile animations.

Protected — do not edit. Stop and report if an item requires changing one:
  Sources/WillagramsRules/Contracts.swift
  Sources/WillagramsRules/BoardAnalysis.swift
  Sources/WillagramsRules/Pool.swift
  Sources/WillagramsRules/GameState.swift
  Sources/WillagramsRules/MatchMessage.swift
  Sources/WillagramsRules/WordList.swift
  Sources/WillagramsRules/Resources/dictionary.txt
  Tests/WillagramsRulesTests/**
  Willagrams/Style/DesignTokens.swift   (key names only)
  Willagrams/Style/Terminology.swift    (frozen entirely — do not edit)
  Willagrams.entitlements
  Package.swift

Frozen contracts — build and test against these; they will not move:
  rules — Sources/WillagramsRules/Contracts.swift
          (Coord, Tile, Placement, Board.place/remove/placementList, PlacementError)
  rules — Sources/WillagramsRules/BoardAnalysis.swift
          (BoardValidation, Board.clusters, Board.words(), Board.validate(against:))
          These carry no JSON fixture. They are concrete Swift types, so the type
          plus its passing tests in Tests/WillagramsRulesTests/ is the fixture.
  style — Willagrams/Style/DesignTokens.swift (key names) and Willagrams/Style/BrandTile.swift
          (BrandTile with State.idle / .placed / .selected)

Test against the fixture, not the producing lane. Do not wait for it to exist.

## The surface, as decided

There is **no rack.** The whole screen is the board; controls overlay on top of
it. Every tile a player holds is a `Board` placement at a real coord — loose
tiles simply sit somewhere they are not part of a word. `GameState.hand` stays
empty, and the Draw gate works out for free: `BoardValidation` counts each loose
tile as its own cluster, so `clusterCount == 1` is false while anything is still
scattered. One model, no rack/board duality.

The board is **unbounded** in all four directions. Coords go negative. The
player navigates by panning and zooming rather than by the board having edges.

## Global rules

  - Never edit project.pbxproj. The target uses PBXFileSystemSynchronizedRootGroup,
    so new files are picked up automatically. Anything that would require a
    build-setting change is a stop-and-report, not a workaround.
  - No literal color, radius, spacing, duration, or font value in any file in this
    lane. Every one comes from DesignTokens. Tile art comes from BrandTile — do
    not re-implement the face, bevel, ring, or lift.
  - Nothing here imports GameKit or references a match, a peer, or a message. The
    board is a single-player surface that a match drives from outside; it must be
    fully exercisable with no network and no second device. Where the match needs
    to change how the surface behaves, it does so by setting a plain input on it —
    the board never learns why, and never asks.
  - Terminology.swift is frozen — use its constants for any player-facing word.
    The banned Bananagrams vocabulary (bunch, split, peel, dump, bananas, rotten)
    must not appear in source identifiers, comments, or test names either. The
    mechanic is **Draw**.
  - Never assume a maximum or non-negative row or column. Any code path that
    clamps, allocates, or iterates over the full coordinate space is a bug.
  - Landscape only. iPad is the primary device, iPhone must work. Derive layout
    from the geometry proxy; no hardcoded screen dimensions or device checks.
  - Tests go in Tests/BoardTests/. If that target cannot be declared without
    editing the protected Package.swift, stop and report — it is an amendment.

---

- task: Build BoardCamera in Willagrams/Board/BoardCamera.swift — the pure geometry
    mapping an unbounded board to a viewport. Holds a pan offset (CGSize), a zoom
    scale, and a base cell size, and exposes: point(for: Coord) -> CGPoint,
    coord(at: CGPoint) -> Coord, visibleCoords(in: CGRect) -> some Sequence<Coord>,
    a zoom clamp keeping the rendered cell between 24pt and 72pt, and
    recenter(over: [Coord], in: CGRect) returning the pan and zoom that frames
    them. No SwiftUI, no UIKit — this is the piece everything else sits on and it
    must be testable with no host app.
  guardrails:
    - Import Foundation and CoreGraphics only. A SwiftUI import here means the
      geometry is entangled with a view and can no longer be tested in isolation
    - Never clamp a Coord to non-negative or to any maximum; the board extends
      equally in all four directions
    - Do not cache a computed transform across a pan or zoom change
  done when:
    - For coords sampled across row/col -500...500 and zoom 0.5...3.0, coord(at: point(for: c)) == c
    - Coord(row: -40, col: -40) maps to a point distinct from Coord(row: 40, col: 40), with no clamping toward the origin
    - visibleCoords(in:) returns exactly the coords whose cells intersect the rect, and its count for a fixed viewport and zoom is the same whether the camera sits at the origin or 500 cells away
    - recenter(over:in:) returns a camera under which every supplied coord's point falls inside the rect, with cell size still inside 24...72pt
  status: done

- task: Build BoardView in Willagrams/Board/BoardView.swift — renders the grid and
    the tiles on it through BoardCamera. Draws a cellEmpty background per visible
    coord on boardSurface, and a BrandTile for each placed tile at its camera
    point. Rendering is driven by camera.visibleCoords(in:), never by iterating
    every placement, so an unbounded board costs the same to draw as a small one.
    A tile that is part of a run of two or more renders BrandTile.State.placed; a
    loose tile renders .idle, so scattered tiles keep their drop shadow and read
    as sitting on top of the surface rather than seated in it.
  guardrails:
    - Never iterate Board.placements to decide what to draw; drive the draw from
      the visible range and look placements up by coord
    - Do not re-implement tile art — BrandTile owns the face, bevel, ring and lift
    - No literal color, radius, or spacing value in the file
  done when:
    - Every coord returned by visibleCoords renders a cell, and every placed tile inside that range renders a BrandTile at the camera's computed point
    - A board whose tiles sit at row/col ±500 builds no more views than the same board translated to the origin
    - A tile in a run of 2+ renders .placed; a tile with no orthogonal neighbor renders .idle
    - The surface renders correctly in both light and dark
  status: done

- task: Add the camera gestures to BoardView — a DragGesture whose hit test at
    gesture start decides once whether it pans or moves a tile (empty cell → pan,
    tile → hand off to the drag item below), a MagnifyGesture zooming about the
    pinch midpoint through BoardCamera's clamp, and a recenter control overlaid on
    the surface calling camera.recenter(over:) with every placed coord.
  guardrails:
    - The pan/drag decision is made at gesture start and never changes mid-gesture;
      a finger that began panning keeps panning even if it crosses a tile
    - The zoom clamp lives in BoardCamera, not in the gesture code
    - Panning is never clamped to a maximum extent in any direction
  done when:
    - A drag beginning on an empty cell translates the camera one-to-one with the finger; a drag beginning on a tile leaves the camera unchanged
    - Pinching scales about the pinch midpoint, and the rendered cell size stops at 24pt and 72pt at the two ends
    - The recenter control produces a camera framing every placed tile, animated over Motion.snapDuration
    - Panning 1000 cells in any direction, including negative, leaves the board rendering normally
  status: done

- task: Add tile dragging to BoardView — touching a tile renders it
    BrandTile.State.selected and lifts it by Motion.tileLift, the tile follows the
    finger, and on release it snaps to the nearest free cell center within
    Motion.snapThreshold, committing through Board.remove(at:) then
    Board.place(_:at:). Model the thing being dragged as a *set* of coords from
    the start, holding one in the ordinary case — a later item moves several
    tiles at once, and a drag written for exactly one tile is painful to widen. A release over an occupied cell or outside the threshold
    returns the tile to where it came from with the board untouched. Pickup, a
    successful snap, and a rejected drop each fire a distinct haptic through
    UIImpactFeedbackGenerator / UINotificationFeedbackGenerator behind a small
    injectable protocol so a test can assert them.
  guardrails:
    - A failed drop must leave Board byte-identical to its pre-drag state — never
      a remove that lands without its matching place
    - Never mutate Board.placements directly; go through place/remove so the
      frozen type's invariants hold
    - A tile's UUID must survive a move unchanged — do not recreate the Tile
  done when:
    - Touching a tile renders it .selected with the Motion.tileLift offset, and releasing returns it to .idle or .placed
    - Releasing within Motion.snapThreshold of a free cell moves the tile there, and the moved tile's id is the same UUID it had before the drag
    - Releasing over an occupied cell or beyond the threshold leaves Board.placementList identical to before the gesture
    - The haptic protocol records exactly one pickup, one snap, and one reject event across a drag of each kind
  status: done

- task: Add an external input lock to BoardModel and BoardView — a plain
    `inputLocked: Bool` the surface accepts from outside. While it is set, tiles
    cannot be picked up, dragged, or committed, and the board reads as inert:
    tiles hold their current position and no lift, ring, or haptic fires on
    touch. Panning, zooming, and recentering stay live, so a locked player can
    still look around their board. The match lane sets this when a Draw is owed
    or the peer has dropped, but nothing in this lane may name or import either
    condition — the board takes a boolean and asks no questions.
  guardrails:
    - No drag may begin or commit while inputLocked is set; refuse at gesture
      start rather than reverting after the fact
    - Never name this flag, its property, or its tests after the match condition
      that causes it — no "pendingDraw", no "peel", no "frozen peer" in this lane
    - Locking must never mutate Board. A lock that lands mid-drag returns the
      tile to its origin coord and leaves placementList unchanged
  done when:
    - With inputLocked set, a drag beginning on a tile leaves Board.placementList identical and fires no haptic
    - With inputLocked set, panning, pinch zoom, and recenter all still work
    - Setting inputLocked during an in-flight drag returns the tile to the coord it started from
    - Clearing inputLocked restores dragging with no residual selected state on any tile
  status: not started

- task: Add live validation to Willagrams/Board/BoardModel.swift — after every
    committed move, call board.validate(against:) on the frozen dictionary and
    publish the resulting BoardValidation. BoardView tints the tiles of every word
    in validation.invalidWords with Palette.danger, so an invalid alignment shows
    the instant it is made rather than when a button is pressed. Also publish
    canDraw straight from validation.isComplete for the shell to gate its buttons
    on.
  guardrails:
    - Never re-implement cluster detection, word extraction, or the completeness
      rule — BoardAnalysis owns all three and is frozen
    - Validation runs on commit only, never per-frame during a drag
    - The tint is read from published state; a view body must not call validate()
  done when:
    - The published BoardValidation is recomputed after every committed move, and removing the recompute call makes a test fail
    - Tiles belonging to a word in invalidWords render in Palette.danger; tiles in valid words and loose tiles do not
    - The published canDraw equals board.validate(against:).isComplete, obtained by calling the frozen method rather than re-deriving the condition
    - Median of 5 runs, revalidating and republishing after a move on a 144-tile board completes in under 16ms
  status: not started

- task: Add the opening layout and Draw landing to BoardModel — a new match takes
    its opening tiles from outside and places them as Board placements in a block
    roughly three rows deep, spaced one empty cell apart in both axes so no two
    are orthogonally adjacent, and the initial camera frames that block. The count
    is an input, never a constant: the starting hand size travels on the wire and
    is about to become configurable, so a hardcoded 21 here would be a bug the
    moment anyone changes it. Tiles arriving from a Draw are placed into free cells
    immediately below the currently visible content, spaced the same way, so they
    are visible without moving the camera.
  guardrails:
    - Opening and delivered tiles must never be placed orthogonally adjacent to
      each other — touching tiles would form runs of random letters and tint the
      whole board danger before the player has done anything
    - Landing must never overwrite an existing tile or let PlacementError.occupied
      escape; find free cells, do not assume they are free
    - GameState.hand stays empty; tiles go onto the board, not into a rack
  done when:
    - Starting a match with N opening tiles leaves N on the board, none orthogonally adjacent to another, and BoardValidation reports N clusters and zero invalid words — verified at N of 21 and at a different N
    - The initial camera frames every opening tile with margin, in landscape, on both an iPad and an iPhone viewport
    - Tiles delivered by a Draw land at coords inside the viewport rect at the moment of delivery, and none is adjacent to an existing tile
    - Delivering onto a board whose cells below are already occupied still places every tile, and Board.placementList grows by exactly the number delivered
  status: not started

- task: Add multi-tile selection and group drag to BoardView. A double-tap enters
    selection mode. While in it, a one-finger drag across the surface paints every
    tile it crosses into the selection rather than panning or moving anything, and
    selected tiles render BrandTile.State.selected. Dragging any already-selected
    tile then moves the whole selection together, every tile keeping its offset
    from the others, committing as one batch through Board.remove/Board.place.
    Tapping empty space clears the selection and leaves selection mode. Pinch zoom
    stays live throughout so the player can still see what they are sweeping.
  guardrails:
    - A group move is all-or-nothing: if any tile would land on a cell occupied by
      a tile outside the selection, refuse the entire move and leave Board unchanged
    - Never leave the player stuck in selection mode — clearing must always be
      reachable without moving a tile
    - Painting a selection mutates view state only; Board is untouched until a
      group drag commits
    - No selection may begin or continue while inputLocked is set
  done when:
    - A double-tap enters selection mode, and a drag crossing N tiles leaves exactly those N selected and rendered .selected
    - Dragging one selected tile moves all of them, and every pairwise row/col offset within the selection is identical before and after
    - A group move whose destination overlaps a non-selected tile leaves Board.placementList unchanged
    - Tapping empty space clears the selection and restores ordinary panning and single-tile dragging
  status: not started

> **⚠️ AUTONOMOUS RUN — STOP HERE**

## Not yet specified

- iPad Split View and Stage Manager — the camera has to respond to a viewport
  that changes size mid-match, and whether it should preserve the center point
  or the zoom level is not yet a sharp question. Revisit after item 3, when the
  camera actually responds to viewport changes.

## Out of scope

- The Draw and Win buttons, the countdown, and the rest of the in-match HUD —
  shell owns those and gates them on the canDraw this lane publishes.
- Any banner or copy explaining *why* input is locked — shell owns that, because
  only shell knows whether a Draw is owed or the peer dropped. This lane ships
  the lock, not its explanation.
- Anything that knows a match exists: peers, messages, the opponent's board.
  Match owns that and drives this surface from outside.
- A deal animation for the opening block — Motion.dealDuration exists for it,
  but the block appearing instantly is fine for a first round, and there is no
  shell yet to trigger a real match start.
- Solo practice mode — shell owns it; it will reuse this surface unchanged.
