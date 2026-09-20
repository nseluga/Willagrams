import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell

/// The seam that lets `MatchRun` run a match it did not build.
///
/// Every assertion here is about a run driven through ``MatchOpponent`` alone:
/// the same countdown → match → results walk the solo path makes, and the
/// down-before-up teardown order — the old opponent's `leave()` before the next
/// one is *constructed*, which the weak "alive count" check in `RematchTests`
/// cannot see, because deallocation and teardown are not the same moment.
@MainActor
@Suite("Match opponent seam")
struct MatchOpponentTests {

    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal

    /// One list both opponents and the test share, in construction order.
    final class Log {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
    }

    /// A far end that is a real host-side `MatchSession` on a `FakeTransport`
    /// pair and nothing else: no bot, no brain, no peer answering. It records
    /// when it was built and when it was left.
    final class RecordingOpponent: MatchOpponent {

        static let localID = PlayerID(rawValue: "aaa")
        static let peerID = PlayerID(rawValue: "zzz")

        let session: MatchSession
        let name: String
        let log: Log
        /// The far half of the wire. Held so it is not deallocated under the
        /// session, the way `SoloMatch` holds its bot.
        let peerWire: FakeTransport
        private let setup: MatchSetup

        init(_ name: String, setup: MatchSetup, dictionary: some WordList, log: Log) {
            self.name = name
            self.log = log
            self.setup = setup
            // The local end is host, as it is in solo: `startMatch` no-ops for
            // anyone else and this double would then never deal.
            let (localWire, peerWire) = FakeTransport.pair(Self.localID, Self.peerID)
            self.peerWire = peerWire
            self.session = MatchSession(
                transport: localWire,
                peerPlayerID: Self.peerID,
                dictionary: dictionary,
                // Never a wall clock: a leaked countdown aborts the whole test
                // process in `MatchSession.deinit`.
                sleepFor: { _ in }
            )
            log.record("build \(name)")
        }

        func start() {
            session.startMatch(
                seed: setup.seed,
                startingHandSize: setup.startingHandSize,
                countdownSeconds: setup.countdownSeconds,
                options: setup.options
            )
        }

        func leave() {
            log.record("leave \(name)")
            session.leave()
        }
    }

    static let setup = MatchSetup(seed: 4_242, startingHandSize: 5, countdownSeconds: 3)

    static func shell() -> ShellModel {
        ShellModel(dictionary: { EveryWordIsReal() }, sleepFor: { _ in })
    }

    // MARK: - The double walks the solo path's routes

    @Test("A run built from an opponent it did not make walks countdown → match → results")
    func aBorrowedOpponentWalksEveryRoute() async throws {
        let shell = Self.shell()
        let log = Log()
        let setup = Self.setup

        #expect(
            shell.startMatch(setup) {
                RecordingOpponent("A", setup: setup, dictionary: EveryWordIsReal(), log: log)
            })

        let run = try #require(shell.run)
        let session = run.session
        #expect(shell.route == .countdown(setup))

        // The board is built over that one session, as it is for solo.
        try await SoloMatchTests.waitUntil("the opening deal to be laid") {
            run.board.board.placementList.count == setup.startingHandSize
        }
        #expect(session.state.board.placementList.count == setup.startingHandSize)

        // Countdown → match, moved by the shell itself, on the double's session.
        try await SoloMatchTests.waitUntil("the shell to advance itself") {
            shell.route == .match(setup)
        }
        #expect(shell.run === run, "the match route rebuilt the run")
        #expect(shell.run?.session === session)

        shell.matchEnded(winner: nil)
        #expect(shell.route == .results(winner: nil))
        #expect(shell.run === run, "the results route rebuilt the run")
        #expect(run.results().outcome == .noWinner)

        shell.returnToMenu()
        #expect(shell.run == nil)
        #expect(log.events == ["build A", "leave A"])
    }

    // MARK: - Teardown order: leave, then build

    @Test("The live opponent is left before the next one is constructed")
    func theOldOpponentIsDownBeforeTheNextIsBuilt() async throws {
        let shell = Self.shell()
        let log = Log()
        let setup = Self.setup

        #expect(
            shell.startMatch(setup) {
                RecordingOpponent("A", setup: setup, dictionary: EveryWordIsReal(), log: log)
            })
        try await SoloMatchTests.waitUntil("the first match to be dealt") {
            shell.run?.session.state.board.placementList.count == setup.startingHandSize
        }

        #expect(
            shell.startMatch(setup) {
                RecordingOpponent("B", setup: setup, dictionary: EveryWordIsReal(), log: log)
            })

        // The whole point: "leave A" is between the two builds, not after them.
        // A run that built B first would read build A, build B, leave A — two
        // live far ends at once — and this is the only check that sees it.
        #expect(log.events == ["build A", "leave A", "build B"])

        shell.returnToMenu()
        #expect(log.events == ["build A", "leave A", "build B", "leave B"])
    }

    @Test("Starting solo practice leaves a borrowed opponent first too")
    func soloPracticeTearsDownTheBorrowedOpponent() async throws {
        let shell = Self.shell()
        let log = Log()
        let setup = Self.setup

        #expect(
            shell.startMatch(setup) {
                RecordingOpponent("A", setup: setup, dictionary: EveryWordIsReal(), log: log)
            })
        #expect(shell.startSoloPractice())
        #expect(log.events == ["build A", "leave A"])
        #expect(shell.run?.match != nil, "the solo path stopped building a solo match")

        shell.returnToMenu()
    }

    // MARK: - The run never learns which opponent it holds

    /// A source scan, falsifiable the way `ServiceFenceTests`' are: it asserts
    /// the symbols it greps for are actually there, so a rename turns it red
    /// rather than vacuously green.
    @Test("MatchRun drives its opponent through the protocol and never casts it")
    func matchRunNeverCastsItsOpponent() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ShellSrc/MatchRun.swift")
                .resolvingSymlinksInPath(),
            encoding: .utf8
        )

        // The greped spellings exist — respell one in the source and this fails.
        #expect(source.contains("let opponent: any MatchOpponent"))
        #expect(source.contains("opponent.session"))
        #expect(source.contains("opponent.start()"))
        #expect(source.contains("opponent.leave()"))

        for cast in ["as? ", "as! ", "is SoloMatch", "as SoloMatch"] {
            let offending = source.components(separatedBy: "\n").filter { line in
                let code = line.trimmingCharacters(in: .whitespaces)
                return !code.hasPrefix("///") && !code.hasPrefix("//") && code.contains(cast)
            }
            #expect(offending.isEmpty, "MatchRun casts its opponent: \(offending)")
        }
    }
}
