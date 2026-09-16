import CoreText
import Foundation
import SwiftUI
import Testing
import StyleKit

/// `ButtonLabelFit` executed, not read.
///
/// The bug these pin: the button styles picked the compact face off
/// `verticalSizeClass == .compact`, which is landscape phone. A portrait phone
/// is `horizontalSizeClass == .compact` with a *regular* vertical class, so it
/// kept the 20pt face and 24pt padding per side, and a two-button row on a
/// 375pt screen broke "Copy" into `Cop` / `y`.
///
/// Widths here are measured with CoreText against the real bundled face, so
/// these fail if the tokens, the padding or the scale floor move.
@Suite("Button label fit")
struct ButtonLabelFitTests {

    // MARK: measurement

    /// Rendered advance width of `text`. Registers the bundled TTFs first —
    /// `BrandFontsTests.registered` is the suite's one registration — so this
    /// measures Instrument Sans, not San Francisco standing in for it.
    static func width(_ text: String, pointSize: CGFloat, face: String = "InstrumentSans-SemiBold") -> CGFloat {
        _ = BrandFontsTests.registered
        let font = CTFontCreateWithName(face as CFString, pointSize, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// A friend code is monospaced system type, not the brand face.
    static func monoWidth(_ text: String, pointSize: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, pointSize, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// The narrowest the app's row of buttons can be drawn, label by label.
    static func rowWidth(
        buttons: [String],
        fixed: CGFloat = 0,
        gaps: Int,
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?
    ) -> CGFloat {
        let size = ButtonLabelFit.pointSize(horizontal: horizontal, vertical: vertical)
        let buttonsWidth = buttons.reduce(CGFloat(0)) { total, label in
            total + ButtonLabelFit.minimumButtonWidth(
                labelWidth: width(label, pointSize: size),
                horizontal: horizontal,
                vertical: vertical
            )
        }
        return fixed + buttonsWidth + CGFloat(gaps) * DesignTokens.Space.m
    }

    /// Content width inside a `.brandCard()` on a 375pt-wide portrait phone:
    /// the screen, less its margin on both sides, less the card's own padding.
    static func cardWidth(screen: CGFloat, horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> CGFloat {
        screen
            - 2 * ScreenMargin.value(horizontal: horizontal, vertical: vertical)
            - 2 * DesignTokens.Space.l
    }

    // MARK: the size-class rule

    static let sizeClasses: [(UserInterfaceSizeClass?, UserInterfaceSizeClass?, Bool)] = [
        (.compact, .regular, true),   // portrait phone — the bug
        (.compact, nil, true),
        (.compact, .compact, true),   // landscape phone, small
        (.regular, .compact, true),   // landscape phone, large
        (nil, .compact, true),
        (.regular, .regular, false),  // iPad
        (.regular, nil, false),
        (nil, .regular, false),
        (nil, nil, false),
    ]

    @Test("Both phone orientations take the compact face; iPad keeps the full one")
    func compactOnEveryPhone() {
        for (h, v, want) in Self.sizeClasses {
            #expect(
                ButtonLabelFit.isCompact(horizontal: h, vertical: v) == want,
                "h=\(String(describing: h)) v=\(String(describing: v))"
            )
        }
    }

    @Test("A portrait phone gets 15pt and 16pt padding, an iPad 20pt and 24pt")
    func sizesFollowTheSizeClass() {
        #expect(ButtonLabelFit.pointSize(horizontal: .compact, vertical: .regular) == 15)
        #expect(ButtonLabelFit.horizontalPadding(horizontal: .compact, vertical: .regular) == 16)
        #expect(ButtonLabelFit.font(horizontal: .compact, vertical: .regular) == DesignTokens.Typography.buttonCompact)

        #expect(ButtonLabelFit.pointSize(horizontal: .regular, vertical: .regular) == 20)
        #expect(ButtonLabelFit.horizontalPadding(horizontal: .regular, vertical: .regular) == 24)
        #expect(ButtonLabelFit.font(horizontal: .regular, vertical: .regular) == DesignTokens.Typography.button)
    }

    /// The two point sizes are written out here because a `Font` will not
    /// report its own size. If a token moves and these do not, every width in
    /// this suite is measuring the wrong face — so tie them to the source.
    @Test("The point-size constants match the Typography tokens they stand for")
    func pointSizesMatchTokens() throws {
        // Whitespace-tolerant: DesignTokens is a protected file this suite only
        // reads, so a reformat there must not fail here with a misleading
        // message about the point size. Only the size itself is pinned.
        let tokens = StyleRepo.strippingComments(try StyleRepo.source("DesignTokens.swift"))
        func size(of key: String) -> [String] {
            StyleRepo.matches(#"let\s+\#(key)\s*=\s*Font\.brand\([^)]*size:\s*([0-9.]+)\s*\)"#, in: tokens)
        }
        #expect(size(of: "button") == ["\(Int(ButtonLabelFit.pointSize))"],
                "Typography.button is \(size(of: "button")), ButtonLabelFit.pointSize is \(ButtonLabelFit.pointSize)")
        #expect(size(of: "buttonCompact") == ["\(Int(ButtonLabelFit.compactPointSize))"],
                "Typography.buttonCompact is \(size(of: "buttonCompact")), ButtonLabelFit.compactPointSize is \(ButtonLabelFit.compactPointSize)")
    }

    // MARK: the single-line rule

    @Test("The rule is one line, and the floor stays legible")
    func singleLineWithALegibleFloor() {
        #expect(ButtonLabelFit.lineLimit == 1)
        // 0.8 of the compact face is 12pt. Anything below 10pt is not read off
        // a phone at arm's length, and a friend code is read off the glass.
        #expect(ButtonLabelFit.minimumScaleFactor * ButtonLabelFit.compactPointSize >= 12)
        #expect(ButtonLabelFit.minimumScaleFactor < 1)
    }

    @Test("All three shared styles apply the rule, and none reads only the vertical class")
    func everyStyleConsumesTheRule() throws {
        let source = StyleRepo.strippingComments(try StyleRepo.source("ButtonStyles.swift"))
        let bodies = source.components(separatedBy: "makeBody").dropFirst()
        #expect(bodies.count == 3)
        for body in bodies {
            #expect(body.contains("lineLimit(ButtonLabelFit.lineLimit)"))
            #expect(body.contains("minimumScaleFactor(ButtonLabelFit.minimumScaleFactor)"))
            #expect(body.contains("ButtonLabelFit.font(horizontal: horizontalSizeClass, vertical: verticalSizeClass)"))
        }
        #expect(!source.contains("verticalSizeClass == .compact"), "a style still decides off the vertical class alone")
        #expect(StyleRepo.matches(#"@Environment\(\\\.horizontalSizeClass\)"#, in: source, group: 0).count == 3)
    }

    // MARK: real rows at 375pt

    /// The rows that broke on Nate's iPhone 13 mini, measured.
    ///
    /// Each is (name, buttons, fixed non-button width, gaps). The share control
    /// on the profile card is icon-only, so it is modelled as a one-em glyph.
    @Test("Every real row fits a 375pt portrait phone at the compact size")
    func realRowsFitAt375() {
        let h: UserInterfaceSizeClass? = .compact
        let v: UserInterfaceSizeClass? = .regular
        let available = Self.cardWidth(screen: 375, horizontal: h, vertical: v)
        let iconSize = ButtonLabelFit.pointSize(horizontal: h, vertical: v)
        let iconButton = ButtonLabelFit.minimumButtonWidth(labelWidth: iconSize, horizontal: h, vertical: v)

        let rows: [(String, CGFloat)] = [
            // Profile: the 28pt code, Copy/Copied, and the icon-only share.
            ("profile code card",
             Self.rowWidth(buttons: ["Copied"],
                           fixed: Self.monoWidth("U1HUAAUA", pointSize: 28) + iconButton,
                           gaps: 2, horizontal: h, vertical: v)),
            // Friends "Your code": the 24pt code and the Share code button.
            ("friends your-code card",
             Self.rowWidth(buttons: ["Share code"],
                           fixed: Self.monoWidth("RSPRZALR", pointSize: 24),
                           gaps: 1, horizontal: h, vertical: v)),
            // Lobby: Copy and Share, side by side, each half the row.
            ("lobby copy/share",
             Self.rowWidth(buttons: ["Copied", "Share"], gaps: 1, horizontal: h, vertical: v)),
        ]

        for (name, total) in rows {
            #expect(total <= available, "\(name) needs \(total)pt of \(available)pt")
        }
    }

    @Test("The full-size face is what overflowed those rows — the compact one is doing the work")
    func theFullSizeFaceWouldNotFit() {
        let available = Self.cardWidth(screen: 375, horizontal: .compact, vertical: .regular)
        let iconSize = ButtonLabelFit.pointSize(horizontal: .regular, vertical: .regular)
        let iconButton = ButtonLabelFit.minimumButtonWidth(labelWidth: iconSize, horizontal: .regular, vertical: .regular)

        // The same profile row, sized as a portrait phone used to size it.
        let asShipped = Self.rowWidth(
            buttons: ["Copied"],
            fixed: Self.monoWidth("U1HUAAUA", pointSize: 28) + iconButton,
            gaps: 2, horizontal: .regular, vertical: .regular
        )
        #expect(asShipped > available, "the old sizing fits after all — this suite has no teeth")
    }

    // MARK: the friend code, everywhere it is drawn

    /// Every `.swift` under `Willagrams/`, comments stripped.
    static func appSources() throws -> [(path: String, text: String)] {
        let root = StyleRepo.root.appendingPathComponent("Willagrams")
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return try walk.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { relative in
                let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
                return (path: "Willagrams/" + relative, text: StyleRepo.strippingComments(text))
            }
    }

    /// The modifier chain applied to whatever ends at `end`: every following
    /// line that begins with a `.`, and no further. A fixed character window
    /// would either stop mid-chain or run into the next view.
    static func modifierChain(after end: String.Index, in source: String) -> String {
        var chain = ""
        for line in source[end...].split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(".") else { break }
            chain += trimmed + "\n"
        }
        return chain
    }

    /// A friend code has to survive in full: readable and copyable, never
    /// shrunk toward illegibility and never clipped to an ellipsis.
    ///
    /// This scans the whole app rather than a list of files, because the
    /// failure it guards against is precisely a site nobody listed — the code
    /// under the display name on the profile header was exactly that. Any
    /// `Text(…friendCode)` anywhere in `Willagrams/`, however the binding is
    /// spelled, has to carry the guard. A multi-line accessibility spelling
    /// (`Text(code.map(String.init).joined(…))`) is not a rendered code and is
    /// not matched: the argument must be a plain binding path.
    @Test("Every friend-code render in the app is single-line and fixed-size")
    func friendCodesAreFixedSize() throws {
        let pattern = #"Text\(\s*[A-Za-z0-9_.]*[fF]riendCode\s*\)"#
        var sites: [String] = []

        for file in try Self.appSources() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = file.text as NSString
            for match in regex.matches(in: file.text, range: NSRange(location: 0, length: ns.length)) {
                let call = ns.substring(with: match.range)
                guard let end = Range(match.range, in: file.text)?.upperBound else { continue }
                let chain = Self.modifierChain(after: end, in: file.text)
                let site = "\(file.path) \(call)"
                sites.append(site)

                #expect(chain.contains(".lineLimit(ButtonLabelFit.lineLimit)"), "\(site) may still wrap")
                #expect(chain.contains(".fixedSize(horizontal: true, vertical: false)"), "\(site) may still be squeezed")
                #expect(!chain.contains("minimumScaleFactor"), "\(site) may shrink below legibility")
                #expect(!chain.contains("truncationMode"), "\(site) may be clipped to an ellipsis")
            }
        }

        // Not the assertion — the scan above is. This only catches a scan that
        // has stopped finding anything at all.
        #expect(sites.count >= 4, "the scan found \(sites.count) friend-code renders: \(sites)")
    }
}
