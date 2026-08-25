# Willagrams — audio lane — Progress

LANE.md is the contract; this tracks where we are in it — if they disagree,
LANE.md wins for scope.

## Current position

- **Status:** in progress
- **Next:** Build `SystemAudioPlayer` (`caution: true`)
- **Blockers:** none
- **Last updated:** 2026-08-25 13:50

## Round 2 — sound and haptics

| Item | Status |
|------|--------|
| Build the effect catalogue (`AudioCatalogue.swift`) | done — Every game moment now has a defined sound, volume, and haptic in one file, so a tenth sound effect would fail to compile until someone decides what it sounds like. |
| Build the mute state and its persistence (`AudioSettings.swift`) | done — The app can now remember whether sound is muted between launches; new installs start unmuted. |
| Build `SystemAudioPlayer` (real playback + haptics, respects silent switch) | not started |
| Wire the placement sound to the snap it belongs to | not started |
