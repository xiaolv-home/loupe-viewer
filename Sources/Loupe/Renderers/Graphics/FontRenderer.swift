import AppKit
import SwiftUI
import CoreText
import LoupeCore

/// One face of a font file.
struct FontFace: Identifiable {
    let id: Int
    let descriptor: CTFontDescriptor

    func font(_ size: CGFloat) -> CTFont { CTFontCreateWithFontDescriptor(descriptor, size, nil) }

    func name(_ key: CFString) -> String? {
        CTFontCopyName(font(12), key) as String?
    }
    var family: String { name(kCTFontFamilyNameKey) ?? "未知字体" }
    var style: String { name(kCTFontStyleNameKey) ?? "Regular" }

    func supports(_ s: String) -> Bool {
        let f = font(12)
        let utf16 = Array(s.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        return CTFontGetGlyphsForCharacters(f, utf16, &glyphs, utf16.count) && !glyphs.contains(0)
    }
}

/// Type specimen in the spirit of a foundry proof sheet. Fonts are loaded privately
/// (never installed or registered system-wide).
@MainActor
final class FontRenderer: NSObject, Renderer, ObservableObject {
    static let engineName = "CoreText"
    static func canHandle(_ file: FileContext) -> Bool { !file.isDirectory }

    @Published var faces: [FontFace] = []
    @Published var selected = 0
    private var file: FileContext?

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.file = file
        let url = file.url
        guard let arr = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !arr.isEmpty else {
            throw RenderError.unreadable("CoreText 无法读取该字体（可能已损坏或格式不受支持）")
        }
        faces = arr.enumerated().map { FontFace(id: $0.offset, descriptor: $0.element) }
        // Start on the upright regular face of a family, when there is one.
        let preferred = ["Regular", "Roman", "Book", "Normal", "Medium", "常规体"]
        selected = faces.first(where: { preferred.contains($0.style) })?.id ?? 0
        let v = RendererHostingView(FontSpecimen(r: self))
        v.sizingOptions = []
        return v
    }

    func cleanup() { faces = [] }

    var face: FontFace? { faces.indices.contains(selected) ? faces[selected] : nil }

    var statusText: String {
        guard let f = face else { return "" }
        return "\(f.family) \(f.style) · \(CTFontGetGlyphCount(f.font(12))) 个字形" + (faces.count > 1 ? " · \(faces.count) 个字面" : "")
    }

    var infoSections: [InfoSection] {
        guard let f = face else { return [] }
        let font = f.font(12)
        var items: [InfoItem] = [InfoItem("字族", f.family), InfoItem("字重/样式", f.style)]
        let keys: [(String, CFString)] = [("全名", kCTFontFullNameKey), ("PostScript 名", kCTFontPostScriptNameKey),
                                          ("版本", kCTFontVersionNameKey), ("设计师", kCTFontDesignerNameKey),
                                          ("厂商", kCTFontManufacturerNameKey), ("版权", kCTFontCopyrightNameKey),
                                          ("授权", kCTFontLicenseNameKey)]
        for (label, key) in keys {
            if let v = f.name(key), !v.isEmpty { items.append(InfoItem(label, v.count > 200 ? String(v.prefix(200)) + "…" : v)) }
        }
        items.append(InfoItem("字形数", "\(CTFontGetGlyphCount(font))"))
        if let langs = CTFontCopySupportedLanguages(font) as? [String], !langs.isEmpty {
            let names = langs.prefix(12).compactMap { Locale(identifier: "zh_CN").localizedString(forIdentifier: $0) }
            items.append(InfoItem("支持语言", names.joined(separator: "、") + (langs.count > 12 ? " 等 \(langs.count) 种" : "")))
        }
        let traits = CTFontGetSymbolicTraits(font)
        var t: [String] = []
        if traits.contains(.traitMonoSpace) { t.append("等宽") }
        if traits.contains(.traitBold) { t.append("粗体") }
        if traits.contains(.traitItalic) { t.append("斜体") }
        if traits.contains(.traitColorGlyphs) { t.append("彩色字形") }
        if !t.isEmpty { items.append(InfoItem("特性", t.joined(separator: "、"))) }
        return [InfoSection("字体", items)]
    }
}

private struct FontSpecimen: View {
    @ObservedObject var r: FontRenderer
    @State private var sample = ""

    var body: some View {
        if let face = r.face {
            let cjk = face.supports("永")
            let defaultSample = cjk ? "永和九年，岁在癸丑，暮春之初。The quick brown fox jumps over the lazy dog." : "The quick brown fox jumps over the lazy dog. 0123456789"
            let text = sample.isEmpty ? defaultSample : sample
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionLabel(text: "字体样张 · SPECIMEN")
                        Spacer()
                        if r.faces.count > 1 {
                            Picker("", selection: $r.selected) {
                                ForEach(r.faces) { f in Text("\(f.family) · \(f.style)").tag(f.id) }
                            }
                            .labelsHidden().frame(maxWidth: 260)
                        }
                    }
                    HStack(alignment: .bottom, spacing: 28) {
                        Text(cjk ? "永A" : "Aa")
                            .font(Font(face.font(150)))
                            .lineLimit(1)
                            .fixedSize()
                        VStack(alignment: .leading, spacing: 6) {
                            Text(face.family).font(.system(size: 26, weight: .semibold)).tracking(-0.5)
                            Text(face.style).font(.system(size: 14)).foregroundStyle(.secondary)
                            Text("\(CTFontGetGlyphCount(face.font(12))) 字形").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        .padding(.bottom, 26)
                    }
                    .padding(.top, 18)

                    rule.padding(.vertical, 18)
                    TextField("输入任意文字预览", text: $sample)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
                        .frame(maxWidth: 420)

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach([12, 16, 24, 36, 54, 80], id: \.self) { size in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text("\(size)").font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.ember).frame(width: 22, alignment: .trailing)
                                Text(text).font(Font(face.font(CGFloat(size)))).lineLimit(size >= 54 ? 1 : 2)
                            }
                        }
                    }
                    .padding(.top, 22)

                    rule.padding(.vertical, 22)
                    SectionLabel(text: "字符集")
                    GlyphGrid(face: face, cjk: cjk).padding(.top, 12)
                }
                .padding(.horizontal, 48).padding(.vertical, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
        }
    }

    private var rule: some View { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5) }
}

private struct GlyphGrid: View {
    let face: FontFace
    let cjk: Bool

    var chars: [String] {
        var ranges: [ClosedRange<UInt32>] = [0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x21...0x2F, 0xC0...0xFF]
        if cjk { ranges += [0x3001...0x3002, 0x4E00...0x4E60, 0x6C38...0x6C38, 0xFF01...0xFF0F] }
        let cs = CTFontCopyCharacterSet(face.font(12)) as CharacterSet
        var out: [String] = []
        for r in ranges {
            for v in r {
                guard let u = Unicode.Scalar(v), cs.contains(u) else { continue }
                out.append(String(Character(u)))
                if out.count >= 260 { return out }
            }
        }
        return out
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 0)], spacing: 0) {
            ForEach(Array(chars.enumerated()), id: \.offset) { _, c in
                VStack(spacing: 2) {
                    Text(c).font(Font(face.font(24))).frame(height: 32)
                    Text(String(format: "%04X", c.unicodeScalars.first?.value ?? 0))
                        .font(.system(size: 7.5, design: .monospaced)).foregroundStyle(.tertiary)
                }
                .frame(width: 46, height: 52)
                .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
            }
        }
    }
}
