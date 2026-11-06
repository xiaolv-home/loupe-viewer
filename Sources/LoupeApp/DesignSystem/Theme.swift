import AppKit
import SwiftUI
import LoupeCore

extension NSColor {
    /// Appearance-aware colour from two hex values.
    static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Loupe design tokens — "Proof": a print-proofing table. Content sits on paper sheets
/// with crop marks; colour is used like a spot ink, sparingly.
enum Theme {
    // Surfaces
    static let stage = NSColor.dynamic(light: 0xE6E3DD, dark: 0x19191C)
    static let stageDot = NSColor.dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.06)
    static let surface = NSColor.dynamic(light: 0xFCFBF8, dark: 0x111113)
    static let surfaceRaised = NSColor.dynamic(light: 0xFFFFFF, dark: 0x222226)
    /// The paper a document is printed on.
    static let sheet = NSColor.dynamic(light: 0xFCFBF8, dark: 0x050506)
    static let codeBackground = sheet
    static let ink = NSColor.dynamic(light: 0x1E1D1B, dark: 0xF2EEE6)
    static let hairline = NSColor.dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.14)
    static let cropMark = NSColor.dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.32)
    static let gutterText = NSColor.dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.26)

    // Accent (the spot colour)
    static let emberNS = NSColor.dynamic(light: 0xD9481C, dark: 0xFF7A45)
    static let ember = Color(nsColor: emberNS)
    static let emberSoft = Color(nsColor: NSColor.dynamic(light: 0xD9481C, dark: 0xFF7A45, alpha: 0.18))
    /// Second spot ink used for strings and literals.
    static let indigoNS = NSColor.dynamic(light: 0x2F4FA8, dark: 0xA6E37A)

    // Type
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let label = Font.system(size: 10, weight: .semibold)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    static func tintNS(_ c: FormatCategory) -> NSColor {
        switch c {
        case .document: return .dynamic(light: 0x5B67D8, dark: 0x8A93FF)
        case .image: return .dynamic(light: 0x0E9F8E, dark: 0x2DD4BF)
        case .media: return .dynamic(light: 0xE0464C, dark: 0xFF6B70)
        case .code: return .dynamic(light: 0x2F8A43, dark: 0x7EE787)
        case .data: return .dynamic(light: 0x0B84E0, dark: 0x5AB0FF)
        case .web: return .dynamic(light: 0xE5630F, dark: 0xFF9248)
        case .font: return .dynamic(light: 0x8A47C2, dark: 0xC48BF5)
        case .archive: return .dynamic(light: 0xB07A06, dark: 0xF5C451)
        case .other: return .dynamic(light: 0x7D808A, dark: 0xA3A6B0)
        }
    }
    static func tint(_ c: FormatCategory) -> Color { Color(nsColor: tintNS(c)) }

    static func categoryName(_ c: FormatCategory) -> String {
        switch c {
        case .document: return "文档"
        case .image: return "图像"
        case .media: return "影音"
        case .code: return "代码"
        case .data: return "数据"
        case .web: return "网页"
        case .font: return "字体"
        case .archive: return "归档"
        case .other: return "其他"
        }
    }

    // Syntax palette. Light is duotone "spot ink" (ink, ember, indigo, graphite); on black every
    // kind of token gets its own colour, since weight alone reads poorly there.
    static func syntax(_ k: TokenKind) -> NSColor {
        switch k {
        case .keyword, .tag, .heading: return emberNS
        case .preprocessor: return .dynamic(light: 0xD9481C, dark: 0xC9B8FF, alpha: 0.9)
        case .string, .inserted: return indigoNS
        case .number, .variable: return .dynamic(light: 0x2F4FA8, dark: 0xFFC46B, alpha: 0.9)
        case .comment: return .dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.42)
        case .type, .key: return .dynamic(light: 0x1E1D1B, dark: 0x7DD3C0)
        case .function: return .dynamic(light: 0x1E1D1B, dark: 0x6CB8FF)
        case .deleted, .error: return emberNS
        case .warning: return .dynamic(light: 0xB7791F, dark: 0xE8B65A)
        }
    }

    /// Weight emphasis per token, which carries much of the duotone hierarchy.
    static func syntaxIsBold(_ k: TokenKind) -> Bool {
        switch k {
        case .type, .key, .heading, .error: return true;
        default: return false
        }
    }
}
