import Foundation

/// Shared locations for the style lane's tests.
enum StyleRepo {

    /// Repo root, four levels up from `Tests/StyleTests/Cases/`.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Cases
        .deletingLastPathComponent()   // StyleTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    static let styleDir = root.appendingPathComponent("Willagrams/Style")
    static let fontsDir = root.appendingPathComponent("Willagrams/Resources/Branding/Fonts")
    static let colorsDir = root.appendingPathComponent("Willagrams/Assets.xcassets/Colors")

    static func source(_ name: String) throws -> String {
        try String(contentsOf: styleDir.appendingPathComponent(name), encoding: .utf8)
    }

    /// Every `.swift` under `Willagrams/Style/`.
    static func styleSources() throws -> [(name: String, text: String)] {
        try FileManager.default.contentsOfDirectory(atPath: styleDir.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { (name: $0, text: try source($0)) }
    }

    /// Strips `//` and `/* */` comments so a documented value is not read as a
    /// literal in the source.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        let chars = Array(source)
        var i = 0
        var inString = false

        while i < chars.count {
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : "\0"

            if inString {
                if c == "\\" { out.append(c); if i + 1 < chars.count { out.append(chars[i + 1]) }; i += 2; continue }
                if c == "\"" { inString = false }
                out.append(c); i += 1; continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/" && next == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && next == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            out.append(c); i += 1
        }
        return out
    }

    /// All matches of `pattern`, returning capture group `group`.
    static func matches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            let r = $0.range(at: group)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }
}
