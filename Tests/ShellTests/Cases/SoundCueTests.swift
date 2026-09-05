import Audio
import BoardKit
import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell

/// Every sound cue, asserted where the model plays it.
///
/// Two rules run through this suite. Every "nothing was played" assertion is
/// paired with a positive twin on the SAME recorder — a player that silently
/// stopped recording would otherwise pass every negative on its own. And the
/// ordering assertion compares the whole array, not a set: the criterion is
/// that the cues arrive in the order the player caused them.
/// A clock that hands out a second to everything currently asleep on it.
///
/// `StepClock` holds one continuation, and a solo run has more than one sleeper
/// — the session's countdown and the far end's own pump — so a single slot
/// loses whichever parked second. Every waiter is held and resumed together.
@MainActor
final class EveryWaiterClock {
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Lets one second elapse for everything asleep right now.
    func advance() {
        let resume = waiting
        waiting = []
        for continuation in resume { continuation.resume() }
    }
}

@MainActor
@Suite("Sound cues")
struct SoundCueTests {

    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal

    static let setup = MatchBoardTests.setup

    struct Fixture {
        let host: FakeTransport
        let session: MatchSession
        let board: MatchBoard
        let shell: ShellModel
        let hud: MatchHUDModel
        let audio: RecordingAudioPlayer
        let dictionary: any WordList
    }

    /// A guest session holding two letters that make one word, with the board
    /// bridge and the HUD over it and one recording player behind all of them.
    ///
    /// A guest rather than a solo match because it is the only way to choose
    /// the letters: the cue assertions below turn on which tile is which.
    static func fixture(words: [String] = ["GO"]) async throws -> Fixture {
        let dictionary = EnableWordList(words: words)
        let audio = RecordingAudioPlayer()
        let (host, session) = try await MatchBoardTests.guest(
            handSize: 2, dictionary: dictionary
        )
        let board = MatchBoard(session: session, dictionary: dictionary, audio: audio)
        board.viewport = MatchBoardTests.viewport
        let shell = ShellModel(
            route: .match(setup), sleepFor: { _ in }, services: ShellServices(audio: audio)
        )
        let hud = MatchHUDModel(shell: shell, session: session, board: board, audio: audio)

        try await MatchBoardTests.grant([Tile(letter: "G"), Tile(letter: "O")], from: host)
        try await SoloMatchTests.waitUntil("the opening on the board") {
            board.board.placementList.count == 2
        }
        // The deal is not a move the player made, so it must not have been
        // heard. Asserted here so every test below starts from silence it can
        // trust rather than from a `forget()` that hides a stray cue.
        #expect(audio.effects.isEmpty, "the opening deal made a sound")
        return Fixture(
            host: host, session: session, board: board,
            shell: shell, hud: hud, audio: audio, dictionary: dictionary
        )
    }

    /// Joins the two dealt letters into one word — the commit a finger makes
    /// when it drops the second tile against the first.
    @discardableResult
    static func makeTheWord(_ f: Fixture) async throws -> Placement {
        let loose = try #require(f.board.board.placementList.first { $0.tile.letter == "O" })
        let anchor = try #require(
            f.board.board.placementList.first { $0.tile.letter == "G" }
        ).coord
        let target = Coord(row: anchor.row, col: anchor.col + 1)
        var next = f.board.board
        _ = next.remove(at: loose.coord)
        try next.place(loose.tile, at: target)
        f.board.board = next
        f.board.model.seed(f.board.board, against: f.dictionary)
        try await SoloMatchTests.waitUntil("the session to follow the finger") {
            f.session.state.board.tile(at: target)?.id == loose.tile.id
        }
        return Placement(tile: loose.tile, coord: target)
    }

    /// Takes one tile off the table and leaves it off — the commit that has
    /// nothing landing at the other end of it.
    static func takeOffTheTable(_ f: Fixture, _ placement: Placement) async throws {
        var next = f.board.board
        _ = next.remove(at: placement.coord)
        f.board.board = next
        f.board.model.seed(f.board.board, against: f.dictionary)
        try await SoloMatchTests.waitUntil("the recall to be heard") {
            f.audio.effects.contains(.tileRecall)
        }
    }

    // MARK: - The board's commit bridge

    @Test("A committed move sounds one tilePlace, and a board that did not change sounds nothing")
    func aCommittedMoveSoundsPlaceOnce() async throws {
        let f = try await Self.fixture()

        try await Self.makeTheWord(f)
        #expect(f.audio.effects == [.tilePlace])

        // The negative: writing the same board back is what an abandoned drag
        // leaves behind — nothing moved, so nothing is heard. The positive twin
        // is the same recorder still holding the cue above.
        f.board.board = f.board.board
        for _ in 0..<50 { await Task.yield() }
        #expect(f.audio.effects == [.tilePlace], "an uncommitted drag made a sound")
        #expect(f.audio.effects.isEmpty == false, "the recorder stopped recording")
        // Tiles fire no haptic through this player — `BoardHaptics` owns that.
        #expect(f.audio.impacts.isEmpty, "a tile buzzed")

        f.session.leave()
    }

    @Test("A tile taken off the table sounds tileRecall and no tilePlace")
    func aTileLeavingTheTableSoundsRecall() async throws {
        let f = try await Self.fixture()
        let placed = try await Self.makeTheWord(f)
        f.audio.forget()

        try await Self.takeOffTheTable(f, placed)
        #expect(f.audio.effects == [.tileRecall], "a tile leaving the table did not sound alone")
        #expect(f.audio.impacts.isEmpty, "a recall buzzed")

        f.session.leave()
    }

    // MARK: - The HUD

    @Test("A refused Draw sounds invalid and never sounds draw, and a granted one sounds draw")
    func refusedDrawSoundsInvalidAndGrantedSoundsDraw() async throws {
        let f = try await Self.fixture()

        // Two loose letters: the board is not finished, so Draw is refused.
        #expect(f.hud.draw() == false)
        #expect(f.audio.effects == [.invalid])
        #expect(f.audio.effects.contains(.draw) == false, "a refused Draw sounded a grant")

        try await Self.makeTheWord(f)
        f.audio.forget()
        #expect(f.hud.draw())
        // The positive twin of the negative above: the same recorder, the same
        // match, one granted press, one `draw` and no second refusal.
        #expect(f.audio.effects == [.draw])

        f.session.leave()
    }

    @Test("A Swap sounds swap alone — never a recall and never a draw")
    func swapSoundsSwapAlone() async throws {
        let f = try await Self.fixture()
        let placed = try await Self.makeTheWord(f)
        f.audio.forget()

        MatchHUDTests.select(Placement(tile: placed.tile, coord: placed.coord), on: f.board)
        #expect(f.hud.swappableTile?.id == placed.tile.id)
        #expect(f.hud.isSwapEnabled)
        #expect(f.hud.swap(placed.tile))

        // The tile left the surface, but the session let go of it first — so
        // the commit bridge has nothing to call a recall.
        for _ in 0..<50 { await Task.yield() }
        #expect(f.audio.effects == [.swap])
        #expect(f.audio.effects.contains(.tileRecall) == false, "a Swap sounded a recall")
        #expect(f.audio.effects.contains(.draw) == false, "a Swap sounded a draw")

        f.session.leave()
    }

    // MARK: - The order of a whole match

    @Test("Place, Draw and a recall are heard in the order the player caused them")
    func theCuesArriveInTheOrderTheyHappened() async throws {
        let f = try await Self.fixture()

        let placed = try await Self.makeTheWord(f)
        #expect(f.hud.draw())
        try await Self.takeOffTheTable(f, placed)

        // The whole array, in order. A set or a `contains` sweep would pass on
        // a bridge that played the recall before the place.
        #expect(f.audio.effects == [.tilePlace, .draw, .tileRecall])
        #expect(f.audio.effects != [.tileRecall, .draw, .tilePlace])

        f.session.leave()
    }

    // MARK: - The ending

    @Test("A win sounds win and exactly one medium haptic")
    func aWinSoundsWinAndBuzzesOnce() async throws {
        let f = try await Self.fixture(words: ["GO"])
        try await Self.makeTheWord(f)
        f.audio.forget()

        // The pool runs out on the host's word; there is no local latch for it.
        try await f.host.send(.poolExhausted, delivery: .reliable)
        try await SoloMatchTests.waitUntil("the pool to run out") { f.session.poolIsExhausted }
        #expect(f.hud.isWinEnabled)
        #expect(f.hud.claimWin())

        #expect(f.audio.effects == [.win])
        #expect(f.audio.effects.contains(.loss) == false, "a win sounded a defeat")
        #expect(f.audio.impacts == [.medium])

        f.session.leave()
    }

    @Test("A resignation sounds loss, with no win and no haptic")
    func aResignationSoundsLoss() async throws {
        let f = try await Self.fixture()
        f.audio.forget()

        f.hud.armResign()
        #expect(f.hud.confirmResign())
        #expect(f.session.isMatchOver)

        #expect(f.audio.effects == [.loss])
        #expect(f.audio.effects.contains(.win) == false, "a defeat sounded a win")
        #expect(f.audio.impacts.isEmpty, "a defeat buzzed")

        f.session.leave()
    }

    // MARK: - The countdown

    @Test("The countdown sounds one tick per second and nothing else before the deal")
    func theCountdownTicksOncePerSecond() async throws {
        let clock = EveryWaiterClock()
        let audio = RecordingAudioPlayer()
        let shell = ShellModel(
            dictionary: { EveryWordIsReal() },
            // A gated clock, not the wall clock: every second of the count is
            // handed out by this test, so nothing is left ticking when it ends
            // and the count cannot race the assertion.
            sleepFor: { await clock.sleep($0) },
            services: ShellServices(audio: audio)
        )
        #expect(shell.startSoloPractice(seed: 20260817))

        // Seconds are handed out until the count runs out and the route moves.
        try await SoloMatchTests.waitUntil("the match to start", within: .seconds(30)) {
            if case .match = shell.route { return true }
            clock.advance()
            return false
        }

        // One tick per second the countdown showed — no tick for the second
        // that never showed, and nothing else played on the way in.
        #expect(
            audio.effects == Array(
                repeating: .countdownTick, count: ShellModel.soloCountdownSeconds
            )
        )
        #expect(audio.effects.isEmpty == false, "the recorder stopped recording")
        #expect(audio.impacts.isEmpty, "the countdown buzzed")

        shell.returnToMenu()
    }

    // MARK: - The menu

    @Test("Each menu action sounds exactly one menuTap, and a refused one sounds nothing")
    func everyMenuActionSoundsOneTap() async throws {
        let backend = FakeBackend()
        let audio = RecordingAudioPlayer()
        let shell = ShellModel(
            dictionary: { EveryWordIsReal() },
            sleepFor: { _ in },
            services: ShellServices(backend: backend, audio: audio, signIn: backend)
        )
        await shell.signInTask?.value
        #expect(shell.currentProfile != nil, "the shell never signed in")

        // The negative first, and from a route these actions must refuse: a
        // transition that did not happen is not a tap. Its positive twin is
        // every action below, on this same recorder.
        shell.showHowToPlay()
        audio.forget()
        #expect(shell.showProfile() == false)
        #expect(shell.showFriends() == false)
        #expect(shell.showJoin() == false)
        #expect(shell.playAFriend() == false)
        #expect(audio.effects.isEmpty, "a refused menu action sounded a tap")
        shell.returnToMenu()

        // Every action the menu offers, one at a time, each back to the menu.
        let actions: [(String, () -> Void)] = [
            ("showSoloSetup", { shell.showSoloSetup() }),
            ("showHowToPlay", { shell.showHowToPlay() }),
            ("showProfile", { #expect(shell.showProfile()) }),
            ("showFriends", { #expect(shell.showFriends()) }),
            ("showJoin", { #expect(shell.showJoin()) }),
            ("playAFriend", { #expect(shell.playAFriend()) }),
        ]
        for (name, act) in actions {
            audio.forget()
            act()
            #expect(audio.effects == [.menuTap], "\(name) did not sound exactly one tap")
            #expect(audio.impacts.isEmpty, "\(name) buzzed")
            shell.returnToMenu()
        }
    }
}
