import Foundation

/// sRGB colour parsed from SpreadsheetML ("FFRRGGBB").
public struct RGBA: Hashable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) { self.r = r; self.g = g; self.b = b; self.a = a }

    public init?(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 6 { h = "FF" + h }
        guard h.count == 8, let v = UInt32(h, radix: 16) else { return nil }
        a = UInt8((v >> 24) & 0xFF); r = UInt8((v >> 16) & 0xFF); g = UInt8((v >> 8) & 0xFF); b = UInt8(v & 0xFF)
        if a == 0 { a = 255 }  // many writers leave alpha 00 for opaque colours
    }

    public var hex: String { String(format: "FF%02X%02X%02X", r, g, b) }

    /// Excel's tint: negative darkens, positive lightens (applied to HSL lightness).
    public func tinted(_ t: Double) -> RGBA {
        guard t != 0 else { return self }
        var (h, s, l) = hsl
        l = t < 0 ? l * (1 + t) : l * (1 - t) + t
        return RGBA.fromHSL(h, s, min(1, max(0, l)), a: a)
    }

    var hsl: (Double, Double, Double) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let mx = max(rf, gf, bf), mn = min(rf, gf, bf)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        switch mx {
        case rf: h = (gf - bf) / d + (gf < bf ? 6 : 0)
        case gf: h = (bf - rf) / d + 2
        default: h = (rf - gf) / d + 4
        }
        h /= 6
        return (h, s, l)
    }

    static func fromHSL(_ h: Double, _ s: Double, _ l: Double, a: UInt8) -> RGBA {
        func f(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let rr, gg, bb: Double
        if s == 0 {
            rr = l; gg = l; bb = l
        } else {
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s
            let p = 2 * l - q
            rr = f(p, q, h + 1 / 3); gg = f(p, q, h); bb = f(p, q, h - 1 / 3)
        }
        return RGBA(r: UInt8((rr * 255).rounded()), g: UInt8((gg * 255).rounded()), b: UInt8((bb * 255).rounded()), a: a)
    }

    /// The legacy 64-entry palette referenced by `indexed="n"`.
    public static let indexed: [RGBA] = [
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "800000", "008000", "000080", "808000", "800080", "008080", "C0C0C0", "808080",
        "9999FF", "993366", "FFFFCC", "CCFFFF", "660066", "FF8080", "0066CC", "CCCCFF",
        "000080", "FF00FF", "FFFF00", "00FFFF", "800080", "800000", "008080", "0000FF",
        "00CCFF", "CCFFFF", "CCFFCC", "FFFF99", "99CCFF", "FF99CC", "CC99FF", "FFCC99",
        "3366FF", "33CCCC", "99CC00", "FFCC00", "FF9900", "FF6600", "666699", "969696",
        "003366", "339966", "003300", "333300", "993300", "993366", "333399", "333333",
    ].map { RGBA(hex: $0)! }
}
