//
//  AudioCatalogue.swift
//  Willagrams
//
//  The one place that decides what a moment sounds like. The player below it
//  just plays what it is handed — it never names an asset or picks a volume.
//
//  Foundation only, by design: this file compiles on the macOS test host, so
//  an AVFoundation or UIKit import here would break the audio test gate.
//

import Foundation

/// What one `SoundEffect` actually plays, and how hard it feels.
public struct AudioCue: Sendable, Equatable {

    /// Bundle resource name — lowercase, no extension. The asset files do not
    /// exist yet; these names are what fixes them.
    public let assetName: String

    /// Relative loudness in `0...1`, before the player's own mute or the
    /// system volume. Repeating cues sit below one-shot cues on purpose.
    public let volume: Float

    /// The haptic fired alongside the sound, or `nil` for a sound-only cue.
    public let haptic: HapticStrength?

    public init(assetName: String, volume: Float, haptic: HapticStrength?) {
        self.assetName = assetName
        self.volume = volume
        self.haptic = haptic
    }
}

/// The effect table. Adding a tenth `SoundEffect` case is a compile error here
/// rather than a silent silence — hence the `switch` with no `default:`.
public enum AudioCatalogue {

    public static func cue(for effect: SoundEffect) -> AudioCue {
        switch effect {
        case .tilePlace:
            // Fires on every tile drop, so it stays under the one-shots.
            return AudioCue(assetName: "tile-place", volume: 0.55, haptic: .light)
        case .tileRecall:
            return AudioCue(assetName: "tile-recall", volume: 0.45, haptic: .light)
        case .draw:
            return AudioCue(assetName: "draw", volume: 0.7, haptic: .medium)
        case .swap:
            return AudioCue(assetName: "swap", volume: 0.7, haptic: .medium)
        case .invalid:
            // Rejection has to land, so it is loud and hits harder than a place.
            return AudioCue(assetName: "invalid", volume: 0.8, haptic: .medium)
        case .countdownTick:
            // Repeats once a second; deliberately quieter than `win`.
            return AudioCue(assetName: "countdown-tick", volume: 0.4, haptic: nil)
        case .win:
            return AudioCue(assetName: "win", volume: 1.0, haptic: .heavy)
        case .loss:
            return AudioCue(assetName: "loss", volume: 0.85, haptic: .heavy)
        case .menuTap:
            return AudioCue(assetName: "menu-tap", volume: 0.5, haptic: .light)
        }
    }
}
