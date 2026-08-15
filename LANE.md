# Willagrams — Lane: style

Lane: style — Visual identity and the IP fence — palette, typography, spacing and motion tokens, tile art, app icon, launch screen, player-facing terminology, and the written distinctness review against Bananagrams' name, trade dress, and vocabulary. Ships a StyleGallery screen rendering every token in situ.

Protected — do not edit. Stop and report if an item requires changing one:
  Sources/WillagramsRules/Contracts.swift
  Sources/WillagramsRules/BoardAnalysis.swift
  Sources/WillagramsRules/Pool.swift
  Sources/WillagramsRules/GameState.swift
  Sources/WillagramsRules/MatchMessage.swift
  Sources/WillagramsRules/WordList.swift
  Sources/WillagramsRules/Resources/dictionary.txt
  Tests/WillagramsRulesTests/**
  Willagrams/Style/DesignTokens.swift   (key names only; this lane owns the values)
  Willagrams/Style/Terminology.swift    (frozen entirely — do not edit)
  Willagrams.entitlements
  Package.swift

This lane has no `depends on:` edges — nothing to wait for, no fixtures to test against.

Global rules:
  - Never edit project.pbxproj. The target uses PBXFileSystemSynchronizedRootGroup,
    so new files are picked up automatically. Anything that would require a build-setting
    change is a stop-and-report, not a workaround.
  - Every color comes from an Assets.xcassets Color Set. No Swift code branches on
    colorScheme, and no literal hex outside the .colorset JSON.
  - Terminology.swift is frozen. Use its constants for any player-facing word.

---

- task: Bundle the Instrument Sans and Fragment Mono families and register them at runtime
  done when:
    - Willagrams/Resources/Branding/Fonts/ contains static TTFs for Instrument Sans 400/500/600/700 and Fragment Mono Regular, plus OFL.txt
    - BrandFonts.register() is called at app launch and exposes Font.brand(weight:size:) and Font.mono(size:)
    - A test asserts each of the five faces resolves to the bundled family, failing if any falls back to the system font
    - project.pbxproj is unchanged
  risk: an unregistered font falls back silently to San Francisco, which looks
        plausible and would ship unnoticed — caught only by the resolution test
  difficulty: low — CTFontManagerRegisterGraphicsFont over bundle URLs. Source the TTFs
        from the legacy-UA Google Fonts endpoint, not the google/fonts repo: the repo ships
        only the variable InstrumentSans[wdth,wght].ttf, while
        `curl -A "Mozilla/4.0" "fonts.googleapis.com/css?family=Instrument+Sans:400,500,600,700"`
        returns four static per-weight TTF URLs. OFL.txt comes from the repo.
  speed: N/A — one-shot registration at launch, no growth with rows or rate
  status: done
  parallel-group: a

- task: Add a light+dark Color Set to Assets.xcassets for every semantic palette token
  done when:
    - Willagrams/Assets.xcassets/Colors/ has one .colorset per token named in the plan's palette tables, each with an Any and a Dark appearance
    - Each colorset's two hex values match the light and dark palette tables exactly
    - A test enumerates the semantic token names and fails on any that does not resolve to a defined color
  risk: a typo'd or missing color set resolves to clear or black at runtime rather
        than erroring, so a whole surface renders wrong with nothing in the log — silent
  difficulty: low — mechanical JSON, values already pinned
  speed: N/A — static asset catalog lookup
  status: done
  parallel-group: a

- task: Replace the placeholder values in DesignTokens.swift and add the new keys the direction needs
  done when:
    - Every existing key keeps its exact name; tileFace, tileEdge, tileLetter, boardSurface, accent, danger, textPrimary, textSecondary, Space.*, Radius.tile, Radius.panel, Typography.*, Motion.* all still resolve
    - Palette members read from the Color Sets rather than Color(red:green:blue:)
    - New keys exist: canvasTop, canvasBottom, surface, ink, onInk, onAccent, accentPressed, hairline, cellEmpty, Radius.cell, Radius.pill, Typography.display, Typography.button, Typography.monoLabel, Motion.tileLift
    - Typography members use Font.brand/Font.mono, not Font.system
  risk: a renamed or dropped key breaks board and shell against a frozen contract —
        loud, it fails to compile. A wrong value is silent but visible in StyleGallery
  difficulty: low — values pinned by the direction; the only constraint is not renaming
  status: done

- task: Build the tile style — face, bevel, selected ring and lift
  done when:
    - A Tile view renders letter, face color and the bottom-bevel band at Radius.tile, in both themes
    - Selected state shows the 2.5pt accent ring and a Motion.tileLift offset, animated over Motion.snapDuration
    - Rendering is driven entirely by DesignTokens; the file contains no literal color, radius or duration
  risk: none — purely visual, wrong output is immediately obvious in StyleGallery
  difficulty: open — SwiftUI has no inner shadow, so the `inset 0 -3px 0` bevel has
        competing implementations (clipped gradient band, overlaid shape, layered rects)
        and which one holds up at small sizes is not settled
  status: done

- task: Build the card style and the three button styles
  done when:
    - A .brandCard() modifier applies surface fill, hairline border, Radius.panel, and the hard-offset zero-blur shadow in light — replaced by a 1pt top highlight in dark, since an offset shadow reads as nothing on a dark ground
    - ButtonStyles provides primary (ink fill, onInk label, soft drop), quiet (cellEmpty fill, hairline border) and text (accent, no chrome), each with a distinct pressed state
    - Both files contain no literal color, radius or duration
  risk: none — purely visual
  difficulty: low — standard ViewModifier and ButtonStyle work
  status: done
  parallel-group: b

- task: Write docs/ip-review.md, the written distinctness review
  done when:
    - It addresses the beveled bone-colored tile face directly as the closest element to Bananagrams' trade dress, and argues genericness across the word-tile category rather than assuming it
    - It records how the name, wordmark, gold-on-cream palette and Terminology.swift vocabulary each differ from the banana-pouch identity and the trademarked terms
    - It lists the Bananagrams terms that must never ship (bunch, split, peel, dump, bananas, rotten) and points at the test that enforces the fence
  risk: a weak or hand-waved argument surfaces as a cease-and-desist after launch,
        not before — silent, and by then the app is published and not cheaply revertible
  difficulty: open — the trade-dress argument has two competing framings (category
        precedent vs. point-by-point visual dissimilarity) and which carries more weight
        for tile faces specifically is the open question
  speed: N/A — prose document
  status: done
  parallel-group: b

- task: Build StyleGallery, rendering every token in situ
  done when:
    - Sections cover palette swatches, the type ramp, tiles in idle/selected/placed, cards, all three button styles, mono labels, and spacing/radius rulers
    - Every key defined in DesignTokens appears at least once, so an unused or misnamed token is visible rather than inferred
    - The screen renders correctly in both light and dark in the simulator
    - Tapping a gallery tile animates the selected lift, exercising Motion
  risk: none — this is the lane's proof surface; if it is wrong you see it
  difficulty: low — composition of the styles built above
  status: done

> **⚠️ AUTONOMOUS RUN — STOP HERE**

## Not yet specified

- App icon and launch screen — the direction supplies the palette and wordmark
  but no icon artwork, and the production route (hand-built vector vs. generated
  vs. commissioned) is undecided. Revisit after StyleGallery lands, when the
  wordmark exists as something to derive from.

## Out of scope

- Any screen under Willagrams/Shell/ or Willagrams/Board/ — the shell and board
  lanes own those and build them against these tokens later.
- The mock's marketing landing page (App Store buttons, live-match counts) —
  it is a store page, not an app screen, and the app has no backend to count matches.
- App Store screenshots and store art — release lane owns Resources/AppStore/.
