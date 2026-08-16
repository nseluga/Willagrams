import SwiftUI
import WillagramsRules

@main
struct WillagramsApp: App {

    init() {
        BrandFonts.registerOnce()
    }

    var body: some Scene {
        WindowGroup {
            // TESTING HARNESS — branch `testing/board-harness` only. Never merge.
            // The shell lane owns this file and the real root; until it lands
            // there is no way to reach BoardView on a device, so this stands one
            // up with a standard opening so the board lane can be tried by hand.
            BoardHarness()
        }
    }
}

/// Throwaway. Stands up a 21-tile opening framed on an iPad viewport so the
/// board can be driven by hand. Delete with the branch.
private struct BoardHarness: View {

    private let board: Board
    private let camera: BoardCamera
    private let dictionary: any WordList

    init() {
        var pool = Pool.standard(seed: 20260815)
        let tiles = pool.draw(21) ?? []
        let opening = BoardLayout.opening(tiles)
        self.board = opening
        self.camera = BoardLayout.framing(
            opening,
            in: CGRect(x: 0, y: 0, width: 1366, height: 1024),
            camera: BoardCamera()
        )
        self.dictionary = (try? EnableWordList()) ?? EnableWordList(words: [])
    }

    var body: some View {
        BoardView(board: board, camera: camera, dictionary: dictionary)
    }
}
