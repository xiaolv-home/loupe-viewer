import AppKit
import PDFKit
import UniformTypeIdentifiers
import LoupeCore

/// Whether the model in use can look at pictures, and turning pictures into what it is sent.
@MainActor
enum AIVision {
    private static var cache: [String: Bool] = [:]

    /// Local servers are asked (LM Studio reports "vlm", Ollama a "vision" capability);
    /// cloud models are known by name.
    static func supports(_ e: AIEndpoint) async -> Bool {
        let key = e.baseURL.absoluteString + "|" + e.model
        if let v = cache[key] { return v }
        let v = e.isLocal ? await askLocalServer(e) : knownVisionModel(e.model)
        cache[key] = v
        return v
    }

    static func knownVisionModel(_ model: String) -> Bool {
        let m = model.lowercased()
        if m.hasPrefix("deepseek") || m.contains("deepseek-ai/deepseek-v") || m.contains("deepseek-r") { return m.contains("vl") }
        let markers = ["claude", "gpt-4o", "gpt-4.1", "gpt-5", "o3", "o4", "gemini", "vl", "vision", "4v", "-v-", "qwen3.5", "qwen3.6",
                       "kimi-latest", "kimi-k2.5", "glm-4.5v", "glm-4.6v", "doubao-seed", "doubao-1.5-vision", "llava", "pixtral", "openrouter/auto"]
        return markers.contains { m.contains($0) }
    }

    private static func askLocalServer(_ e: AIEndpoint) async -> Bool {
        var root = e.baseURL
        if root.lastPathComponent == "v1" { root.deleteLastPathComponent() }
        // LM Studio
        if let (d, r) = try? await AIHTTP.session.data(from: root.appendingPathComponent("api/v0/models")),
           (r as? HTTPURLResponse)?.statusCode == 200,
           let m = AIJSON.parse(d)?["data"]?.array?.first(where: { $0["id"]?.string == e.model }) {
            return m["type"]?.string == "vlm"
        }
        // Ollama
        var req = URLRequest(url: root.appendingPathComponent("api/show"))
        req.httpMethod = "POST"
        req.httpBody = AIJSON.object(["model": .string(e.model)]).data()
        req.timeoutInterval = 5
        if let (d, r) = try? await AIHTTP.session.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 {
            return AIJSON.parse(d)?["capabilities"]?.array?.contains(.string("vision")) ?? false
        }
        return knownVisionModel(e.model)
    }

    // MARK: Pictures

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]

    /// A picture file (or one page of a PDF) scaled to at most 1600 px on its long side —
    /// enough to read small print, small enough to send.
    nonisolated static func load(_ url: URL, page: Int = 1, maxPixels: Int = 1600) throws -> (AIImage, CGSize) {
        let cg: CGImage
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { throw AIError("PDF 打不开") }
            guard let p = doc.page(at: max(0, min(page - 1, doc.pageCount - 1))) else { throw AIError("没有第 \(page) 页") }
            let box = p.bounds(for: .mediaBox)
            let scale = CGFloat(maxPixels) / max(box.width, box.height)
            let img = p.thumbnail(of: NSSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
            guard let c = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw AIError("PDF 页面渲染失败") }
            cg = c
        } else {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw AIError("图片打不开") }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: maxPixels]
            guard let c = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw AIError("图片打不开") }
            cg = c
        }
        return (try encode(cg), CGSize(width: cg.width, height: cg.height))
    }

    /// A pasted or dropped picture.
    nonisolated static func image(from ns: NSImage, maxPixels: Int = 1600) throws -> AIImage {
        guard let tiff = ns.tiffRepresentation, let src = CGImageSourceCreateWithData(tiff as CFData, nil) else { throw AIError("图片读不出来") }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw AIError("图片读不出来") }
        return try encode(cg)
    }

    nonisolated static func encode(_ cg: CGImage) throws -> AIImage {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw AIError("图片编码失败") }
        // JPEG has no transparency: draw onto white first so clear areas do not turn black.
        let w = cg.width, h = cg.height
        let flat: CGImage = {
            guard cg.alphaInfo != .none, cg.alphaInfo != .noneSkipLast, cg.alphaInfo != .noneSkipFirst,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return cg }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage() ?? cg
        }()
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw AIError("图片编码失败") }
        return AIImage(mediaType: "image/jpeg", base64: (data as Data).base64EncodedString())
    }

    /// Text recognised in pictures, for models that cannot see.
    nonisolated static func describe(_ image: AIImage) -> String {
        guard let d = Data(base64Encoded: image.base64), let src = CGImageSourceCreateWithData(d as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "（图片无法识别）" }
        return (try? DocumentText.ocr(cg)) ?? "（图片里没有识别到文字）"
    }
}
