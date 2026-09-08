import Foundation
import Testing

/// Guardrails checked against the bytes on disk rather than against a comment
/// claiming them, on the `Tests/ShellTests` pattern. `AccountSrc` is a
/// whole-directory symlink, so a single unexcluded SwiftUI file dropped into
/// `Willagrams/Account` stops this suite building for macOS — this test fails
/// first and says why.
///
/// Every check here asserts what must be PRESENT as well as what must be
/// absent: an absence-only scan turns green when the thing it guards is
/// renamed or deleted, which is the opposite of what a guardrail is for.
///
/// Nothing here scans the repository. The two directories below are reached
/// through this package's own symlinks, so a sibling worktree under `.claude/`
/// is never walked.
@Suite("Account source guardrails")
struct SourceGuardrailTests {

    /// Built at runtime so the scanner does not match its own source.
    private static let bannedFramework = "Swift" + "UI"

    private static var casesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    /// `AccountSrc`, the committed symlink to `Willagrams/Account`.
    private static var accountSourceDirectory: URL {
        casesDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AccountSrc")
            .resolvingSymlinksInPath()
    }

    private static func swiftFiles(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    private static func text(_ name: String) throws -> String {
        try String(contentsOf: accountSourceDirectory.appendingPathComponent(name), encoding: .utf8)
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

    /// This package's manifest, the single list of account files this target
    /// does not compile.
    private static var manifest: String {
        get throws {
            try String(
                contentsOf: casesDirectory
                    .deletingLastPathComponent()
                    .appendingPathComponent("Package.swift"),
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
                contentsOf: casesDirectory
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("ShellTests/Package.swift"),
                encoding: .utf8
            )
        }
    }

    @Test("No compiled account source and no test pulls in SwiftUI")
    func noSwiftUIAnywhere() throws {
        let sources = try Self.swiftFiles(in: Self.accountSourceDirectory)
        let tests = try Self.swiftFiles(in: Self.casesDirectory)
        let manifest = try Self.manifest
        let shellManifest = try Self.shellManifest

        // A scan that finds nothing because it looked nowhere proves nothing.
        #expect(sources.count >= 2, "expected the account sources at \(Self.accountSourceDirectory.path)")
        #expect(tests.count >= 2, "expected the test sources at \(Self.casesDirectory.path)")

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
    @Test("Every excluded account file exists and really is a view")
    func exclusionsAreViewsThatExist() throws {
        let manifest = try Self.manifest
        for file in try Self.swiftFiles(in: Self.accountSourceDirectory) {
            guard manifest.contains("\"\(file.lastPathComponent)\"") else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                Self.imports(Self.bannedFramework, in: text),
                "\(file.lastPathComponent) is excluded but does not import \(Self.bannedFramework)"
            )
        }
        // Presence: the view this package exists to keep out is really there and
        // really excluded, so deleting either turns this red rather than green.
        #expect(manifest.contains("\"ProfileView.swift\""))
        #expect(FileManager.default.fileExists(
            atPath: Self.accountSourceDirectory.appendingPathComponent("ProfileView.swift").path
        ))
    }

    /// `Willagrams/Account` holds no navigation: the shell owns the route and
    /// the screen reports back through the closure it was handed.
    @Test("The account screen knows nothing about routes")
    func holdsNoNavigation() throws {
        let sources = try Self.swiftFiles(in: Self.accountSourceDirectory)
        #expect(sources.count >= 2, "expected the account sources at \(Self.accountSourceDirectory.path)")

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

        // Presence, so deleting the way out turns this red: the view takes its
        // exit as a closure and hands it to the header.
        let view = try Self.text("ProfileView.swift")
        #expect(view.contains("let onBack: () -> Void"))
        #expect(view.contains("onBack: onBack"))
    }

    /// The stats are the row as read. A derived number — a rate, an average, a
    /// total — would be a number that can disagree with the database that ranks
    /// it, so the model may name a `profile` field and format it and nothing
    /// else.
    @Test("No stat is worked out on the client")
    func statsAreNotComputed() throws {
        let model = try Self.text("ProfileModel.swift")

        // Presence first: the four fields really are read here.
        for field in ["profile.matchesPlayed", "profile.matchesWon", "profile.tilesPlaced", "profile.fastestWinSeconds"] {
            #expect(model.contains(field), "ProfileModel no longer reads \(field)")
        }

        // The body of `stats` alone, comments dropped: the block ends at the
        // first line that closes it at member indentation.
        let lines = model.components(separatedBy: "\n")
        let start = try #require(
            lines.firstIndex { $0.contains("var stats: [ProfileStat] {") },
            "ProfileModel no longer publishes a stats table"
        )
        let end = try #require(
            lines[start...].dropFirst().firstIndex { $0 == "    }" },
            "the stats table is not closed at member indentation"
        )
        let statsBlock = lines[start...end]
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(statsBlock.contains("ProfileStat("), "the stats block scan found no rows")

        for arithmetic in [" / ", " * ", " + ", " - ", "Double(", "percent"] {
            #expect(
                !statsBlock.contains(arithmetic),
                "the stats table works something out with \(arithmetic)"
            )
        }
    }

    /// The clamp is client-side and matches the column. Asserted on the source
    /// as well as on behaviour, because the behavioural test would still pass if
    /// the range were re-derived somewhere else and the two drifted apart.
    @Test("One clamp, named once, matching the column check")
    func oneClamp() throws {
        let model = try Self.text("ProfileModel.swift")
        #expect(model.contains("public static let nameLength = 1...24"))
        // Two uses and one definition: `canSave` and `save()` ask the same
        // question of the same constant.
        #expect(model.components(separatedBy: "Self.nameLength.contains").count == 3)
    }
}
