import Foundation
import Testing

/// Two fences checked against every byte under `Willagrams/`, not against a
/// comment claiming them: the Release build must contain no anonymous sign-in,
/// and exactly one place in the app may build a service.
///
/// Both scans assert the symbols they hunt for are actually present somewhere,
/// so a rename that slipped past the greps turns them red instead of green.
@Suite("Service and sign-in fences")
struct ServiceFenceTests {


    /// Spelled in pieces so this file is not itself a hit.
    private static let signIn = "signIn" + "Anonymously"
    private static let debugFence = "#if " + "DEBUG"

    /// `Willagrams/`, reached through the committed `ShellSrc` symlink.
    private static var appSourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ShellSrc")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
    }

    private static func swiftFiles() throws -> [URL] {
        let root = appSourceDirectory
        let found = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        // A scan that finds nothing because it looked nowhere proves nothing.
        #expect(found.count > 20, "expected the app sources under \(root.path)")
        return found
    }

    private static func text(of file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    /// Prose naming a symbol is not a call to it, and every file here documents
    /// the fences in its header.
    private static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// The code lines of `text` that sit inside a `#if DEBUG` region, and those
    /// that do not. Nesting is counted, so a `#if DEBUG` inside another
    /// conditional is still recognised as fenced, and the `#else` half of one is
    /// not — that half is the Release build.
    private static func debugFencedLines(_ text: String) -> (inside: [String], outside: [String]) {
        var depth = 0
        var debugDepths: Set<Int> = []
        var inside: [String] = []
        var outside: [String] = []

        for line in text.components(separatedBy: "\n") where !isComment(line) {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("#if") {
                depth += 1
                if code == debugFence { debugDepths.insert(depth) }
                continue
            }
            if code.hasPrefix("#endif") {
                debugDepths.remove(depth)
                depth -= 1
                continue
            }
            if code.hasPrefix("#else") || code.hasPrefix("#elseif") {
                debugDepths.remove(depth)
                continue
            }
            if debugDepths.isEmpty { outside.append(line) } else { inside.append(line) }
        }
        return (inside, outside)
    }

    @Test("Anonymous sign-in exists, and only inside a #if DEBUG region")
    func signInIsDebugOnly() throws {
        var mentions = 0
        for file in try Self.swiftFiles() {
            let text = try Self.text(of: file)
            guard text.contains(Self.signIn) else { continue }
            let (inside, outside) = Self.debugFencedLines(text)
            mentions += inside.filter { $0.contains(Self.signIn) }.count
            for line in outside where line.contains(Self.signIn) {
                Issue.record(
                    "\(file.lastPathComponent) calls \(Self.signIn) outside \(Self.debugFence): \(line.trimmingCharacters(in: .whitespaces))"
                )
            }
        }
        // Falsifiability: rename the symbol and this fails rather than passing
        // on a scan that now matches nothing.
        #expect(mentions >= 2, "expected \(Self.signIn) on the backend and on the shell's conformance")
    }

    /// The guardrail is about routes, not about every Debug affordance: the
    /// style gallery MenuView opens on a long press predates this item and is
    /// not a route. These four files are the ones that own routes and the
    /// launch path, and none of them may branch on the build configuration.
    @Test("No #if DEBUG fences a route, the route switch, or the launch path")
    func debugFencesNoRoute() throws {
        let routeOwners = [
            "Shell/AppRoute.swift", "Shell/ShellModel.swift",
            "Shell/ShellRootView.swift", "App/WillagramsApp.swift",
        ]
        for relative in routeOwners {
            let file = Self.appSourceDirectory.appendingPathComponent(relative)
            let directives = try Self.text(of: file)
                .components(separatedBy: "\n")
                .filter { !Self.isComment($0) }
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(Self.debugFence) }
            #expect(directives.isEmpty, "\(relative) fences code behind \(Self.debugFence)")
        }

        // Falsifiability: the one file that may carry the fence still does, so
        // deleting the conformance fails here instead of passing silently.
        let fence = Self.appSourceDirectory.appendingPathComponent("Shell/ShellSignInSupabase.swift")
        let fenceDirectives = try Self.text(of: fence)
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(Self.debugFence) }
        #expect(fenceDirectives.count >= 1)
    }

    @Test("Only the app root constructs a backend, a player or a settings store")
    func onlyTheRootBuildsServices() throws {
        let constructors = ["SupabaseBackend(", "SystemAudioPlayer(", "SettingsStore(defaults:"]
        let root = "WillagramsApp.swift"

        for file in try Self.swiftFiles() where file.lastPathComponent != root {
            let text = try Self.text(of: file)
            for constructor in constructors {
                let hits = text.components(separatedBy: "\n").filter {
                    !Self.isComment($0) && $0.contains(constructor)
                }
                #expect(hits.isEmpty, "\(file.lastPathComponent) constructs \(constructor)")
            }
        }

        // Falsifiability: the root builds all three, so a rename of any of them
        // fails here instead of quietly matching nothing above.
        let appRoot = try Self.text(
            of: Self.appSourceDirectory.appendingPathComponent("App").appendingPathComponent(root)
        )
        for constructor in constructors {
            #expect(appRoot.contains(constructor), "\(root) no longer constructs \(constructor)")
        }
    }

    /// Constructing the player is not the same as handing it over. `ShellServices`
    /// defaults `audio:` to a silent player, so dropping the argument at the root
    /// mutes the shipping app while every cue test still passes against its own
    /// hand-built player. Assert the argument itself.
    @Test("The root hands its player to ShellServices")
    func theRootInjectsItsPlayer() throws {
        let appRoot = try Self.text(
            of: Self.appSourceDirectory
                .appendingPathComponent("App")
                .appendingPathComponent("WillagramsApp.swift")
        )
        let lines = appRoot.components(separatedBy: "\n").filter { !Self.isComment($0) }
        let built = lines.first { $0.contains("let audio = SystemAudioPlayer(") }
        #expect(built != nil, "the root no longer binds its player to `audio`")
        #expect(
            lines.contains { $0.contains("audio: audio") },
            "the root builds a player but does not pass it to ShellServices, so the app ships silent"
        )

        // The player must come up in the state the player left it in. A rename
        // of either symbol fails here rather than shipping a launch that
        // forgets mute.
        #expect(
            built?.contains("muted: AudioSettings(defaults: .standard).isMuted") == true,
            "the root no longer builds its player muted from AudioSettings"
        )
    }

    /// The toggle has to be on the menu, not merely on the model. `MenuView` is
    /// SwiftUI and so is excluded from this target's sources — the bytes on
    /// disk are all this can check.
    @Test("The menu carries the mute toggle")
    func theMenuCarriesTheMuteToggle() throws {
        let menu = Self.appSourceDirectory
            .appendingPathComponent("Shell")
            .appendingPathComponent("MenuView.swift")
        let lines = try Self.text(of: menu)
            .components(separatedBy: "\n")
            .filter { !Self.isComment($0) }
        #expect(lines.count > 50, "expected MenuView.swift at \(menu.path)")

        for symbol in [
            "shell.toggleMute()", "shell.isMuted", ".accessibilityLabel(",
            "\"Sound on\"", "\"Sound off\"",
        ] {
            #expect(lines.contains { $0.contains(symbol) }, "MenuView.swift no longer has \(symbol)")
        }
    }
}
