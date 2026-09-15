import Foundation
import Testing
@testable import Shell

/// iPhone is portrait everywhere but the three match screens; iPad is landscape
/// always. The UIKit half (the delegate, the geometry request) cannot run on a
/// macOS host, so its wiring is pinned against the bytes on disk.
@Suite("Orientation")
struct OrientationTests {

    @Test("isGameplay is true exactly for countdown, match and results")
    func gameplayRoutes() {
        let setup = MatchSetup(seed: 1, startingHandSize: 7, countdownSeconds: 3)
        // Every case, written out. The switch has no default, so a new case
        // stops this compiling until it is sorted onto one side.
        let routes: [AppRoute] = [
            .menu, .soloSetup, .howToPlay, .hostLobby, .join, .profile, .friends,
            .countdown(setup), .match(setup), .results(winner: nil),
        ]
        for route in routes {
            let expected: Bool
            switch route {
            case .countdown, .match, .results: expected = true
            case .menu, .soloSetup, .howToPlay, .hostLobby, .join, .profile, .friends: expected = false
            }
            #expect(route.isGameplay == expected, "\(route)")
        }
        #expect(routes.filter(\.isGameplay).count == 3)
    }

    @Test("iPhone: portrait off gameplay, landscape in it; iPad: landscape always")
    func policy() {
        #expect(OrientationPolicy.mask(isGameplay: false, isPad: false) == .portrait)
        #expect(OrientationPolicy.mask(isGameplay: true, isPad: false) == .landscape)
        #expect(OrientationPolicy.mask(isGameplay: false, isPad: true) == .landscape)
        #expect(OrientationPolicy.mask(isGameplay: true, isPad: true) == .landscape)
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Cases
        .deletingLastPathComponent()  // ShellTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    /// `ShellRootView.body` only, comments stripped.
    @Test("ShellRootView re-locks orientation whenever gameplay flips, from launch")
    func rootViewWiring() throws {
        let source = try String(
            contentsOf: Self.root.appendingPathComponent("Willagrams/Shell/ShellRootView.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "var body: some View {"))
        let end = try #require(source.range(of: "@ViewBuilder private var inviteBanner"))
        #expect(start.upperBound < end.lowerBound)
        let body = source[start.upperBound..<end.lowerBound]
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
        #expect(body.contains(".onChange(of: shell.route.isGameplay, initial: true)"))
        #expect(body.contains("OrientationLock.mask = OrientationLock.mask(isGameplay: isGameplay)"))
        #expect(body.contains(".setNeedsUpdateOfSupportedInterfaceOrientations()"))
        #expect(body.contains(".requestGeometryUpdate(.iOS(interfaceOrientations:"))
    }

    @Test("Only the iPhone plist key allows portrait")
    func plistKeys() throws {
        let pbx = try String(
            contentsOf: Self.root.appendingPathComponent("Willagrams.xcodeproj/project.pbxproj"),
            encoding: .utf8
        ).components(separatedBy: "\n")
        let iPhone = pbx.filter { $0.contains("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone") }
        let iPad = pbx.filter { $0.contains("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad") }
        #expect(iPhone.count == 2)
        #expect(iPad.count == 2)
        for line in iPhone { #expect(line.contains("UIInterfaceOrientationPortrait")) }
        for line in iPad {
            #expect(line.contains("\"UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\""))
        }
    }
}
