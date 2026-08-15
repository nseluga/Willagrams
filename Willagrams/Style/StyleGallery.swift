import SwiftUI

/// The lane's proof surface: every design token rendered in situ.
///
/// Nothing here is a product screen — the `shell` lane owns those. This exists
/// so an unused, misnamed or wrongly-valued token is *visible* rather than
/// inferred from the source. Every key in `DesignTokens` appears at least
/// once, and `StyleSourceTests` fails if one stops appearing.
public struct StyleGallery: View {

    @State private var selectedTile: Int?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.xl) {
                header
                palette
                typeRamp
                tiles
                cards
                buttons
                monoLabels
                rulers
                shadows
                motion
            }
            .padding(DesignTokens.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(canvas)
    }

    // MARK: - Ground

    private var canvas: some View {
        LinearGradient(
            colors: [DesignTokens.Palette.canvasTop, DesignTokens.Palette.canvasBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            Text(verbatim: "Willagrams")
                .font(DesignTokens.Typography.display)
                .tracking(DesignTokens.Typography.displayTracking)
                .foregroundStyle(DesignTokens.Palette.ink)
            label("DESIGN TOKENS")
        }
    }

    // MARK: - Palette

    private var palette: some View {
        section("Palette") {
            LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: DesignTokens.Space.m) {
                ForEach(Self.swatches, id: \.0) { name, color in
                    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                            .fill(color)
                            .frame(height: DesignTokens.Space.xl)
                            .overlay {
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                                    .strokeBorder(DesignTokens.Palette.hairline,
                                                  lineWidth: DesignTokens.Stroke.hairline)
                            }
                        Text(name)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Palette.textSecondary)
                    }
                }
            }
        }
    }

    /// Every color token, including the two that are meant to be invisible in
    /// one theme — an all-transparent swatch in both themes is a bug worth
    /// seeing.
    private static let swatches: [(String, Color)] = [
        ("canvasTop", DesignTokens.Palette.canvasTop),
        ("canvasBottom", DesignTokens.Palette.canvasBottom),
        ("boardSurface", DesignTokens.Palette.boardSurface),
        ("surface", DesignTokens.Palette.surface),
        ("cellEmpty", DesignTokens.Palette.cellEmpty),
        ("ink", DesignTokens.Palette.ink),
        ("onInk", DesignTokens.Palette.onInk),
        ("textPrimary", DesignTokens.Palette.textPrimary),
        ("textSecondary", DesignTokens.Palette.textSecondary),
        ("hairline", DesignTokens.Palette.hairline),
        ("tileFace", DesignTokens.Palette.tileFace),
        ("tileEdge", DesignTokens.Palette.tileEdge),
        ("tileLetter", DesignTokens.Palette.tileLetter),
        ("accent", DesignTokens.Palette.accent),
        ("accentPressed", DesignTokens.Palette.accentPressed),
        ("onAccent", DesignTokens.Palette.onAccent),
        ("danger", DesignTokens.Palette.danger),
        ("shadowTile", DesignTokens.Palette.shadowTile),
        ("shadowCard", DesignTokens.Palette.shadowCard),
        ("shadowButton", DesignTokens.Palette.shadowButton),
        ("shadowSelected", DesignTokens.Palette.shadowSelected),
        ("topHighlight", DesignTokens.Palette.topHighlight),
    ]

    private var swatchColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 96), spacing: DesignTokens.Space.m)]
    }

    // MARK: - Type

    private var typeRamp: some View {
        section("Type") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
                ramp("display", DesignTokens.Typography.display, tracking: DesignTokens.Typography.displayTracking)
                ramp("title", DesignTokens.Typography.title)
                ramp("body", DesignTokens.Typography.body)
                ramp("button", DesignTokens.Typography.button)
                ramp("tileLetter", DesignTokens.Typography.tileLetter)
                ramp("caption", DesignTokens.Typography.caption)
            }
        }
    }

    private func ramp(_ name: String, _ font: Font, tracking: CGFloat = 0) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            label(name.uppercased())
            Text(verbatim: "Willagrams AaBbCc 0123")
                .font(font)
                .tracking(tracking)
                .foregroundStyle(DesignTokens.Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(Self.rampScaleFloor)
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        section("Tiles") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
                HStack(spacing: DesignTokens.Space.m) {
                    labelled("idle") { BrandTile(letter: "W", size: Self.tileSize, state: .idle) }
                    labelled("placed") {
                        BrandTile(letter: "I", size: Self.tileSize, state: .placed)
                            .background(cell)
                    }
                    labelled("selected") { BrandTile(letter: "L", size: Self.tileSize, state: .selected) }
                }

                VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
                    label("TAP TO LIFT")
                    HStack(spacing: DesignTokens.Space.s) {
                        ForEach(Array(Self.tapRow.enumerated()), id: \.offset) { index, letter in
                            BrandTile(
                                letter: letter,
                                size: Self.tileSize,
                                state: selectedTile == index ? .selected : .idle
                            )
                            .onTapGesture {
                                withAnimation(DesignTokens.Motion.snap) {
                                    selectedTile = selectedTile == index ? nil : index
                                }
                            }
                        }
                    }
                    // Room for the lift, so a raised tile is not clipped.
                    .padding(.vertical, DesignTokens.Space.s)
                }
            }
        }
    }

    /// An empty board cell, to show a placed tile seated in one.
    private var cell: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.cell, style: .continuous)
            .fill(DesignTokens.Palette.cellEmpty)
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.cell, style: .continuous)
                    .strokeBorder(DesignTokens.Palette.hairline, lineWidth: DesignTokens.Stroke.hairline)
            }
    }

    // MARK: - Cards

    private var cards: some View {
        section("Card") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
                Text(verbatim: "A panel on the tabletop")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Palette.ink)
                Text(verbatim: "Hard offset shadow in light, lit top edge in dark. Both are applied; the catalog decides which one you can see.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignTokens.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .brandCard()
            .padding(.trailing, DesignTokens.Space.s)
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        section("Buttons") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
                Button(Terminology.draw) {}.buttonStyle(.brandPrimary)
                Button(Terminology.swap) {}.buttonStyle(.brandQuiet)
                Button(Terminology.winCall) {}.buttonStyle(.brandText)
                Button(Terminology.invalid) {}
                    .buttonStyle(.brandText)
                    .tint(DesignTokens.Palette.danger)
            }
        }
    }

    // MARK: - Mono

    private var monoLabels: some View {
        section("Mono labels") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
                label(Terminology.pool.uppercased())
                label(Terminology.countdownTitle.uppercased())
                label("144 TILES")
            }
        }
    }

    // MARK: - Rulers

    private var rulers: some View {
        section("Space, radius, stroke") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
                ruler("Space", [
                    ("xs", DesignTokens.Space.xs), ("s", DesignTokens.Space.s),
                    ("m", DesignTokens.Space.m), ("l", DesignTokens.Space.l),
                    ("xl", DesignTokens.Space.xl),
                ]) { width in
                    DesignTokens.Palette.accent.frame(width: width, height: DesignTokens.Space.s)
                }

                ruler("Radius", [
                    ("cell", DesignTokens.Radius.cell), ("tile", DesignTokens.Radius.tile),
                    ("panel", DesignTokens.Radius.panel), ("pill", DesignTokens.Radius.pill),
                ]) { radius in
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(DesignTokens.Palette.tileFace)
                        .frame(width: DesignTokens.Space.xl, height: DesignTokens.Space.l)
                }

                ruler("Stroke", [
                    ("hairline", DesignTokens.Stroke.hairline), ("bevel", DesignTokens.Stroke.bevel),
                    ("selectedRing", DesignTokens.Stroke.selectedRing),
                ]) { width in
                    DesignTokens.Palette.ink.frame(width: DesignTokens.Space.xl, height: width)
                }
            }
        }
    }

    private func ruler<Sample: View>(
        _ title: String,
        _ entries: [(String, CGFloat)],
        @ViewBuilder sample: @escaping (CGFloat) -> Sample
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            label(title.uppercased())
            ForEach(entries, id: \.0) { name, value in
                HStack(spacing: DesignTokens.Space.s) {
                    sample(value)
                    Text(verbatim: "\(name) \(Self.number(value))")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                }
            }
        }
    }

    // MARK: - Shadows

    private var shadows: some View {
        section("Shadow recipes") {
            HStack(spacing: DesignTokens.Space.l) {
                shadowChip("tile", DesignTokens.Shadow.tile)
                shadowChip("card", DesignTokens.Shadow.card)
                shadowChip("button", DesignTokens.Shadow.button)
                shadowChip("selected", DesignTokens.Shadow.selected)
                shadowChip("flush", DesignTokens.Shadow.flush)
            }
            .padding(.vertical, DesignTokens.Space.s)
        }
    }

    private func shadowChip(_ name: String, _ recipe: DesignTokens.Shadow.Recipe) -> some View {
        VStack(spacing: DesignTokens.Space.xs) {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                .fill(DesignTokens.Palette.surface)
                .frame(width: DesignTokens.Space.xl, height: DesignTokens.Space.xl)
                .brandShadow(recipe)
            Text(name)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
        }
    }

    // MARK: - Motion

    private var motion: some View {
        section("Motion") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                label("SNAPDURATION \(Self.number(DesignTokens.Motion.snapDuration))")
                label("DEALDURATION \(Self.number(DesignTokens.Motion.dealDuration))")
                label("SNAPTHRESHOLD \(Self.number(DesignTokens.Motion.snapThreshold))")
                label("TILELIFT \(Self.number(DesignTokens.Motion.tileLift))")
            }
        }
    }

    // MARK: - Chrome

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
            Text(title)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Palette.ink)
            Rectangle()
                .fill(DesignTokens.Palette.hairline)
                .frame(height: DesignTokens.Stroke.hairline)
            content()
        }
    }

    /// A Fragment Mono metadata label, the direction's one non-sans use.
    private func label(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Typography.monoLabel)
            .tracking(DesignTokens.Typography.monoLabelTracking)
            .foregroundStyle(DesignTokens.Palette.textSecondary)
    }

    private func labelled<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: DesignTokens.Space.s) {
            content()
            label(name.uppercased())
        }
    }

    private static func number(_ value: some BinaryFloatingPoint) -> String {
        String(format: "%g", Double(value))
    }

    private static let tileSize: CGFloat = 44
    private static let rampScaleFloor: CGFloat = 0.5
    private static let tapRow: [Character] = ["T", "I", "L", "E", "S"]
}

#Preview("Light") { StyleGallery() }
#Preview("Dark") { StyleGallery().preferredColorScheme(.dark) }
