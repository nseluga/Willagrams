import Foundation
import Testing

/// Guardrails checked against the bytes on disk rather than against a comment
/// claiming them, on the `Tests/AccountTests` pattern. `FriendsSrc` is a
/// whole-directory symlink, so a single unexcluded SwiftUI file dropped into
/// `Willagrams/Friends` stops this suite building for macOS — this test fails
/// first and says why.
///
/// Every check here asserts what must be PRESENT as well as what must be
/// absent: an absence-only scan turns green when the thing it guards is renamed
/// or deleted, which is the opposite of what a guardrail is for.
///
/// Nothing here scans the repository. The directories below are reached through
/// this package's own symlinks, so a sibling worktree under `.claude/` is never
/// walked.
@Suite("Friends source guardrails")
struct SourceGuardrailTests {

    /// Built at runtime so the scanner does not match its own source.
    private static let bannedFramework = "Swift" + "UI"

    private static var casesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    private static var packageDirectory: URL {
        casesDirectory.deletingLastPathComponent()
    }

    /// `FriendsSrc`, the committed symlink to `Willagrams/Friends`.
    private static var friendsSourceDirectory: URL {
        packageDirectory.appendingPathComponent("FriendsSrc").resolvingSymlinksInPath()
    }

    private static func swiftFiles(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    private static func text(_ name: String) throws -> String {
        try String(contentsOf: friendsSourceDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    /// True when `text` has an actual import statement, not merely a comment
    /// saying it must not have one.
    private static func imports(_ framework: String, in text: String) -> Bool {
        text.components(separatedBy: "\n").contains { line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//") else { return false }
            guard code.hasPrefix("import ") || code.contains(" import ") else { return false }
            return code.contains(framework)
        }
    }

    private static var manifest: String {
        get throws {
            try String(
                contentsOf: packageDirectory.appendingPathComponent("Package.swift"),
                encoding: .utf8
            )
        }
    }

    /// The shell's manifest, which symlinks the same directory and so carries
    /// the same exclusions. A view excluded here and forgotten there breaks
    /// `Tests/ShellTests` instead of failing anything.
    private static var shellManifest: String {
        get throws {
            try String(
                contentsOf: packageDirectory
                    .deletingLastPathComponent()
                    .appendingPathComponent("ShellTests/Package.swift"),
                encoding: .utf8
            )
        }
    }

    @Test("No compiled friends source and no test pulls in SwiftUI")
    func noSwiftUIAnywhere() throws {
        let sources = try Self.swiftFiles(in: Self.friendsSourceDirectory)
        let tests = try Self.swiftFiles(in: Self.casesDirectory)
        let manifest = try Self.manifest
        let shellManifest = try Self.shellManifest

        // A scan that finds nothing because it looked nowhere proves nothing.
        #expect(sources.count >= 2, "expected the friends sources at \(Self.friendsSourceDirectory.path)")
        #expect(tests.count >= 3, "expected the test sources at \(Self.casesDirectory.path)")

        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard Self.imports(Self.bannedFramework, in: text) else { continue }
            #expect(
                manifest.contains("\"\(file.lastPathComponent)\""),
                "\(file.lastPathComponent) imports \(Self.bannedFramework) but Package.swift does not exclude it"
            )
            #expect(
                shellManifest.contains("\"\(file.lastPathComponent)\""),
                "\(file.lastPathComponent) imports \(Self.bannedFramework) but Tests/ShellTests/Package.swift does not exclude it"
            )
        }

        for file in tests {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !Self.imports(Self.bannedFramework, in: text),
                "\(file.lastPathComponent) imports \(Self.bannedFramework)"
            )
        }
    }

    /// Nothing may be excluded that does not need to be: an excluded pure source
    /// would silently drop out of the suite.
    @Test("Every excluded friends file exists and really is a view")
    func exclusionsAreViewsThatExist() throws {
        let manifest = try Self.manifest
        for file in try Self.swiftFiles(in: Self.friendsSourceDirectory) {
            guard manifest.contains("\"\(file.lastPathComponent)\"") else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                Self.imports(Self.bannedFramework, in: text),
                "\(file.lastPathComponent) is excluded but does not import \(Self.bannedFramework)"
            )
        }
        // Presence: the view this package exists to keep out is really there and
        // really excluded, so deleting either turns this red rather than green.
        #expect(manifest.contains("\"FriendsView.swift\""))
        #expect(try Self.shellManifest.contains("\"FriendsView.swift\""))
        #expect(FileManager.default.fileExists(
            atPath: Self.friendsSourceDirectory.appendingPathComponent("FriendsView.swift").path
        ))
    }

    /// `Willagrams/Friends` holds no navigation: the shell owns the route and
    /// the screen reports back through the closure it was handed.
    @Test("The friends screen knows nothing about routes")
    func holdsNoNavigation() throws {
        let sources = try Self.swiftFiles(in: Self.friendsSourceDirectory)
        #expect(sources.count >= 2, "expected the friends sources at \(Self.friendsSourceDirectory.path)")

        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.isEmpty }
                .joined(separator: "\n")
            for banned in ["AppRoute", "ShellModel", "NavigationStack", "NavigationLink", "returnToMenu"] {
                #expect(
                    !code.contains(banned),
                    "\(file.lastPathComponent) names \(banned) — routing is the shell's"
                )
            }
        }

        let view = try Self.text("FriendsView.swift")
        #expect(view.contains("let onBack: () -> Void"))
        #expect(view.contains("onBack: onBack"))
        // The one irreversible action on the screen says so before it is tapped.
        #expect(view.contains("FriendsModel.declineFootnote"))
    }

    /// The three seam calls are the only way this model touches `friendships`.
    ///
    /// Asserted on the source as well as on behaviour: a model that patched a
    /// `Friendship` it was holding would still publish the right sections for
    /// one turn, and only disagree with the database on the next read.
    @Test("The model writes only through the three seam calls")
    func writesOnlyThroughTheSeam() throws {
        let model = try Self.text("FriendsModel.swift")

        // Presence: the three calls really are the ones being made.
        for call in ["backend.friendships()", "backend.profile(id: id)",
                     "respondToFriendRequest(", "block(entry.profile.id)"] {
            #expect(model.contains(call), "FriendsModel no longer calls \(call)")
        }

        // Absence: no status is assigned, and no `Friendship` is rebuilt, on
        // this side of the seam.
        for arithmetic in [".status =", "status: .accepted", "status: .blocked",
                           "Friendship(", "respondedAt ="] {
            #expect(
                !model.contains(arithmetic),
                "FriendsModel works a friendship status out itself with \(arithmetic)"
            )
        }
    }
}
