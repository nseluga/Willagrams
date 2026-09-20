//
//  SupabaseConfig.swift
//  Willagrams
//
//  Where the project lives. The anon key is publishable, but it is still not
//  committed: a test run gets it from the environment, and a device build
//  gets it from Info.plist, where Config/Secrets.local.xcconfig (gitignored)
//  put it at build time. The environment wins so a test can point at a
//  different project without rebuilding.
//

import Foundation

public enum SupabaseConfig {
    public static let url = URL(string: "https://ynkayuwwrifluhhqnrjc.supabase.co")!
    public static let anonKey: String = {
        if let env = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"], !env.isEmpty {
            return env
        }
        return Bundle.main.infoDictionary?["SupabaseAnonKey"] as? String ?? ""
    }()
}
