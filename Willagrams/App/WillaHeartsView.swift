import SwiftUI

/// Hearts over the whole app when WILLA is spelled. Mounted once at the root by
/// `WillagramsApp`, above every screen, and transparent to touches. The trigger
/// is the board model's own `willaSparkles` count, so one burst fires per new
/// WILLA run and none for any other word.
struct WillaHeartsView: View {

    let shell: ShellModel

    /// Which board, and how many new WILLA runs it has seen.
    private struct Key: Equatable {
        let board: ObjectIdentifier?
        let count: Int
    }

    private struct Heart: Identifiable {
        let id: Int
        let x = Double.random(in: 0.02...0.98)
        let size = Double.random(in: 22...46)
        let drift = Double.random(in: -50...50)
        let duration = Double.random(in: 1.6...2.5)
        let delay = Double.random(in: 0...0.5)
    }

    /// Total time on screen is at most delay + duration, under three seconds.
    private static let heartCount = 44
    private static let burstSeconds = 3.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hearts: [Heart] = []
    @State private var rising = false
    @State private var showing = false
    @State private var hideTask: Task<Void, Never>?

    private var key: Key {
        let board = shell.run?.board
        return Key(board: board.map(ObjectIdentifier.init), count: board?.model.willaSparkles ?? 0)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if showing {
                    if reduceMotion {
                        // Calm version: one heart that fades in and out in place.
                        Image(systemName: "heart.fill")
                            .font(.system(size: 120))
                            .foregroundStyle(DesignTokens.Palette.accent)
                            .opacity(rising ? 0.9 : 0)
                            .animation(.easeInOut(duration: 1.2), value: rising)
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    } else {
                        ForEach(hearts) { heart in
                            Image(systemName: "heart.fill")
                                .font(.system(size: heart.size))
                                .foregroundStyle(DesignTokens.Palette.accent)
                                .position(
                                    x: heart.x * proxy.size.width + (rising ? heart.drift : 0),
                                    y: rising ? -60 : proxy.size.height + 60
                                )
                                .animation(.easeOut(duration: heart.duration).delay(heart.delay), value: rising)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: key) { _, new in
            if new.count > 0 { fire() }
        }
    }

    private func fire() {
        hideTask?.cancel()
        hearts = (0..<Self.heartCount).map { Heart(id: $0) }
        rising = false
        showing = true
        hideTask = Task { @MainActor in
            // One turn at the start position, or the move would interpolate nothing.
            try? await Task.sleep(for: .milliseconds(50))
            rising = true
            if reduceMotion {
                try? await Task.sleep(for: .milliseconds(1300))
                rising = false
                try? await Task.sleep(for: .milliseconds(1300))
            } else {
                try? await Task.sleep(for: .seconds(Self.burstSeconds))
            }
            guard !Task.isCancelled else { return }
            showing = false
        }
    }
}
