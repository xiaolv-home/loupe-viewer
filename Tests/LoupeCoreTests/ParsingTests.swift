import Testing
import Foundation
@testable import LoupeCore

@Suite("编码检测")
struct EncodingTests {
    let sample = "床前明月光，疑是地上霜。举头望明月，低头思故乡。\n"

    func cf(_ e: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
    }

    @Test("UTF-8 / 带 BOM / UTF-16 BOM / 无 BOM UTF-16")
    func unicode() {
        #expect(TextEncodingDetector.detect(Data(sample.utf8)).encoding == .utf8)
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data(sample.utf8)
        let d = TextEncodingDetector.detect(bom)
        #expect(d.bomLength == 3)
        #expect(TextEncodingDetector.decode(bom, as: d) == sample)
        let u16 = sample.data(using: .utf16)!   // with BOM
        #expect(TextEncodingDetector.decode(u16).0 == sample)
        let le = "plain ascii in utf16".data(using: .utf16LittleEndian)!
        #expect(TextEncodingDetector.detect(le).encoding == .utf16LittleEndian)
    }

    @Test("GBK / GB18030 中文不乱码")
    func gbk() {
        let data = (sample + "繁體混排：臺灣\n").data(using: cf(.GB_18030_2000))!
        let (text, enc) = TextEncodingDetector.decode(data)
        #expect(enc.name.contains("GB"))
        #expect(text.hasPrefix("床前明月光"))
    }

    @Test("Big5 与 Shift_JIS")
    func otherCJK() {
        let big5 = String(repeating: "繁體中文測試：臺北市資訊電腦。\n", count: 4).data(using: cf(.big5_HKSCS_1999))!
        #expect(TextEncodingDetector.decode(big5).0.contains("臺北市"))
        let sjis = String(repeating: "日本語のテキスト、ひらがなとカタカナ。\n", count: 4).data(using: .shiftJIS)!
        let (t, e) = TextEncodingDetector.decode(sjis)
        #expect(e.name == "Shift_JIS")
        #expect(t.contains("ひらがな"))
    }

    @Test("文本 / 二进制嗅探")
    func sniff() {
        #expect(TextSniffer.isLikelyText(Data("hello 世界".utf8)))
        #expect(!TextSniffer.isLikelyText(Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0x10, 0x00])))
        #expect(TextSniffer.isLikelyText(sample.data(using: cf(.GB_18030_2000))!))
    }

    @Test("截断在多字节字符中间的 UTF-8 仍被认可")
    func truncatedUTF8() {
        let d = Data("中文".utf8).dropLast()
        #expect(TextEncodingDetector.isValidUTF8(Data(d)))
        #expect(!TextEncodingDetector.isValidUTF8(Data([0xC3, 0x28])))
    }
}

@Suite("CSV 解析")
struct CSVTests {
    @Test("引号、转义、逗号、换行与 CRLF")
    func rfc4180() {
        let rows = CSVParser.parse("a,b,c\r\n1,\"x, y\",\"he said \"\"hi\"\"\"\r\n2,\"line1\nline2\",\r\n")
        #expect(rows.count == 3)
        #expect(rows[1] == ["1", "x, y", "he said \"hi\""])
        #expect(rows[2] == ["2", "line1\nline2", ""])
    }

    @Test("分块喂入与结果一致")
    func streaming() {
        let text = (0..<500).map { "\($0),\"名称 \($0)\",\($0 * 2)" }.joined(separator: "\n")
        let whole = CSVParser.parse(text)
        var p = CSVParser(delimiter: 44)
        var rows: [[String]] = []
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            let n = min(37, bytes.count - i)
            rows += p.feed(Data(bytes[i..<i + n]))
            i += n
        }
        if let last = p.finish() { rows.append(last) }
        #expect(rows == whole)
        #expect(rows.count == 500)
    }

    @Test("分隔符嗅探")
    func sniff() {
        #expect(CSVSniffer.sniffDelimiter("a\tb\tc\n1\t2\t3\n4\t5\t6\n") == 9)
        #expect(CSVSniffer.sniffDelimiter("a;b\n1;2\n3;4\n") == 59)
        #expect(CSVSniffer.sniffDelimiter("just a sentence\nanother one\n") == nil)
    }
}

@Suite("字幕解析")
struct SubtitleTests {
    @Test("SRT")
    func srt() {
        let cues = SubtitleParser.parse("1\n00:00:01,500 --> 00:00:03,000\n你好 <i>世界</i>\n\n2\n00:00:04,000 --> 00:00:05,000\n第二条\n", ext: "srt")
        #expect(cues.count == 2)
        #expect(cues[0].start == 1.5)
        #expect(cues[0].text == "你好 世界")
        #expect(SubtitleParser.cue(at: 2, in: cues)?.text == "你好 世界")
        #expect(SubtitleParser.cue(at: 3.5, in: cues) == nil)
    }

    @Test("WebVTT 无小时字段")
    func vtt() {
        let cues = SubtitleParser.parse("WEBVTT\n\n00:01.000 --> 00:02.500 align:start\nVTT 字幕\n", ext: "vtt")
        #expect(cues.first?.start == 1)
        #expect(cues.first?.end == 2.5)
    }

    @Test("ASS 去除样式标签、保留文本中的逗号")
    func ass() {
        let src = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\b1}粗体{\\b0}，逗号, 保留\\N第二行\n"
        let cues = SubtitleParser.parse(src, ext: "ass")
        #expect(cues.count == 1)
        #expect(cues[0].text == "粗体，逗号, 保留\n第二行")
    }
}

@Suite("JSON 解析")
struct JSONTests {
    @Test("保持键顺序")
    func order() throws {
        let v = try JSONParser.parse(Data(#"{"z":1,"a":2,"m":{"y":true,"b":null}}"#.utf8))
        guard case .object(let m) = v else { Issue.record("not object"); return }
        #expect(m.map(\.0) == ["z", "a", "m"])
    }

    @Test("注释、尾逗号、Unicode 转义与代理对")
    func lenient() throws {
        let v = try JSONParser.parse(Data("// c\n{\"s\": \"\\u4e2d\\ud83d\\ude00\", /* x */ \"a\": [1,2,],}".utf8))
        guard case .object(let m) = v, case .string(let s) = m[0].1 else { Issue.record("bad"); return }
        #expect(s == "中😀")
    }

    @Test("JSON Lines 合并为数组")
    func jsonl() throws {
        let v = try JSONParser.parse(Data("{\"a\":1}\n{\"a\":2}\n".utf8))
        guard case .array(let a) = v else { Issue.record("not array"); return }
        #expect(a.count == 2)
    }

    @Test("错误报告位置")
    func error() {
        #expect(throws: JSONParseError.self) { try JSONParser.parse(Data("{\"a\": [1, 2,".utf8)) }
    }

    @Test("属性列表转换为同一树结构")
    func plist() {
        let v = JSONValue.fromPlist(["b": 1, "a": ["x", true]] as [String: Any])
        guard case .object(let m) = v else { Issue.record("bad"); return }
        #expect(m.map(\.0) == ["a", "b"])
    }
}

@Suite("大文件行索引")
struct LineIndexTests {
    @Test("UTF-8 行切分与按需解码")
    func utf8() {
        let idx = LineIndex(data: Data("第一行\n第二行\r\nthird\nlast".utf8))
        idx.build()
        #expect(idx.lineCount == 4)
        #expect(idx.line(1) == "第二行")
        #expect(idx.line(3) == "last")
    }

    @Test("UTF-16 LE 行切分")
    func utf16() {
        let d = "甲\n乙\n丙".data(using: .utf16)!   // BOM + LE on Apple platforms
        let idx = LineIndex(data: d)
        idx.build()
        #expect(idx.lineCount == 3)
        #expect(idx.line(2) == "丙")
    }

    @Test("超长行被截断显示")
    func longLine() {
        let idx = LineIndex(data: Data(String(repeating: "x", count: 100_000).utf8))
        idx.build()
        #expect(idx.line(0, maxBytes: 100).hasSuffix("…"))
    }
}

@Suite("杂项")
struct MiscTests {
    @Test("十六进制行格式")
    func hex() {
        let r = HexDump.row(Data("Hello, Loupe!\u{0}\u{1}\u{2}".utf8), offset: 0)
        #expect(r.offset == "00000000")
        #expect(r.hex.hasPrefix("48 65 6C 6C 6F"))
        #expect(r.ascii == "Hello, Loupe!···")
    }

    @Test("语法高亮：字符串内的关键字不着色")
    func highlighter() throws {
        let h = try #require(SyntaxHighlighter.forLanguage("swift"))
        let code = "let s = \"let inside\" // let comment\nfunc f() {}"
        let tokens = h.tokens(in: code)
        let ns = code as NSString
        let keywords = tokens.filter { $0.kind == .keyword }.map { ns.substring(with: $0.range) }
        #expect(keywords == ["let", "func"])
        #expect(tokens.contains { $0.kind == .string && ns.substring(with: $0.range) == "\"let inside\"" })
        #expect(tokens.contains { $0.kind == .comment })
    }

    @Test("所有语言规则都能编译", arguments: ["swift", "python", "javascript", "typescript", "go", "rust", "c", "cpp", "java", "kotlin",
                                       "ruby", "php", "shell", "sql", "json", "yaml", "toml", "ini", "xml", "html", "css",
                                       "diff", "log", "markdown", "makefile", "dockerfile", "lua", "haskell", "tex"])
    func allLanguages(lang: String) {
        #expect(SyntaxHighlighter.forLanguage(lang) != nil)
    }
}

@Suite("压缩包读取")
struct ArchiveTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/archives")

    @Test("列出 zip / 7z / tar.gz 内容（含中文文件名）", arguments: ["sample.zip", "sample.7z", "sample.tar.gz", "sample.tar.xz"])
    func list(name: String) throws {
        let url = Self.fixtures.appendingPathComponent(name)
        try #require(FileManager.default.fileExists(atPath: url.path), "先运行 scripts/gen-fixtures.py")
        let l = try ArchiveReader.list(url: url)
        let paths = l.entries.map(\.path)
        #expect(paths.contains { $0.hasSuffix("说明.txt") })
        #expect(paths.contains { $0.hasSuffix("main.swift") })
    }

    @Test("损坏的压缩包抛出错误而不是崩溃")
    func corrupt() throws {
        let tmp = TestTemp.dir("zip").appendingPathComponent("bad.zip")
        try Data([0x50, 0x4B, 0x03, 0x04] + (0..<500).map { UInt8($0 % 251) }).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(throws: (any Error).self) { try ArchiveReader.list(url: tmp) }
    }
}
