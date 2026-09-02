//
//  SupabaseConfig.swift
//  Willagrams
//
//  Where the project lives. The anon key is publishable, but it is still not
//  committed: it arrives from the environment, so a fork of this repo cannot
//  spend our quota by accident.
//

import Foundation

public enum SupabaseConfig {
    public static let url = URL(string: "https://ynkayuwwrifluhhqnrjc.supabase.co")!
    public static let anonKey = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"] ?? ""
}
