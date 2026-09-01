//
//  AudioSettings.swift
//  Willagrams
//
//  The persisted mute *value*, and nothing else. The control the player taps
//  lives in `Willagrams/Settings/**` and reads this.
//
//  Platform-free on purpose: `UserDefaults` is Foundation, so this file — and
//  therefore the whole `Audio` target — still compiles on the macOS test host.
//

import Foundation

/// Whether the player has muted the game's sound, remembered across launches.
///
/// Owns the value only: it does not silence anything itself, and it does not
/// govern haptics — iOS already gates those through System Haptics.
///
/// The `UserDefaults` suite is injected rather than assumed so tests can hand
/// it a scratch suite instead of writing into the real preferences.
public final class AudioSettings: @unchecked Sendable {

    /// The key this class owns in the injected suite.
    public static let mutedKey = "audio.muted"

    private let defaults: UserDefaults

    /// - Parameter defaults: the suite to read and write. Callers in the app
    ///   pass `.standard`; tests pass a scratch suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Whether sound is muted. `false` on a fresh install, because
    /// `bool(forKey:)` reports `false` for a key that was never written.
    ///
    /// Read straight through to `UserDefaults` — no cached copy — so the value
    /// is correct however it changed, and `UserDefaults`' own thread safety is
    /// the only synchronisation this needs.
    public var isMuted: Bool {
        defaults.bool(forKey: Self.mutedKey)
    }

    /// Persists `muted` immediately.
    public func setMuted(_ muted: Bool) {
        defaults.set(muted, forKey: Self.mutedKey)
    }
}
