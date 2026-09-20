import Foundation
import Testing
import WillagramsRules
@testable import Match
@testable import Shell

/// Switching between Host and Join on the Two Player screen — item 6's own
/// guardrail: the model being left is torn down, backend cancel included,
/// before the other one is built. Never two live lobbies, even for one turn.
@MainActor
@Suite("Two Player: switching Host and Join")
struct TwoPlayerSwitchTests {

    typealias EveryWordIsReal = SoloMatchTests.EveryWordIsReal

    // MARK: - done when 1

    @Test("From the host lobby, the Join chip leaves the route at .join and records the host's backend cancel")
    func hostToJoinTearsDownTheLobby() async throws {
        let f = try await HostLobbyTests.make()

        #expect(f.shell.playAFriend())
        let lobby = try #require(f.shell.hostLobby)
        await HostLobbyTests.until("the lobby exists") { lobby.phase == .waiting }
        #expect(f.wire.hasLeft == false, "the lobby's own channel opened, not left, before the switch")

        #expect(f.shell.showJoin())

        #expect(f.shell.route == .join)
        #expect(f.shell.hostLobby == nil)
        #expect(f.wire.hasLeft, "the host lobby's backend cancel never ran")

        f.shell.returnToMenu()
    }

    // MARK: - done when 1 (the other direction)

    @Test("From the join screen, the Host chip leaves the route at .hostLobby and tears down the join model")
    func joinToHostTearsDownTheJoin() async throws {
        let f = try await JoinTests.make()
        let join = try await JoinTests.joinTheLobby(f)
        #expect(f.guestWire.hasLeft == false, "the join's own channel opened, not left, before the switch")

        #expect(f.shell.playAFriend())

        #expect(f.shell.route == .hostLobby)
        #expect(f.shell.join == nil)
        #expect(join.match == nil, "the torn-down join model must not still hold the façade")
        #expect(f.guestWire.hasLeft, "the join model's backend cancel never ran")

        f.shell.returnToMenu()
    }
}

/// The plain value behind the six code tiles — host and join modes, asserted
/// against written literals, never against `CodeTile.length` or any other
/// constant the module exports.
@Suite("Code tiles")
struct CodeTileTests {

    @Test("Host mode with a six-character code yields six filled tiles, the last accented")
    func hostModeYieldsSixFilledTilesLastAccented() {
        let tiles = CodeTile.tiles(mode: .host, code: "18VXES")

        #expect(tiles == [
            .filled("1", accent: false),
            .filled("8", accent: false),
            .filled("V", accent: false),
            .filled("X", accent: false),
            .filled("E", accent: false),
            .filled("S", accent: true),
        ])
    }

    @Test("Join mode with three typed characters yields three filled and three empty tiles")
    func joinModeWithThreeCharactersYieldsThreeFilledThreeEmpty() {
        let tiles = CodeTile.tiles(mode: .join, code: "AB1")

        #expect(tiles == [
            .filled("A", accent: false),
            .filled("B", accent: false),
            .filled("1", accent: false),
            .empty,
            .empty,
            .empty,
        ])
    }
}
