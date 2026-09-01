#!/bin/bash
# Smoke-runs SystemAudioPlayer on a booted simulator. The macOS gate cannot
# reach the type — it is behind `#if canImport(UIKit)` — so this is where the
# player is actually executed. Run from the repo root.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
mkdir -p "$out/empty.bundle"
export SIMCTL_CHILD_SMOKE_EMPTY_BUNDLE="$out/empty.bundle"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
# -D DEBUG: the harness reads the voice pool through the player's `#if DEBUG`
# queue-confined accessor, so the assertions cannot race `preload`/`emit`.
xcrun -sdk iphonesimulator swiftc -D DEBUG -target arm64-apple-ios17.0-simulator -sdk "$sdk" \
  "$here/../../../Willagrams/Audio/AudioPlayer.swift" \
  "$here/../../../Willagrams/Audio/AudioCatalogue.swift" \
  "$here/../../../Willagrams/Audio/SystemAudioPlayer.swift" \
  "$here/main.swift" -o "$out/smoke"
dev="$(xcrun simctl list devices available | grep -m1 'iPhone 1' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
xcrun simctl boot "$dev" 2>/dev/null || true
xcrun simctl spawn "$dev" "$out/smoke"
