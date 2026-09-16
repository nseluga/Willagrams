import SwiftUI

/// The loading screen from comp 02.
///
/// The wordmark's nine tiles start scattered and rotated, fly into place with
/// an overshoot, the assembled mark clicks, a ring expands out of it and six
/// small squares burst from the accent A — one 4.2s cycle, replayed until the
/// app is ready.
///
/// This view owns the animation and nothing else. Whether to replay, and when
/// it is allowed to leave, is ``LaunchLoop``'s — a plain value a test drives
/// without a clock. The one thing decided here is what a frame looks like.
struct LaunchView: View {

    let shell: ShellModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where each tile starts a cycle, and when it sets off. Row and column are
    /// the 5x5 grid's; the letters are, in order, G R W I L L A M S.
    private static let scatter: [Scatter] = [
        Scatter(row: 0, column: 4, dx: 13, dy: -86, degrees: 18, delay: 0),
        Scatter(row: 1, column: 4, dx: -119, dy: -126, degrees: -27, delay: 0.05),
        Scatter(row: 2, column: 0, dx: -29, dy: 36, degrees: 24, delay: 0.10),
        Scatter(row: 2, column: 1, dx: 157, dy: -18, degrees: -21, delay: 0.15),
        Scatter(row: 2, column: 2, dx: -25, dy: 138, degrees: 30, delay: 0.20),
        Scatter(row: 2, column: 3, dx: -195, dy: -178, degrees: -31, delay: 0.25),
        Scatter(row: 2, column: 4, dx: -125, dy: -28, degrees: 14, delay: 0.40),
        Scatter(row: 3, column: 4, dx: 11, dy: 70, degrees: -26, delay: 0.30),
        Scatter(row: 4, column: 4, dx: -263, dy: 32, degrees: 28, delay: 0.35),
    ]

    private struct Scatter {
        let row: Int
        let column: Int
        let dx: CGFloat
        let dy: CGFloat
        let degrees: Double
        let delay: Double
    }

    /// Tile edge, and everything the mark's geometry is derived from. Fixed
    /// rather than read off the container: the comp's per-tile offsets are in
    /// points against this size, and scaling them would be a second set of
    /// numbers nobody measured.
    private static let cell: CGFloat = 44
    private static var gap: CGFloat { (cell / 7).rounded() }
    private static var markWidth: CGFloat { cell * 5 + gap * 4 }
    /// The accent A's centre, relative to the mark's: column 4 of 5.
    private static var accentCentre: CGSize { CGSize(width: 2 * (cell + gap), height: 0) }

    private static let ringStart: CGFloat = 0.72
    private static let ringEnd: CGFloat = 1.25
    private static let ringOpacity: Double = 0.5
    private static let sparkCount = 6
    private static let sparkTravel: CGFloat = 58
    private static let sparkSide: CGFloat = 7

    /// When the mark clicks, measured from the start of a cycle.
    private static let clickAt: Double = 1.30
    private static let barPeriod: Double = 1.5

    @State private var isAssembled = false
    @State private var clickScale: CGFloat = 1
    @State private var ringScale: CGFloat = LaunchView.ringStart
    @State private var ringAlpha: Double = 0
    @State private var sparkReach: CGFloat = 0
    @State private var sparkAlpha: Double = 0
    @State private var barPhase: CGFloat = 0
    @State private var startedAt = Date()

    /// The policy, rebuilt from what the model currently reports. Cheap, and it
    /// keeps the readiness answer in one place rather than spread over the
    /// three points in the cycle that ask for it.
    private var loop: LaunchLoop {
        let start = startedAt
        var loop = LaunchLoop(
            reduceMotion: reduceMotion,
            elapsed: { Date().timeIntervalSince(start) }
        )
        if shell.isDictionaryLoaded { loop.dictionaryDidLoad() }
        if shell.hasSignInSettled { loop.signInDidSettle() }
        return loop
    }

    var body: some View {
        ZStack {
            // The same ground the generated launch screen paints, so the
            // hand-off from it to this view shows nothing in between.
            DesignTokens.Palette.launchGround.ignoresSafeArea()

            VStack(spacing: DesignTokens.Space.xl) {
                mark
                VStack(spacing: DesignTokens.Space.m) {
                    bar
                    Text("Shuffling the \(Terminology.pool)")
                        .monoLabel()
                }
            }
        }
        // The ground is the dark tabletop whatever the system theme is, so the
        // tokens drawn on it resolve against that ground rather than against a
        // light theme they are not sitting on.
        .environment(\.colorScheme, .dark)
        .task { await drive() }
        .task { await startLaunchWork() }
        .onAppear {
            withAnimation(.linear(duration: Self.barPeriod).repeatForever(autoreverses: false)) {
                barPhase = 1
            }
        }
    }

    // MARK: - The mark

    private var mark: some View {
        ZStack {
            ring
            WordmarkTiles(cell: Self.cell, placement: placement)
            sparks
        }
        .scaleEffect(clickScale)
    }

    private func placement(row: Int, column: Int) -> WordmarkTiles.Placement {
        guard let tile = Self.scatter.first(where: { $0.row == row && $0.column == column }) else {
            return .inPlace
        }
        guard !reduceMotion else { return .inPlace }
        // The overshoot: a spring with very little damping, so each tile passes
        // its slot and settles back into it.
        let fly = Animation
            .interpolatingSpring(stiffness: 180, damping: 13)
            .delay(tile.delay)
        return isAssembled
            ? WordmarkTiles.Placement(animation: fly)
            : WordmarkTiles.Placement(
                offset: CGSize(width: tile.dx, height: tile.dy),
                rotation: .degrees(tile.degrees),
                animation: nil
            )
    }

    private var ring: some View {
        Circle()
            .strokeBorder(DesignTokens.Palette.accent, lineWidth: DesignTokens.Stroke.hairline * 2)
            .frame(width: Self.markWidth, height: Self.markWidth)
            .scaleEffect(ringScale)
            .opacity(ringAlpha)
            .allowsHitTesting(false)
    }

    private var sparks: some View {
        ForEach(0 ..< Self.sparkCount, id: \.self) { index in
            let angle = Angle.degrees(Double(index) / Double(Self.sparkCount) * 360 - 90)
            RoundedRectangle(cornerRadius: DesignTokens.Radius.tile / 3, style: .continuous)
                .fill(DesignTokens.Palette.accent)
                .frame(width: Self.sparkSide, height: Self.sparkSide)
                .offset(
                    x: Self.accentCentre.width + cos(angle.radians) * sparkReach,
                    y: Self.accentCentre.height + sin(angle.radians) * sparkReach
                )
                .opacity(sparkAlpha)
        }
        .allowsHitTesting(false)
    }

    // MARK: - The bar

    private var bar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            Capsule()
                .fill(DesignTokens.Palette.accent)
                .frame(width: width / 3)
                // Travels a full width plus its own, so it leaves one edge as
                // it enters the other and the loop has no visible seam.
                .offset(x: -width / 3 + barPhase * (width + width / 3))
        }
        .frame(width: 160, height: 3)
        .background(DesignTokens.Palette.accent.opacity(0.18), in: Capsule())
        .clipShape(Capsule())
    }

    // MARK: - The loop

    /// Starts the work the loader is waiting on. A turn late so the first frame
    /// is on screen before the dictionary read stalls the main actor — the
    /// stall is the very thing this screen exists to cover.
    private func startLaunchWork() async {
        try? await Task.sleep(for: .seconds(0.05))
        shell.launch()
    }

    private func drive() async {
        guard !reduceMotion else {
            // The static mark and bar, out as soon as ready.
            isAssembled = true
            while !loop.exitsMidCycle {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            shell.finishLaunch()
            return
        }
        while !Task.isCancelled {
            await runCycle()
            if Task.isCancelled { return }
            // Readiness that landed part-way through is answered here and only
            // here, which is what keeps a cycle from being cut short.
            if loop.cycleEnded() == .home {
                shell.finishLaunch()
                return
            }
        }
    }

    /// One 4.2s pass: fly in, click, ring, spark, hold.
    private func runCycle() async {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            isAssembled = false
            clickScale = 1
            ringScale = Self.ringStart
            ringAlpha = 0
            sparkReach = 0
            sparkAlpha = 0
        }
        await pause(0.05)

        isAssembled = true
        await pause(Self.clickAt - 0.05)

        // The click: over, under, home.
        withAnimation(.easeOut(duration: 0.10)) { clickScale = 1.04 }
        withTransaction(reset) {
            ringScale = Self.ringStart
            ringAlpha = Self.ringOpacity
            sparkReach = 0
            sparkAlpha = 0.9
        }
        withAnimation(.easeOut(duration: 0.55)) {
            ringScale = Self.ringEnd
            ringAlpha = 0
        }
        withAnimation(.easeOut(duration: 0.50)) {
            sparkReach = Self.sparkTravel
            sparkAlpha = 0
        }
        await pause(0.10)
        withAnimation(.easeInOut(duration: 0.10)) { clickScale = 0.99 }
        await pause(0.10)
        withAnimation(.easeInOut(duration: 0.12)) { clickScale = 1 }

        // Whatever is left of the cycle, held on the assembled mark.
        await pause(LaunchLoop.cycleSeconds - Self.clickAt - 0.25)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(max(0, seconds)))
    }
}
