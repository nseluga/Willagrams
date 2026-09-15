# polish lane — returned team-memory entries

## 2026-09-14 — dev-team-auto — One sizing mechanism for landscape phone, proven on Menu
- **Outcome:** DONE — 1 attempt — caution: no — team: dt-ui (sonnet, high), dt-qa (sonnet, high) — auto/polish, commit 6706a34
- **What happened:** Added `Typography.buttonCompact` and `Space.screenMargin`/`screenMarginCompact` tokens, taught the three `ButtonStyle` structs to read `verticalSizeClass` for compact sizing, added `.screenPadding()`, and replaced MenuView's hand-tuned layout with a plain `MenuLayout(size:)` struct that drives wordmark height, spacing, and quiet-action column count.
- **What worked:** Builder's own ShellTests/StyleTests cases covered every criterion; dt-qa's fresh re-run confirmed them.
- **What failed:** The top-level screenshot review found the letter met but the intent missed — wordmark ~50pt on phone, a dead middle gap, not centered — so a follow-up Menu pass ran.
- **Remember next run:** `MenuLayout` must stay SwiftUI-free to compile in ShellTests' macOS target, so it uses `size.height < 500` as the compact proxy. `StyleSourceTests` requires every DesignTokens key to appear in `StyleGallery.swift` — a new token needs a gallery row. Judge layout items from the screenshot, not the struct's numbers.

## 2026-09-14 — dev-team-auto — Remaining fixed-size screens (HostLobby/Results/Countdown/SoloSetup)
- **Outcome:** DONE (top-level verified after orchestrator hand-back) — caution: no — team: dt-ui (sonnet, high); dt-qa not run — auto/polish-b2, commit 7e3c6af
- **What happened:** New `HostLobbyLayout` struct drives the invite-code font (44/32) and button height (36/32); Results/Countdown card padding goes `.xl`→`.l` under compact; HostLobby/SoloSetup use `.screenPadding()`. No new tokens.
- **What failed:** Orchestrator ran out of turn budget waiting for a contention-free xcodebuild window — three worktrees built at once all session.
- **Remember next run:** Never run parallel-group UI items that each need xcodebuild concurrently on one machine; give each a distinct `-derivedDataPath` or serialize builds.

## 2026-09-14 — dev-team-auto — HUD bag legible on a phone
- **Outcome:** DONE (top-level verified; builder stalled "waiting on background work" and was stopped) — caution: no — team: dt-ui (sonnet, high) — auto/polish-b3, commit c1ef2ad
- **What happened:** `MatchHUDLayout` holds bag size (96 regular / 72 compact) and the pool-count formatter (nil → `—`); the count Text is monospaced-digit with minimumScaleFactor 0.5. Mutation check: nil guard → "0" turns the new test red.
- **Remember next run:** A shared-DerivedData "database is locked" BUILD FAILED is contention, not a code error. Don't wait on a subagent reporting "waiting on its own background work" with no process running — take over.
