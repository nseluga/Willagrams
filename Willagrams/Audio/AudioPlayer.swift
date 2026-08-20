//
//  AudioPlayer.swift
//  Willagrams
//
//  The seam every screen calls to make a sound, pinned by `/foundation` so the
//  shell can wire its call sites before the `audio` lane exists.
//
//  Deliberately platform-free: no AVFoundation, no CoreHaptics, no SwiftUI.
//  The `audio` lane adds concrete players beside this file; it does not edit
//  this file, which is `protected:` in MAP.md.
//

import Foundation

/// Every sound the game makes. One case per moment, not per asset — the
/// `audio` lane decides what each one plays, and may play nothing.
public enum SoundEffect: String, Sendable, CaseIterable {
    /// A tile lands on the board and snaps to the lattice.
    case tilePlace
    /// A tile is pulled back off the board into the hand.
    case tileRecall
    /// Draw succeeded and new tiles arrived.
    case draw
    /// A tile went back to the Pool and three came out.
    case swap
    /// The board holds a word the dictionary refuses, or Draw was denied.
    case invalid
    /// One second of the pre-match countdown.
    case countdownTick
    /// This device won.
    case win
    /// Somebody else won.
    case loss
    /// Any menu button, anywhere outside a match.
    case menuTap
}

/// How hard a haptic should hit. Maps onto the platform's impact generators in
/// the concrete player; meaningless on a device with no haptic engine.
public enum HapticStrength: Sendable, Equatable {
    case light
    case medium
    case heavy
}

/// Plays the game's sounds and haptics.
///
/// ## Why nothing here is `async` or `throws`
///
/// Every call site is a UI event handler on the main actor — a tile landing, a
/// button tap. Making a sound `await`able would put a `Task { }` around each of
/// them, and making it throwing would put a `do`/`catch` around each of them,
/// for a failure no player can act on. A missing asset, a busy audio session
/// and a silent switch are all the same outcome: no sound, and the game
/// continues. The concrete player absorbs them.
///
/// Conformers must therefore return immediately and do their real work
/// elsewhere. `play` is called inside animations.
public protocol AudioPlayer: Sendable {

    /// Whether sound is currently suppressed. Reflects the last `setMuted`.
    ///
    /// This is the player's own mute, not the system silent switch — a
    /// concrete player may stay silent for the switch while this reads `false`.
    var isMuted: Bool { get }

    /// Plays `effect`, or does nothing if muted. Never blocks the caller.
    func play(_ effect: SoundEffect)

    /// Fires a haptic of `strength`, or does nothing if muted. Never blocks.
    func impact(_ strength: HapticStrength)

    /// Turns this player's own sound and haptics on or off.
    func setMuted(_ muted: Bool)
}

/// An `AudioPlayer` that makes no sound.
///
/// **Ships in Release, not behind `#if DEBUG`.** It is the value every screen
/// holds until the `audio` lane replaces it, so the app is silent rather than
/// broken while that lane is unbuilt. It still tracks `isMuted` so a mute
/// control built against it behaves correctly before there is anything to mute.
public final class SilentAudioPlayer: AudioPlayer, @unchecked Sendable {

    private let lock = NSLock()
    private var muted = false

    public init(muted: Bool = false) {
        self.muted = muted
    }

    public var isMuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return muted
    }

    public func play(_ effect: SoundEffect) {}

    public func impact(_ strength: HapticStrength) {}

    public func setMuted(_ muted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.muted = muted
    }
}
