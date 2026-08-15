# Willagrams — style lane progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** all 7 items done on `lane/style`; app builds for the simulator and
  both test suites pass.
- **Next:** merge into `integration` for human review.
- **Blockers:** none. Two things for the reviewer: the app root
  (`Willagrams/App/WillagramsApp.swift`, shell lane's file) was pointed at the
  gallery and registers the fonts at launch, and the style tests live in a
  nested standalone package because the root `Package.swift` is protected.
- **Last updated:** 2026-08-14

| Item | Status |
|------|--------|
| Bundle the Instrument Sans and Fragment Mono families and register them at runtime | done — The app now draws in its own typefaces instead of the system font, and a test fails if any weight silently falls back. |
| Add a light+dark Color Set to Assets.xcassets for every semantic palette token | done — Every brand color lives in the asset catalog with a light and a dark value, so the app themes itself without any code deciding which mode it is in. |
| Replace the placeholder values in DesignTokens.swift and add the new keys the direction needs | done — Spacing, radii, strokes, type, shadows and motion are all named values now; nothing in the UI hard-codes a number, and no old name was dropped. |
| Build the tile style — face, bevel, selected ring and lift | done — Tiles render with a bone face, a carved bottom edge, and idle/placed/selected states, holding their look at every size from a board cell to a hero tile. |
| Build the card style and the three button styles | done — Panels sit on the table with a hard offset shadow in light and a lit top edge in dark, and primary, quiet and text buttons each have a pressed state you can see without a side-by-side. |
| Write docs/ip-review.md, the written distinctness review | done — The review records why the name, look and vocabulary are defensible against Bananagrams, and which four things still need a human's eye before launch. |
| Build StyleGallery, rendering every token in situ | done — One screen shows every color, type size, tile state, card, button, ruler, shadow and motion value, checked in both light and dark on a simulator. |
