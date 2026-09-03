# Willagrams — audio lane — Progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** all items above the autonomous-run stop marker are done — run shut down
- **Next:** human review of the `caution: true` SystemAudioPlayer item, then merge; after that the two open questions under "Not yet specified" (what the nine effects sound like; the countdown tick's cadence)
- **Blockers:** none
- **Last updated:** 2026-08-25 15:20 — full-suite regression check (every `Tests/*` package plus `WillagramsRulesTests`) passed with zero failures: WillagramsRules 53/53, AudioTests 19/19, BoardTests 0/0, BotTests 68/68, MatchTests 125/125, OnlineTests 26/26, SettingsTests 36/36, ShellTests 125/125, StyleTests 30/30

## Round 2 — sound and haptics

| Item | Status |
|------|--------|
| Build the effect catalogue (`AudioCatalogue.swift`) | done — Every game moment now has a defined sound, volume, and haptic in one file, so a tenth sound effect would fail to compile until someone decides what it sounds like. |
| Build the mute state and its persistence (`AudioSettings.swift`) | done — The app can now remember whether sound is muted between launches; new installs start unmuted. |
| Build `SystemAudioPlayer` (real playback + haptics, respects silent switch) | done — The game can now actually play sound and haptics through the system, without ever overriding the phone's silent switch. Flagged for human review (`caution: true`): behaviorally verified on a simulator (no physical Taptic Engine or silent-switch hardware to test against), and no sound files exist yet so every sound is still silent until assets are added. |
| Wire the placement sound to the snap it belongs to | done — The place, recall, and draw sounds now wait for the tile's animation to finish before they play, so the sound lands with the tile instead of ahead of it. The wait is read straight from the design tokens, so retuning an animation retunes its sound with no audio edit; a sound still pending when the app backgrounds is dropped. |
