import Foundation
import Testing

// `SystemAudioPlayer` is iOS-only, so its delay table cannot be exercised on
// the macOS test host — the whole file is behind `#if canImport(UIKit)`.
//
// What *is* checkable here is the property the delay table exists to protect:
// the timings are read from `DesignTokens.Motion`, never copied. A literal
// `0.16` or `0.45` under `Willagrams/Audio/**` is the drift this guards.

@Suite("Audio timing source")
struct AudioTimingSourceTests {

    /// `Cases/` sits beside `AudioSrc`, which is a directory symlink to
    /// `Willagrams/Audio`. Resolved from `#filePath` so this works from any cwd.
    private static func audioSources(_ file: String = #filePath) throws -> [(String, String)] {
        let dir = URL(fileURLWithPath: file)
            .deletingLastPathComponent()   // Cases
            .deletingLastPathComponent()   // AudioTests
            .appendingPathComponent("AudioSrc")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
        return try names.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
    }

    @Test("The audio lane holds no copy of an animation duration")
    func noTimingLiterals() throws {
        let sources = try Self.audioSources()
        #expect(!sources.isEmpty, "AudioSrc resolved to nothing — the symlink moved")
        for (name, text) in sources {
            // `volume: 0.45` in the catalogue is a loudness, not a duration, and
            // collides with `dealDuration` only by coincidence.
            let timings = text.replacingOccurrences(
                of: #"volume: [0-9.]+"#, with: "", options: .regularExpression)
            #expect(!timings.contains("0.16"), "\(name) copies Motion.snapDuration as a literal")
            #expect(!timings.contains("0.45"), "\(name) copies Motion.dealDuration as a literal")
        }
    }

    @Test("The delayed cues read their timing from the design tokens")
    func delaysReadFromTokens() throws {
        let player = try #require(try Self.audioSources().first { $0.0 == "SystemAudioPlayer.swift" }?.1)
        #expect(player.contains("DesignTokens.Motion.snapDuration"))
        #expect(player.contains("DesignTokens.Motion.dealDuration"))
        // The Style reference must stay inside the UIKit guard, or this whole
        // package stops compiling on the host.
        let guardIndex = try #require(player.range(of: "#if canImport(UIKit)")).lowerBound
        let motionIndex = try #require(player.range(of: "DesignTokens.Motion")).lowerBound
        #expect(guardIndex < motionIndex)
    }
}
