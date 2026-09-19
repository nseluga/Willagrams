//
//  ShellSignInSupabase.swift
//  Willagrams
//
//  The app's whole sign-in: an anonymous Supabase session, with no screen, no
//  email and no password. It is what puts a `Profile` behind the friend-code
//  and username flow, and `ShellModel.canPlayOnline` is false without it.
//
//  It was fenced behind `#if DEBUG` until the App Store build was tried, which
//  meant a Release build had no sign-in at all and could not play a friend.
//  The fence carried no rationale and was never a policy — it arrived inside a
//  checkpoint commit — so it is gone. The only fence left here is the
//  portability one below.
//
//  ponytail: an anonymous session lives on one device. A reinstall or a new
//  phone loses the username and the friends list with no way back. Sign in with
//  Apple is the upgrade path, deferred in FOUNDATION.md.
//

#if canImport(Match)
import Match
#endif

// `Tests/ShellTests` compiles the two SDK-free `Online` files and not the
// Supabase client, so `SupabaseBackend` is absent there. Same portability
// fence the shell already uses for `#if canImport(Match)`; the app and
// `xcodebuild` compile everything below it.
#if canImport(Auth)

extension SupabaseBackend: ShellSignIn {
    public func signIn() async throws -> Profile {
        try await signInAnonymously()
    }
}

extension ShellServices {

    /// The sign-in every build offers. The caller passes the result straight to
    /// ``init`` and holds no conditional of its own — it stays optional because
    /// `ShellServices` takes an optional and a build without the SDK has none.
    public static func anonymousSignIn(_ backend: SupabaseBackend) -> (any ShellSignIn)? { backend }
}

#endif
