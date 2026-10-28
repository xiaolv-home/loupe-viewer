import Testing
import Foundation
@testable import LoupeCore

@Suite("数字格式")
struct NumberFormatTests {
    func f(_ v: Double, _ code: String) -> String { NumberFormat.format(.number(v), code: code).text }

    @Test("千分位、小数、百分比、货币、科学计数")
    func numbers() {
        #expect(f(1234567.891, "#,##0.00") == "1,234,567.89")
        #expect(f(1234.5, "0") == "1235")
        #expect(f(0.1234, "0.0%") == "12.3%")
        #expect(f(1284567.5, "\"¥\"#,##0.00") == "¥1,284,567.50")
        #expect(f(1500, "[$¥-804]#,##0") == "¥1,500")
        #expect(f(12345, "0.00E+00") == "1.23E+04")
        #expect(f(3, "000") == "003")
        #expect(f(1234567, "#,##0,\"千\"") == "1,235千")
    }

    @Test("正负零分段与颜色")
    func sections() {
        let neg = NumberFormat.format(.number(-0.052), code: "0.0%;[Red]-0.0%")
        #expect(neg.text == "-5.2%")
        #expect(neg.color != nil)
        #expect(f(-5, "#,##0;(#,##0)") == "(5)")
        #expect(f(0, "0.00;-0.00;\"—\"") == "—")
    }

    @Test("日期与时间格式")
    func dates() {
        let d = CellValue.serial(from: ISO8601DateFormatter().date(from: "2019-03-08T14:05:09Z")!)
        #expect(f(d, "yyyy\"年\"m\"月\"d\"日\"") == "2019年3月8日")
        #expect(f(d, "yyyy/m/d") == "2019/3/8")
        #expect(f(d, "yyyy-mm-dd hh:mm") == "2019-03-08 14:05")
        #expect(f(d, "h:mm AM/PM") == "2:05 PM")
        #expect(f(d, "m\"月\"d\"日\"") == "3月8日")
        #expect(StylesParser.isDateFormat("yyyy\"年\"m\"月\"d\"日\""))
        #expect(!StylesParser.isDateFormat("#,##0.00"))
    }

    @Test("文本格式与 General")
    func text() {
        #expect(NumberFormat.format(.text("abc"), code: "\"编号：\"@").text == "编号：abc")
        #expect(f(12.5, "General") == "12.5")
    }

    @Test("颜色解析与色调")
    func colors() {
        #expect(RGBA(hex: "FFC0392B") == RGBA(r: 0xC0, g: 0x39, b: 0x2B))
        let light = RGBA(hex: "4472C4")!.tinted(0.6)
        #expect(light.r > 0xA0 && light.b > 0xD0)
        #expect(RGBA(hex: "4472C4")!.tinted(-0.5).b < 0xC4)
    }
}

@Suite("表格样式读取")
struct StyleReaderTests {
    static let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/office/report-styled.xlsx")

    @Test("填充、字体、合并、列宽、冻结、隐藏列、数字格式")
    func styled() throws {
        try #require(FileManager.default.fileExists(atPath: Self.url.path))
        let wb = try SpreadsheetReader.readXLSX(url: Self.url)
        let s = wb.sheets[0]
        let title = try #require(wb.style(0, 0, 0))
        #expect(title.fill == RGBA(hex: "C0392B"))
        #expect(title.bold)
        #expect(title.fontColor == RGBA(hex: "FFFFFF"))
        #expect(title.hAlign == .center)
        #expect(s.merges.contains(MergeRange(r0: 0, c0: 0, r1: 0, c1: 5)))
        let header = try #require(wb.style(0, 1, 0))
        #expect(header.fill != nil)             // theme accent with tint
        #expect(header.borders.contains(.bottom))
        #expect(s.frozenRows == 2)
        #expect(s.hiddenColumns.contains(5))
        #expect(abs((s.columnWidths[0] ?? 0) - 16) < 1)
        #expect(s.rowHeights[0] == 30)
        #expect(wb.formatted(0, 2, 2).text == "2019年3月8日")
        #expect(wb.formatted(0, 2, 3).text == "¥1,284,567.50")
        let neg = wb.formatted(0, 3, 4)
        #expect(neg.text == "-5.2%")
        #expect(neg.color != nil)
        #expect(wb.formatted(0, 6, 3).text == "¥3,468,652.65")    // uncached SUM computed by Loupe
    }
}
