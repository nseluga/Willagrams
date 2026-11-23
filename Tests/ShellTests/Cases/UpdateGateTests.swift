import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell

/// The update gate: the decision, what it gates, where the button goes, and
/// the visible message when a start speaks another wire version.
@MainActor
@Suite("Update gate")
struct UpdateGateTests {

    private nonisolated static func answer(_ version: String) -> Data {
        Data(#"{"resultCount":1,"results":[{"version":"\#(version)"}]}"#.utf8)
    }

    private nonisolated static func blocked(running: String, store: String) async -> Bool {
        await UpdateGate.isBlocked(running: running, lookup: { answer(store) })
    }

    // 8a
    @Test("A newer store version blocks; equal or older does not")
    func comparison() async {
        #expect(await Self.blocked(running: "1.0", store: "1.1"))
        #expect(await Self.blocked(running: "1.9", store: "1.10"))
        #expect(await Self.blocked(running: "1.0", store: "1.0.1"))
        #expect(await !Self.blocked(running: "1.0", store: "1.0"))
        #expect(await !Self.blocked(running: "1.0", store: "1.0.0"))
        #expect(await !Self.blocked(running: "1.10", store: "1.9"))
        #expect(await !Self.blocked(running: "1.2", store: "1.0"))
    }

    // 8a
    @Test("A lookup error or a malformed answer allows play")
    func failuresAllow() async {
        struct Down: Error {}
        #expect(await !UpdateGate.isBlocked(running: "1.0", lookup: { throw Down() }))
        for body in ["", "not json", "{}", #"{"results":[]}"#, #"{"results":[{"version":"x.y"}]}"#,
                     #"{"results":[{"version":7}]}"#] {
            #expect(await !UpdateGate.isBlocked(running: "1.0", lookup: { Data(body.utf8) }))
        }
        #expect(await !Self.blocked(running: "garbage", store: "2.0"))
    }

    // 8b
    @Test("When blocked, Play a Friend and Join show the prompt and Solo still starts")
    func onlyOnlineIsGated() async throws {
        let backend = FakeBackend()
        let shell = ShellModel(
            services: ShellServices(backend: backend, signIn: backend),
            updateCheck: { true }
        )
        await shell.signInTask?.value
        shell.launch()
        await shell.updateTask?.value
        #expect(shell.updateRequired)
        #expect(!shell.showsUpdatePrompt)

        #expect(!shell.playAFriend())
        #expect(shell.route == .menu)
        #expect(shell.showsUpdatePrompt)

        shell.showsUpdatePrompt = false
        #expect(!shell.showJoin())
        #expect(shell.showsUpdatePrompt)

        #expect(shell.startSoloPractice())
        #expect(shell.run != nil)
    }

    @Test("Not blocked: Play a Friend opens and no prompt shows")
    func unblockedPlays() async {
        let backend = FakeBackend()
        let shell = ShellModel(
            services: ShellServices(backend: backend, signIn: backend),
            updateCheck: { false }
        )
        await shell.signInTask?.value
        shell.launch()
        await shell.updateTask?.value
        #expect(shell.playAFriend())
        #expect(!shell.showsUpdatePrompt)
        shell.returnToMenu()
    }

    // 8c
    @Test("The Update button goes to the one shared store link")
    func updateLink() {
        #expect(ShellModel().updateLink == AppStoreLink.url)
        #expect(ShellModel().updateLink.absoluteString == "https://apps.apple.com/app/id6812609905")
    }

    // 8d
    @Test("A start on another wire version shows the latest-version message")
    func mismatchIsVisible() async throws {
        let f = try await JoinTests.make()
        let model = try await JoinTests.joinTheLobby(f)
        await JoinTests.until("the guest's session to exist") { model.session != nil }
        #expect(model.message == nil)

        f.guestWire.deliver(.start(
            version: WireFormat.current + 1, seed: 1, startingHandSize: 21,
            countdownSeconds: 3, options: .standard, roster: []
        ))
        await JoinTests.until("the mismatch message") { model.message == JoinModel.versionMismatchMessage }
        #expect(model.phase == .waiting)
        model.cancel()
    }

    @Test("A stray foreign start on a session that has begun leaves no refusal")
    func foreignStartAfterTheMatchBeganIsIgnored() async throws {
        let f = try await JoinTests.make(
            sleepFor: { _ in try await Task.sleep(for: .milliseconds(500)) })
        let model = try await JoinTests.joinTheLobby(f)
        for _ in 0..<500 { await Task.yield() }
        f.hostWire.announce(.connected(f.guest.playerID))
        await JoinTests.until("two in the host's lobby") { f.hostMatch.lobby.count == 2 }
        let hostSession = try await f.hostMatch.start()
        await JoinTests.until("the guest left the join screen") { f.shell.route != .join }
        let session = try #require(f.shell.run).session

        f.guestWire.deliver(.start(
            version: WireFormat.current + 1, seed: 1, startingHandSize: 21,
            countdownSeconds: 3, options: .standard, roster: []
        ))
        for _ in 0..<500 { await Task.yield() }
        #expect(session.optionsRefusal == nil)
        withExtendedLifetime((model, hostSession)) {}
    }

    // The app root and the prompt are SwiftUI, so the wiring is pinned in text.
    @Test("The root passes updateCheck and mounts the prompt; the prompt opens the shell's link")
    func updateWiringIsPinned() throws {
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ShellSrc").resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("App")
        func code(_ name: String) throws -> String {
            try String(contentsOf: src.appendingPathComponent(name), encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        let root = try code("WillagramsApp.swift")
        #expect(root.contains("updateCheck:"))
        #expect(root.contains("UpdatePromptView(shell: shell)"))
        #expect(try code("UpdatePromptView.swift").contains("UIApplication.shared.open(shell.updateLink)"))
    }
}
