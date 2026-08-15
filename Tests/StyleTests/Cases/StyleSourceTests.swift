import Foundation
import Testing

/// The style views must be pure compositions of DesignTokens.
///
/// A literal that sneaks into one of them is not caught by the compiler and
/// not obviously wrong on screen — it just quietly stops tracking the token it
/// was supposed to follow. These tests are the only thing that notices.
@Suite("Style sources")
struct StyleSourceTests {

    /// Files that render, as opposed to declaring the tokens themselves.
    static let views = ["BrandTile.swift", "BrandCard.swift", "ButtonStyles.swift", "StyleGallery.swift"]

    static func present() throws -> [(name: String, text: String)] {
        try StyleRepo.styleSources().filter { views.contains($0.name) }
    }

    @Test("No view file hardcodes a corner radius, a duration or a stroke width")
    func viewsCarryNoLiterals() throws {
        for file in try Self.present() {
            let text = StyleRepo.strippingComments(file.text)

            let radii = StyleRepo.matches(#"cornerRadius:\s*([0-9.]+)"#, in: text)
            #expect(radii.isEmpty, "\(file.name) hardcodes cornerRadius \(radii)")

            let durations = StyleRepo.matches(#"duration:\s*([0-9.]+)"#, in: text)
            #expect(durations.isEmpty, "\(file.name) hardcodes duration \(durations)")

            let widths = StyleRepo.matches(#"lineWidth:\s*([0-9.]+)"#, in: text)
            #expect(widths.isEmpty, "\(file.name) hardcodes lineWidth \(widths)")

            let shadows = StyleRepo.matches(#"\.shadow\(color:\s*\.?[a-z]"#, in: text, group: 0)
            #expect(shadows.isEmpty, "\(file.name) applies a shadow outside the recipes")
        }
    }

    @Test("No view file names a system color")
    func viewsUseNoSystemColors() throws {
        // `.clear` is legitimate — it is the absence of a color, not a choice
        // of one — so it is not in this list.
        let systemColors = ["Color.black", "Color.white", "Color.gray", "Color.red",
                            "Color.blue", "Color.green", "Color.primary", "Color.secondary",
                            ".foregroundStyle(.black", ".foregroundStyle(.white"]
        for file in try Self.present() {
            let text = StyleRepo.strippingComments(file.text)
            for color in systemColors {
                #expect(!text.contains(color), "\(file.name) uses \(color)")
            }
        }
    }

    @Test("No style source branches on colorScheme")
    func noColorSchemeBranching() throws {
        // Both themes come out of the asset catalog. A Swift branch on
        // colorScheme means a value that only exists in one of them.
        for file in try StyleRepo.styleSources() {
            let text = StyleRepo.strippingComments(file.text)
            #expect(!text.contains("colorScheme =="), "\(file.name) branches on colorScheme")
            #expect(!text.contains("@Environment(\\.colorScheme)"), "\(file.name) reads colorScheme")
        }
    }

    @Test("The tile is driven by the tile tokens")
    func tileUsesItsTokens() throws {
        let tile = StyleRepo.strippingComments(try StyleRepo.source("BrandTile.swift"))
        for token in ["Radius.tile", "Palette.tileFace", "Palette.tileEdge", "Palette.tileLetter",
                      "Stroke.bevel", "Stroke.selectedRing", "Palette.accent",
                      "Motion.tileLift", "Motion.snap", "Typography.tileLetter"] {
            #expect(tile.contains(token), "BrandTile does not use DesignTokens.\(token)")
        }
    }

    @Test("The selected lift animates over snapDuration")
    func liftUsesSnapDuration() throws {
        let tile = StyleRepo.strippingComments(try StyleRepo.source("BrandTile.swift"))
        let tokens = StyleRepo.strippingComments(try StyleRepo.source("DesignTokens.swift"))

        #expect(tile.contains("animation(DesignTokens.Motion.snap"))
        // Motion.snap is the only animation the tile uses, so this is the link
        // between the lift and the duration the direction pins.
        #expect(StyleRepo.matches(#"let snap = Animation\.easeOut\(duration: (\w+)\)"#, in: tokens) == ["snapDuration"])
    }

    @Test("The card carries fill, border, radius and both theme treatments")
    func cardUsesItsTokens() throws {
        let card = StyleRepo.strippingComments(try StyleRepo.source("BrandCard.swift"))
        for token in ["Palette.surface", "Palette.hairline", "Radius.panel",
                      "Stroke.hairline", "Shadow.card", "Palette.topHighlight"] {
            #expect(card.contains(token), "BrandCard does not use DesignTokens.\(token)")
        }
        #expect(card.contains("func brandCard()"), "no .brandCard() modifier")
    }

    @Test("The theme swap lives in the catalog, not in Swift")
    func cardThemeSwapIsDataDriven() throws {
        // The offset shadow must vanish in dark and the top highlight in light.
        // Since no Swift may branch on colorScheme, the alphas are the switch.
        let shadow = try ColorSetTests.entries("shadowCard")
        let highlight = try ColorSetTests.entries("topHighlight")

        #expect(shadow.any?.alpha ?? 0 > 0, "the card has no offset shadow in light")
        #expect(shadow.dark?.alpha == 0, "the offset shadow still shows in dark")
        #expect(highlight.any?.alpha == 0, "the top highlight shows in light")
        #expect(highlight.dark?.alpha ?? 0 > 0, "the card has no top highlight in dark")
    }

    @Test("All three button styles exist and each has a distinct pressed state")
    func buttonStylesAreDistinct() throws {
        let buttons = StyleRepo.strippingComments(try StyleRepo.source("ButtonStyles.swift"))

        for style in ["PrimaryButtonStyle", "QuietButtonStyle", "TextButtonStyle"] {
            #expect(buttons.contains("struct \(style): ButtonStyle"), "missing \(style)")
        }

        // primary: ink fill, onInk label, soft drop
        #expect(buttons.contains("Palette.ink"))
        #expect(buttons.contains("Palette.onInk"))
        #expect(buttons.contains("Shadow.button"))
        // quiet: cellEmpty fill, hairline border
        #expect(buttons.contains("Palette.cellEmpty"))
        #expect(buttons.contains("Stroke.hairline"))
        // text: accent, no chrome
        #expect(buttons.contains("Palette.accentPressed"))

        // Every style must actually read isPressed, and do something with it.
        let pressedBodies = buttons.components(separatedBy: "makeBody").dropFirst()
        #expect(pressedBodies.count == 3)
        for body in pressedBodies {
            #expect(body.contains("configuration.isPressed ?"), "a button style has no pressed state")
        }
    }

    @Test("The literal check has teeth")
    func literalCheckIsReal() {
        #expect(StyleRepo.matches(#"cornerRadius:\s*([0-9.]+)"#, in: "cornerRadius: 12") == ["12"])
        #expect(StyleRepo.matches(#"cornerRadius:\s*([0-9.]+)"#, in: "cornerRadius: DesignTokens.Radius.tile").isEmpty)
    }
}
