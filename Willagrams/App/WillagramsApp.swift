import SwiftUI
import WillagramsRules

@main
struct WillagramsApp: App {

    init() {
        BrandFonts.registerOnce()
    }

    var body: some Scene {
        WindowGroup {
            // ponytail: the app root is a TEST HARNESS, deliberately, on main.
            // The `shell` lane owns this file and writes the real root; until it
            // lands there is no way to reach BoardView on a device, and every
            // board fix so far came from driving it by hand — no test in this
            // repo reaches a gesture. So the harness stays and the entry point
            // is a demo with a fixed seed. Delete `BoardHarness` and everything
            // below it the moment `shell` authors this file.
            BoardHarness()
        }
    }
}

/// Throwaway. Stands up a 21-tile opening framed on an iPad viewport so the
/// board can be driven by hand. Delete with the `shell` lane, not with a branch.
private struct BoardHarness: View {

    /// The harness is the owner now: `BoardView` takes the board and the
    /// session as bindings, so someone above has to hold them.
    @State private var board: Board
    @State private var model = BoardModel()
    private let camera: BoardCamera
    private let dictionary: any WordList

    init() {
        var pool = Pool.standard(seed: 20260815)
        let tiles = pool.draw(21) ?? []
        let opening = BoardLayout.opening(tiles)
        self._board = State(initialValue: opening)
        self.camera = BoardLayout.framing(
            opening,
            in: CGRect(x: 0, y: 0, width: 1366, height: 1024),
            camera: BoardCamera()
        )
        self.dictionary = (try? EnableWordList()) ?? EnableWordList(words: [])
    }

    var body: some View {
        BoardView(board: $board, model: $model, camera: camera, dictionary: dictionary)
    }
}
