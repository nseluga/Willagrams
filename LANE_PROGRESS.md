# Willagrams — audio lane — Progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** in progress
- **Next:** Wire the placement sound to the snap it belongs to
- **Blockers:** none
- **Last updated:** 2026-08-25 14:35

## Round 2 — sound and haptics

| Item | Status |
|------|--------|
| Build the effect catalogue (`AudioCatalogue.swift`) | done — Every game moment now has a defined sound, volume, and haptic in one file, so a tenth sound effect would fail to compile until someone decides what it sounds like. |
| Build the mute state and its persistence (`AudioSettings.swift`) | done — The app can now remember whether sound is muted between launches; new installs start unmuted. |
| Build `SystemAudioPlayer` (real playback + haptics, respects silent switch) | done — The game can now actually play sound and haptics through the system, without ever overriding the phone's silent switch. Flagged for human review (`caution: true`): behaviorally verified on a simulator (no physical Taptic Engine or silent-switch hardware to test against), and no sound files exist yet so every sound is still silent until assets are added. |
| Wire the placement sound to the snap it belongs to | not started |
