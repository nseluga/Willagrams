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
        #expect(body.contains(".requestGeometryUpdate("))
        #expect(body.contains(".iOS(interfaceOrientations: OrientationLock.mask)"))
        // The handler is passed by reference. An inline closure would inherit
        // the view's `@MainActor` isolation and trap when UIKit calls it off
        // the main queue, which is the iPad launch crash.
        #expect(body.contains("errorHandler: OrientationPolicy.report(rejection:)"))
        #expect(!body.contains("debugPrint"))
    }

    /// The iPad launch crash: UIKit called the rejection handler on
    /// `com.apple.root.default-qos` while the handler assumed the main actor.
    /// This runs the real reporting path off the main actor — it compiles only
    /// while `report` is `nonisolated`, and it runs only if nothing it touches
    /// asserts a queue.
    @Test("The rejection report needs no main-actor isolation")
    func rejectionReportIsNonisolated() async {
        struct Rejected: Error {}
        await Task.detached(priority: .background) {
            // `Thread.isMainThread` is unavailable from an async context; this
            // is the same question one layer down.
            #expect(pthread_main_np() == 0)
            OrientationPolicy.report(rejection: Rejected())
        }.value

        // And it is reachable as a plain function value of the type UIKit's
        // `errorHandler:` parameter takes, carrying no isolation with it.
        let handler: (any Error) -> Void = OrientationPolicy.report(rejection:)
        handler(Rejected())
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
        // Exact literal, not `contains("...Portrait")` — that also matches
        // `UIInterfaceOrientationPortraitUpsideDown`.
        for line in iPhone {
            #expect(line.contains(
                "= \"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\";"
            ))
        }
        for line in iPad {
            #expect(line.contains(
                "= \"UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\";"
            ))
        }
    }

    /// Pins the review's Important fix: the static mask starts already
    /// resolved from the policy (launch route is `.menu`, non-gameplay), not
    /// from `.all`, which would let UIKit answer "anything goes" from window
    /// creation until the first `onChange(initial:)` fires.
    @Test("The static mask starts from the policy, not .all")
    func initialMaskFromPolicy() throws {
        let source = try String(
            contentsOf: Self.root.appendingPathComponent("Willagrams/App/OrientationLock.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "static var mask: UIInterfaceOrientationMask ="))
        let end = try #require(source.range(of: "\n", range: start.upperBound..<source.endIndex))
        let declaration = source[start.upperBound..<end.lowerBound]
        #expect(declaration.contains("mask(isGameplay: false)"))
        #expect(!declaration.contains(".all"))
    }

    /// Pins the review Minor: `uiMask` and the delegate's return value are
    /// otherwise not observable from `swift test` (a UIKit type on a macOS
    /// host), so swapping either passes every other test.
    @Test("uiMask maps .portrait/.landscape literally, and the delegate returns the static mask")
    func uiMaskAndDelegateWiring() throws {
        let source = try String(
            contentsOf: Self.root.appendingPathComponent("Willagrams/App/OrientationLock.swift"),
            encoding: .utf8
        )

        let mapStart = try #require(source.range(of: "var uiMask: UIInterfaceOrientationMask {"))
        let mapEnd = try #require(source.range(of: "\n}", range: mapStart.upperBound..<source.endIndex))
        let mapping = source[mapStart.upperBound..<mapEnd.lowerBound]
        #expect(mapping.contains("case .portrait: .portrait"))
        #expect(mapping.contains("case .landscape: .landscape"))

        let sigStart = try #require(source.range(
            of: "supportedInterfaceOrientationsFor window: UIWindow?\n    ) -> UIInterfaceOrientationMask {"
        ))
        let bodyEnd = try #require(source.range(of: "\n    }", range: sigStart.upperBound..<source.endIndex))
        let delegateBody = source[sigStart.upperBound..<bodyEnd.lowerBound]
        #expect(delegateBody.contains("Self.mask"))
    }
}
