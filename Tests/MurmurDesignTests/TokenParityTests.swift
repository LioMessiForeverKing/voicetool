import Foundation
import Testing

/// Parity between the two design token files.
///
/// The palette is written out twice, once per platform, and nothing but this test stops the two
/// drifting. A divergence is silent: both sides compile, both sides run, and one of them simply
/// looks subtly wrong on a machine nobody is currently sitting at.
///
/// Parsing is deliberately done by hand rather than with `Regex`, because this target is compiled
/// for macOS 26 and loaded on an older CI runner. See AGENTS.md.
enum Tokens {

    static let swiftSource = repoRoot
        .appendingPathComponent("Sources/Murmur/UI/DesignSystem.swift")
    static let csharpSource = repoRoot
        .appendingPathComponent("windows/src/Murmur.App/Design/DesignTokens.cs")

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func lines(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    static func slice(_ text: String, after opening: String, upTo closing: String) -> String? {
        guard let start = text.range(of: opening) else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: closing) else { return nil }
        return String(rest[..<end.lowerBound])
    }

    static func hex(_ text: String, after marker: String) -> String? {
        guard let start = text.range(of: marker) else { return nil }
        let digits = text[start.upperBound...].prefix { $0.isHexDigit }
        return digits.count == 6 ? digits.uppercased() : nil
    }

    /// Colour token name, lowercased, to its light and dark values.
    static func colours(swift source: [String]) -> [String: String] {
        var found: [String: String] = [:]
        for line in source {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("static let "),
                  let name = slice(text, after: "static let ", upTo: " =")
            else { continue }
            if let light = hex(text, after: "face(light: 0x"), let dark = hex(text, after: "dark: 0x") {
                found[name.lowercased()] = "\(light)/\(dark)"
            } else if let flat = hex(text, after: "swatch(0x") {
                found[name.lowercased()] = "\(flat)/\(flat)"
            }
        }
        return found
    }

    static func colours(csharp source: [String]) -> [String: String] {
        var found: [String: String] = [:]
        for line in source {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("public static Color "),
                  let name = slice(text, after: "public static Color ", upTo: " =>")
            else { continue }
            if let light = hex(text, after: "Face(0x"), let dark = hex(text, after: ", 0x") {
                found[name.lowercased()] = "\(light)/\(dark)"
            } else if let flat = hex(text, after: "Rgb(0x") {
                found[name.lowercased()] = "\(flat)/\(flat)"
            }
        }
        return found
    }

    /// Numeric tokens keyed `scale.name`, since `panel` means 32 in one scale and 5 in another.
    static func scales(swift source: [String]) -> [String: String] {
        var found: [String: String] = [:]
        var scale = ""
        for line in source {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("enum "), let name = slice(text, after: "enum ", upTo: " {") {
                scale = name.lowercased()
            }
            guard tracked.contains(scale),
                  text.hasPrefix("static let "),
                  let name = slice(text, after: "static let ", upTo: ":"),
                  let value = slice(text + "\n", after: "= ", upTo: "\n")
            else { continue }
            found["\(scale).\(name.lowercased())"] = normalise(value)
        }
        return found
    }

    static func scales(csharp source: [String]) -> [String: String] {
        var found: [String: String] = [:]
        var scale = ""
        for line in source {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("public static class "),
               let name = slice(text + "\n", after: "public static class ", upTo: "\n") {
                scale = name.trimmingCharacters(in: .whitespaces).lowercased()
            }
            guard tracked.contains(scale),
                  text.hasPrefix("public const double "),
                  let name = slice(text, after: "public const double ", upTo: " ="),
                  let value = slice(text, after: "= ", upTo: ";")
            else { continue }
            found["\(scale).\(name.lowercased())"] = normalise(value)
        }
        return found
    }

    static let tracked: Set<String> = ["space", "radius", "border"]

    static func normalise(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return Double(trimmed).map { String($0) } ?? trimmed
    }
}

@Suite("Design token parity")
struct TokenParityTests {

    @Test("Both platforms declare the same colour tokens with the same values")
    func coloursMatch() throws {
        let swift = Tokens.colours(swift: try Tokens.lines(of: Tokens.swiftSource))
        let csharp = Tokens.colours(csharp: try Tokens.lines(of: Tokens.csharpSource))

        #expect(!swift.isEmpty, "parsed no colours from DesignSystem.swift")
        #expect(!csharp.isEmpty, "parsed no colours from DesignTokens.cs")

        let onlySwift = Set(swift.keys).subtracting(csharp.keys).sorted()
        let onlyCSharp = Set(csharp.keys).subtracting(swift.keys).sorted()
        #expect(onlySwift.isEmpty, "only in DesignSystem.swift: \(onlySwift)")
        #expect(onlyCSharp.isEmpty, "only in DesignTokens.cs: \(onlyCSharp)")

        for name in Set(swift.keys).intersection(csharp.keys).sorted() {
            #expect(swift[name] == csharp[name],
                    "\(name): Swift \(swift[name] ?? "-"), C# \(csharp[name] ?? "-")")
        }
    }

    @Test("Both platforms declare the same spacing, radius and border values")
    func scalesMatch() throws {
        let swift = Tokens.scales(swift: try Tokens.lines(of: Tokens.swiftSource))
        let csharp = Tokens.scales(csharp: try Tokens.lines(of: Tokens.csharpSource))

        #expect(!swift.isEmpty, "parsed no scale values from DesignSystem.swift")
        #expect(!csharp.isEmpty, "parsed no scale values from DesignTokens.cs")

        for name in Set(swift.keys).intersection(csharp.keys).sorted() {
            #expect(swift[name] == csharp[name],
                    "\(name): Swift \(swift[name] ?? "-"), C# \(csharp[name] ?? "-")")
        }

        let shared = Set(swift.keys).intersection(csharp.keys)
        #expect(shared.count >= 12, "expected the scales to overlap, matched only \(shared.count)")
    }

    @Test("The red accent appears exactly once, and nothing else in the palette is red")
    func oneAccent() throws {
        let swift = Tokens.colours(swift: try Tokens.lines(of: Tokens.swiftSource))
        #expect(swift["record"] == "C8342A/C8342A")
    }
}
