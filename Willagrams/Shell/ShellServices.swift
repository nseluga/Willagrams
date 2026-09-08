//
//  ShellServices.swift
//  Willagrams
//
//  The app's long-lived services, built once at the root and handed down.
//  Nothing here reaches for a service; `WillagramsApp` is the only place that
//  constructs one.
//

#if canImport(Match)
import Match
#endif
#if canImport(Audio)
import Audio
#endif
#if canImport(Settings)
import Settings
#endif

import Foundation

/// The one sign-in the shell knows how to run.
///
/// It exists because `signInAnonymously()` lives on the concrete
/// `SupabaseBackend` and only in Debug: a protocol with one requirement is what
/// lets the Release build carry no sign-in at all rather than a call site
/// fenced off with `#if DEBUG`.
public protocol ShellSignIn: Sendable {
    func signIn() async throws -> Profile
}

/// Every service the shell was given. A plain value, not a container: one
/// backend, one player, one settings store, and whether this build can sign in.
///
/// `backend` and `settings` are optional so a model built with no services —
/// every existing routing test — needs no stand-in for them. A screen that
/// needs one is disabled without it, which is the same state a failed sign-in
/// leaves the menu in.
public struct ShellServices {

    public let backend: (any BackendClient)?
    public let audio: any AudioPlayer
    public let settings: SettingsStore?

    /// Where the mute value is remembered across launches. Defaulted to the
    /// real suite because that is what the root passes — a test that asserts
    /// mute injects its own named scratch suite instead.
    public let audioSettings: AudioSettings

    /// Nil in Release, and in any build that chooses not to offer one.
    public let signIn: (any ShellSignIn)?

    /// Builds the signed-in player's invite channel, given their id.
    ///
    /// A factory rather than a channel: the topic is named for the local user,
    /// who is not known until sign-in lands, and nothing may open a channel
    /// before then. Nil in a build with no realtime behind it, which is a shell
    /// that simply never receives an invite.
    public let inviteChannel: (@Sendable (UUID) -> any MatchInviteChannel)?

    public init(
        backend: (any BackendClient)? = nil,
        audio: any AudioPlayer = SilentAudioPlayer(),
        settings: SettingsStore? = nil,
        audioSettings: AudioSettings = AudioSettings(defaults: .standard),
        signIn: (any ShellSignIn)? = nil,
        inviteChannel: (@Sendable (UUID) -> any MatchInviteChannel)? = nil
    ) {
        self.backend = backend
        self.audio = audio
        self.settings = settings
        self.audioSettings = audioSettings
        self.signIn = signIn
        self.inviteChannel = inviteChannel
    }
}
