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
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Loupe design tokens — "Proof": a print-proofing table. Content sits on paper sheets
/// with crop marks; colour is used like a spot ink, sparingly.
enum Theme {
    // Surfaces
    static let stage = NSColor.dynamic(light: 0xE6E3DD, dark: 0x1B1C1F)
    static let stageDot = NSColor.dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.05)
    static let surface = NSColor.dynamic(light: 0xFCFBF8, dark: 0x25262A)
    static let surfaceRaised = NSColor.dynamic(light: 0xFFFFFF, dark: 0x2B2C31)
    /// The paper a document is printed on.
    static let sheet = NSColor.dynamic(light: 0xFCFBF8, dark: 0x232428)
    static let codeBackground = sheet
    static let ink = NSColor.dynamic(light: 0x1E1D1B, dark: 0xE9E5DD)
    static let hairline = NSColor.dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.10)
    static let cropMark = NSColor.dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.32)
    static let gutterText = NSColor.dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.26)

    // Accent (the spot colour)
    static let emberNS = NSColor.dynamic(light: 0xD9481C, dark: 0xFF6A3D)
    static let ember = Color(nsColor: emberNS)
    static let emberSoft = Color(nsColor: NSColor.dynamic(light: 0xD9481C, dark: 0xFF6A3D, alpha: 0.14))
    /// Second spot ink used for strings and literals.
    static let indigoNS = NSColor.dynamic(light: 0x2F4FA8, dark: 0x9DB2F5)

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

    // Syntax palette: duotone "spot ink" — ink, ember, indigo and graphite only.
    static func syntax(_ k: TokenKind) -> NSColor {
        switch k {
        case .keyword, .tag, .heading: return emberNS
        case .preprocessor: return .dynamic(light: 0xD9481C, dark: 0xFF6A3D, alpha: 0.75)
        case .string, .inserted: return indigoNS
        case .number, .variable: return .dynamic(light: 0x2F4FA8, dark: 0x9DB2F5, alpha: 0.8)
        case .comment: return .dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.38)
        case .type, .key: return .dynamic(light: 0x1E1D1B, dark: 0xF4F1EA)
        case .function: return ink
        case .deleted, .error: return emberNS
        case .warning: return .dynamic(light: 0xB7791F, dark: 0xE8B65A)
        }
    }

    /// Weight emphasis per token, which carries much of the duotone hierarchy.
    static func syntaxIsBold(_ k: TokenKind) -> Bool {
        switch k { case .type, .key, .heading, .error: return true; default: return false }
    }
}

// MARK: - Reusable SwiftUI pieces

/// Format mark: a square ink swatch followed by the letter-spaced type token.
struct FormatBadge: View {
    let token: String
    let category: FormatCategory
    var size: CGFloat = 9.5

    var body: some View {
        HStack(spacing: 5) {
            Rectangle().fill(Theme.tint(category)).frame(width: size * 0.85, height: size * 0.85)
            Text(token.prefix(7))
                .font(.system(size: size, weight: .bold, design: .default))
                .tracking(1.6)
                .foregroundStyle(.primary.opacity(0.85))
        }
        .fixedSize()
    }
}

/// Printer's registration mark (circle + cross), drawn small.
struct RegistrationMark: View {
    var size: CGFloat = 11
    var color: Color = .primary.opacity(0.45)
    var body: some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let r = min(sz.width, sz.height) / 2 * 0.62
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color), lineWidth: 0.9)
            var p = Path()
            p.move(to: CGPoint(x: 0, y: c.y)); p.addLine(to: CGPoint(x: sz.width, y: c.y))
            p.move(to: CGPoint(x: c.x, y: 0)); p.addLine(to: CGPoint(x: c.x, y: sz.height))
            ctx.stroke(p, with: .color(color), lineWidth: 0.9)
        }
        .frame(width: size, height: size)
    }
}

/// Printer's colour bar: a row of swatches stepping down in density.
struct ColorBar: View {
    let category: FormatCategory
    var body: some View {
        HStack(spacing: 0) {
            ForEach([1.0, 0.7, 0.45, 0.25], id: \.self) { o in
                Rectangle().fill(Theme.tint(category).opacity(o)).frame(width: 7, height: 7)
            }
            Rectangle().fill(Color.primary.opacity(0.85)).frame(width: 7, height: 7)
            Rectangle().fill(Theme.ember).frame(width: 7, height: 7)
        }
    }
}

/// Small-caps style section label.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(2.2)
            .foregroundStyle(.secondary)
    }
}

/// Compact icon button used in the lens bar and status strip.
struct LensButton: View {
    let symbol: String
    var help: String = ""
    var active: Bool = false
    var enabled: Bool = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 28, height: 24)
                .foregroundStyle(active ? Theme.ember : (hover ? Color.primary : Color.primary.opacity(0.72)))
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Theme.emberSoft : (hover ? Color.primary.opacity(0.08) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Text toggle pill (e.g. "渲染 | 源码").
struct LensSegment: View {
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                Button { selection = i } label: {
                    Text(options[i])
                        .font(.system(size: 11, weight: selection == i ? .semibold : .regular))
                        .padding(.horizontal, 9).frame(height: 22)
                        .foregroundStyle(selection == i ? Theme.ember : Color.primary.opacity(0.7))
                        .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(selection == i ? Theme.emberSoft : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

struct LensDivider: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 3) }
}

/// Monospaced numeric readout ("125%", "3 / 12").
struct Readout: View {
    let text: String
    var minWidth: CGFloat = 0
    var body: some View {
        Text(text).font(Theme.mono(11, .medium)).foregroundStyle(.secondary)
            .frame(minWidth: minWidth).monospacedDigit()
    }
}
