//
//  ShellSignInSupabase.swift
//  Willagrams
//
//  The only `#if DEBUG` in the shell. It fences the anonymous session itself —
//  never a route, never a screen — so a Release build contains no reference to
//  `signInAnonymously` and simply has no sign-in to offer.
//

#if canImport(Match)
import Match
#endif

// `Tests/ShellTests` compiles the two SDK-free `Online` files and not the
// Supabase client, so `SupabaseBackend` is absent there. Same portability
// fence the shell already uses for `#if canImport(Match)`; the app and
// `xcodebuild` compile everything below it.
#if canImport(Auth)

#if DEBUG
extension SupabaseBackend: ShellSignIn {
    public func signIn() async throws -> Profile {
        try await signInAnonymously()
    }
}
#endif

extension ShellServices {

    /// The sign-in this build can offer: the anonymous session in Debug, none
    /// in Release. The caller passes the result straight to ``init`` and holds
    /// no conditional of its own.
    #if DEBUG
    public static func anonymousSignIn(_ backend: SupabaseBackend) -> (any ShellSignIn)? { backend }
    #else
    public static func anonymousSignIn(_ backend: SupabaseBackend) -> (any ShellSignIn)? { nil }
    #endif
}

#endif
