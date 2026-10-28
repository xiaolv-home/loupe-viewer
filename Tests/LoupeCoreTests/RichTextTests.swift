import Testing
import Foundation
@testable import LoupeCore

/// 一个格子里的字分几段、各有格式(一半红、一半黑)。原来读成纯文字,红字全成了黑字。
@Suite("单元格里的富文本")
struct RichTextTests {
    static let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/office/rich-text.xlsx")

    static func sheet() throws -> Sheet {
        try #require(FileManager.default.fileExists(atPath: url.path), "先运行 scripts/gen-richtext-fixture.py")
        return try SpreadsheetReader.readXLSX(url: url).sheets[0]
    }

    @Test("共享字符串里的分段颜色(Excel 的写法)")
    func sharedStringRuns() throws {
        let s = try Self.sheet()
        let runs = try #require(s.richText[Sheet.key(1, 1)], "B2 应该带分段格式")
        #expect(runs.map(\.text).joined() == s.cell(1, 1).display, "各段拼起来就是格子里的字")
        let red = RGBA(hex: "C00000"), black = RGBA(hex: "000000")
        #expect(runs.first { $0.text.hasPrefix("入库批次") }?.color == black)
        #expect(runs.first { $0.text == "单据编号" }?.color == red)
        #expect(runs.first { $0.text == "、" }?.color == black)
        #expect(runs.filter { $0.color == red }.count == 3)
    }

    @Test("直接写在格子里的分段格式(openpyxl 的写法):加粗、字号、斜体")
    func inlineRuns() throws {
        let s = try Self.sheet()
        let runs = try #require(s.richText[Sheet.key(3, 1)], "B4 应该带分段格式")
        #expect(runs.map(\.text).joined() == "普通开头，加粗，大号，斜体")
        #expect(runs.first { $0.text == "加粗" }?.bold == true)
        #expect(runs.first { $0.text == "大号" }?.size == 16)
        #expect(runs.first { $0.text == "斜体" }?.italic == true)
        #expect(runs.first?.isPlain == true, "没写格式的段跟着格子自己的样式")
    }

    @Test("纯文字的格子不记分段")
    func plainCells() throws {
        let s = try Self.sheet()
        #expect(s.richText[Sheet.key(0, 0)] == nil)
        #expect(s.cell(0, 0) == .text("所需字段"))
    }
}
