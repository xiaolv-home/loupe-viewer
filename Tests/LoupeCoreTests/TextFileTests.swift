import Testing
import Foundation
@testable import LoupeCore

@Suite("文本文件保存（编码、BOM、换行原样保留）")
struct TextFileTests {
    func roundTrip(_ data: Data, edit: (String) -> String = { $0 + "追加一行\n" }) throws -> (Data, String, TextFileFormat, Bool) {
        let dir = TestTemp.dir("text")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.md")
        try data.write(to: url)
        let (text, fmt) = try TextFileFormat.read(url)
        let kept = try fmt.write(edit(text), to: url)
        return (try Data(contentsOf: url), text, fmt, kept)
    }

    @Test("UTF-8 + LF：只多出新增的内容")
    func utf8() throws {
        let src = "# 标题\n正文\n"
        let (out, text, fmt, kept) = try roundTrip(Data(src.utf8))
        #expect(text == src)
        #expect(fmt.lineEnding == "\n")
        #expect(kept)
        #expect(out == Data((src + "追加一行\n").utf8))
    }

    @Test("CRLF 编辑时统一成 LF，保存时还原成 CRLF")
    func crlf() throws {
        let (out, text, fmt, _) = try roundTrip(Data("a\r\nb\r\n".utf8))
        #expect(text == "a\nb\n")
        #expect(fmt.lineEnding == "\r\n")
        #expect(out == Data("a\r\nb\r\n追加一行\r\n".utf8))
    }

    @Test("GBK 保持 GBK；BOM 保持 BOM")
    func legacyAndBOM() throws {
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let src = "# 门店周报\n上海、北京、天津的营业额汇总。\n"
        let (out, _, fmt, kept) = try roundTrip(src.data(using: gbk)!)
        #expect(fmt.encoding.encoding == gbk)
        #expect(kept)
        #expect(out == (src + "追加一行\n").data(using: gbk)!)

        let bomSrc = Data([0xEF, 0xBB, 0xBF]) + Data("x\n".utf8)
        let (out2, text2, _, _) = try roundTrip(bomSrc)
        #expect(text2 == "x\n")
        #expect(out2 == Data([0xEF, 0xBB, 0xBF]) + Data("x\n追加一行\n".utf8))
    }

    @Test("原编码写不下的字符：改存 UTF-8 并告知")
    func fallback() throws {
        // GB18030 covers all of Unicode, so use a Shift_JIS file edited with simplified Chinese.
        let (out, _, fmt, kept) = try roundTrip("テキスト日本語の文章です。\nもう一行。\n".data(using: .shiftJIS)!, edit: { $0 + "简体字：门店\n" })
        if fmt.encoding.encoding == .shiftJIS {
            #expect(!kept)
            #expect(String(data: out, encoding: .utf8)?.contains("简体字：门店") == true)
        }
    }
}
