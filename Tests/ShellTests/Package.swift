// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShellTests",
    platforms: [.iOS(.v17), .macOS(.v14)],
    // `name:` is load-bearing: a path dependency's identity is otherwise its
    // directory name, so the bare `.package(path:)` MatchTests uses resolves to
    // "shell-r1" in a worktree and the product lookup below fails.
    dependencies: [
        .package(name: "Willagrams", path: "../.."),
    ],
    targets: [
        // The app compiles `Willagrams/Match` into the same module as the shell;
        // here it is a separate one, which is what the `#if canImport(Match)`
        // in `SoloMatch.swift` exists for. Symlinked, not copied — this lane
        // consumes those files and never edits them.
        //
        // The two SDK-free `Willagrams/Online` files join it rather than forming
        // a target of their own: the app compiles Match and Online into one
        // module, so those files carry no `import Match`, and a second target
        // would need imports the app does not want. `BackendClient`, `Profile`
        // and `FakeBackend` therefore arrive through `import Match` here, and
        // through no import at all in the app. The rest of Online needs the
        // Supabase SDK and stays out — `Tests/OnlineTests` owns it.
        .target(
            name: "Match",
            dependencies: [
                .product(name: "WillagramsRules", package: "Willagrams"),
            ],
            path: ".",
            // `OnlineMatch` and the recorder seam join the two originals: the
            // host lobby calls the façade directly, so the shell cannot be
            // tested without it. All four are SDK-free — the one place
            // `OnlineMatch` names `SupabaseBackend` is fenced on
            // `canImport(PostgREST)`, which is false here and true in the app.
            sources: [
                "MatchSrc",
                "OnlineSrc/BackendContracts.swift",
                "OnlineSrc/FakeBackend.swift",
                "OnlineSrc/MatchOutcomeRecorder.swift",
                "OnlineSrc/OnlineMatch.swift",
            ]
        ),
        // `SystemAudioPlayer` imports AVFoundation and UIKit and cannot build
        // for macOS; the seam, the catalogue and the settings can.
        .target(name: "Audio", path: "AudioSrc", exclude: ["SystemAudioPlayer.swift"]),
        // Only the model half: both files under `Views` are SwiftUI.
        .target(
            name: "Settings",
            dependencies: [.product(name: "WillagramsRules", package: "Willagrams")],
            path: "SettingsSrc",
            exclude: ["Views/MatchOptionsView.swift", "Views/RulesInForceView.swift"]
        ),
        // One file, symlinked in: `Terminology` is the frozen IP fence and the
        // countdown's title comes from it. The rest of `Willagrams/Style` is
        // SwiftUI and cannot build for this target, which is why this is a
        // directory of file symlinks rather than a symlink to the directory.
        .target(name: "Style", path: "StyleSrc"),
        // The pure, macOS-buildable half of `Willagrams/Board` — the same eight
        // files, symlinked, that this package already compiled. `BoardFeedback`
        // imports UIKit and `BoardPinch`/`BoardView` import SwiftUI, so none of
        // those three can join a macOS target. Named `BoardKit`, not `Board`:
        // `Board` is a type in `WillagramsRules` and a module of that name would
        // shadow it at every use site. See `#if canImport(BoardKit)` in
        // `MatchBoard.swift`.
        .target(
            name: "BoardKit",
            dependencies: [.product(name: "WillagramsRules", package: "Willagrams")],
            path: "BoardSrc"
        ),
        // The bot is the far end of every solo match now, so `SoloMatch` names
        // `BotMatch`, `BotBrain` and `BotDifficulty`. Same symlink pattern and
        // same exclude as `Tests/BotTests`: `BotDifficultyView` is SwiftUI.
        .target(
            name: "Bot",
            dependencies: ["Match", .product(name: "WillagramsRules", package: "Willagrams")],
            path: "BotSrc",
            exclude: ["BotDifficultyView.swift"]
        ),
        .target(
            name: "Shell",
            dependencies: ["Match", "Style", "BoardKit", "Bot", "Audio", "Settings", .product(name: "WillagramsRules", package: "Willagrams")],
            path: "ShellSrc",
            // The macOS test build has no SwiftUI. Every view file in
            // `Willagrams/Shell` must be listed here, and `SourceGuardrailTests`
            // fails if this list and the files that import SwiftUI disagree.
            exclude: [
                "ShellRootView.swift", "MenuView.swift", "CountdownView.swift",
                "MatchHUD.swift", "MatchView.swift", "ResultsView.swift",
                "HowToPlayView.swift", "SoloSetupView.swift", "HostLobbyView.swift",
            ]
        ),
        .testTarget(
            name: "ShellTests",
            dependencies: ["Shell", "Match", "Style", "BoardKit", "Bot", "Audio", "Settings"],
            path: "Cases"
        ),
    ]
)
