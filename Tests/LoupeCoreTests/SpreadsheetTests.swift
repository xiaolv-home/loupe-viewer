import Testing
import Foundation
@testable import LoupeCore

@Suite("公式引擎")
struct FormulaTests {
    /// Row 1 is a header; data in rows 2–5.
    static let wb: Workbook = {
        let sales = Sheet(name: "销售", rows: [
            [.text("门店"), .text("城市"), .text("营业额"), .text("订单")],
            [.text("A店"), .text("上海"), .number(100), .number(4)],
            [.text("B店"), .text("北京"), .number(250.5), .number(5)],
            [.text("C店"), .text("上海"), .number(80), .number(2)],
            [.text("D店"), .text("深圳"), .text("n/a"), .number(1)]
        ])
        let cities = Sheet(name: "城市 表", rows: [
            [.text("城市"), .text("区域")], [.text("上海"), .text("华东")], [.text("北京"), .text("华北")], [.text("深圳"), .text("华南")]
        ])
        return Workbook(sheets: [sales, cities], source: "test")
    }()

    func ev(_ f: String, row offset: Int = 0) -> FValue {
        FormulaEngine.evaluate(f, in: FormulaContext(workbook: Self.wb, sheet: 0, rowOffset: offset))
    }

    @Test("聚合函数跳过文本", arguments: [
        ("=SUM(C2:C5)", 430.5), ("=AVERAGE(C2:C5)", 143.5), ("=COUNT(C:C)", 3), ("=COUNTA(A2:A5)", 4),
        ("=MAX(C2:C5)", 250.5), ("=MIN(C2:C5)", 80), ("=SUM(D:D)", 12), ("=ROUND(AVERAGE(C2:C4)/3, 2)", 47.83)
    ])
    func aggregates(f: String, expected: Double) {
        #expect(ev(f) == .number(expected))
    }

    @Test("运算优先级、百分号、字符串拼接、比较")
    func operators() {
        #expect(ev("=1+2*3^2") == .number(19))
        #expect(ev("=-2^2") == .number(4))          // Excel: unary minus binds tighter
        #expect(ev("=50%*C2") == .number(50))
        #expect(ev("=A2&\"-\"&B2") == .text("A店-上海"))
        #expect(ev("=C2>C4") == .bool(true))
        #expect(ev("=B2=\"上海\"") == .bool(true))
        #expect(ev("=1/0") == .error("#DIV/0!"))
    }

    @Test("条件函数 SUMIF / COUNTIF / SUMIFS / AVERAGEIF")
    func conditional() {
        #expect(ev("=SUMIF(B2:B5,\"上海\",C2:C5)") == .number(180))
        #expect(ev("=COUNTIF(C2:C5,\">=100\")") == .number(2))
        #expect(ev("=COUNTIF(A2:A5,\"?店\")") == .number(4))
        #expect(ev("=SUMIFS(C2:C5,B2:B5,\"上海\",D2:D5,\">2\")") == .number(100))
        #expect(ev("=AVERAGEIF(B:B,\"上海\",C:C)") == .number(90))
        #expect(ev("=COUNTIFS(B2:B5,\"<>上海\")") == .number(2))
    }

    @Test("VLOOKUP / XLOOKUP / INDEX+MATCH，含跨表与带空格的表名")
    func lookups() {
        #expect(ev("=VLOOKUP(\"北京\",'城市 表'!A:B,2,FALSE)") == .text("华北"))
        #expect(ev("=VLOOKUP(B2,'城市 表'!$A$2:$B$4,2,0)") == .text("华东"))
        #expect(ev("=VLOOKUP(\"广州\",'城市 表'!A:B,2,FALSE)") == .error("#N/A"))
        #expect(ev("=IFERROR(VLOOKUP(\"广州\",'城市 表'!A:B,2,FALSE),\"未知\")") == .text("未知"))
        #expect(ev("=XLOOKUP(\"深圳\",B2:B5,A2:A5)") == .text("D店"))
        #expect(ev("=XLOOKUP(\"杭州\",B2:B5,A2:A5,\"无\")") == .text("无"))
        #expect(ev("=INDEX(A2:A5,MATCH(250.5,C2:C5,0))") == .text("B店"))
        #expect(ev("=MATCH(\"C*\",A2:A5,0)") == .number(3))
    }

    @Test("相对引用随行偏移，绝对引用不动（计算列填充）")
    func relativeFill() {
        #expect(ev("=C2/D2", row: 1) == .number(50.1))          // becomes C3/D3
        #expect(ev("=C2/$D$2", row: 2) == .number(20))          // C4 / D2
        #expect(ev("=IF(C2>90,\"高\",\"低\")", row: 2) == .text("低"))
    }

    @Test("文本与日期函数")
    func textAndDates() {
        #expect(ev("=LEFT(\"上海市黄浦区\",3)") == .text("上海市"))
        #expect(ev("=MID(\"ABCDEF\",2,3)") == .text("BCD"))
        #expect(ev("=LEN(\"中文\")") == .number(2))
        #expect(ev("=SUBSTITUTE(\"a-b-c\",\"-\",\"/\")") == .text("a/b/c"))
        #expect(ev("=TEXTJOIN(\",\",TRUE,B2:B4)") == .text("上海,北京,上海"))
        #expect(ev("=YEAR(DATE(2026,10,23))") == .number(2026))
        #expect(ev("=DAYS(DATE(2026,10,23),DATE(2026,10,1))") == .number(22))
        #expect(ev("=TEXT(1234.5,\"#,##0.00\")") == .text("1,234.50"))
    }

    @Test("错误输入给出提示而不是崩溃")
    func errors() {
        if case .error(let e) = ev("=SUM(") { #expect(e.contains("ERROR")) } else { Issue.record("expected error") }
        if case .error(let e) = ev("=FOO(1)") { #expect(e.contains("#NAME?")) } else { Issue.record("expected error") }
        if case .error(let e) = ev("=VLOOKUP(1,不存在!A:B,2,0)") { #expect(e.contains("找不到工作表")) } else { Issue.record("expected error") }
    }
}

@Suite("表格读取与视图")
struct SpreadsheetReaderTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures")

    @Test("xlsx：多表、共享字符串、日期、公式原文，以及缺缓存值的公式自动计算")
    func xlsx() throws {
        let url = Self.fixtures.appendingPathComponent("office/sales.xlsx")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let wb = try SpreadsheetReader.readXLSX(url: url)
        #expect(wb.sheets.map(\.name) == ["销售", "城市"])
        let s = wb.sheets[0]
        #expect(s.cell(0, 0) == .text("门店"))
        #expect(s.rows.count == 301)
        if case .date = s.cell(1, 2) {} else { Issue.record("C2 should be a date, got \(s.cell(1, 2))") }
        #expect(s.formulas[Sheet.key(1, 5)] == "=D2/E2")
        let d = s.cell(1, 3).number!, e = s.cell(1, 4).number!
        #expect(abs((s.cell(1, 5).number ?? 0) - d / e) < 1e-9)
        let region = FormulaEngine.evaluate("=VLOOKUP(B2,城市!A:B,2,FALSE)", in: FormulaContext(workbook: wb, sheet: 0))
        if case .text(let t) = region { #expect(["华东", "华北", "华南", "西南"].contains(t)) } else { Issue.record("lookup failed: \(region)") }
    }

    @Test("ods：重复行列展开")
    func ods() throws {
        let url = Self.fixtures.appendingPathComponent("office/stock.ods")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let wb = try SpreadsheetReader.readODS(url: url)
        let s = wb.sheets[0]
        #expect(s.name == "库存")
        #expect(s.rows.count == 5)
        #expect(s.cell(1, 1) == .number(12))
        #expect(s.cell(4, 0) == .text("梨"))
    }

    @Test("CSV（GBK）转为表格并识别数字")
    func csv() throws {
        let url = Self.fixtures.appendingPathComponent("data/sales-gbk.csv")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let wb = try SpreadsheetReader.readDelimited(url: url, delimiter: 44)
        let s = wb.sheets[0]
        #expect(s.cell(0, 0) == .text("门店"))
        if case .number = s.cell(1, 3) {} else { Issue.record("营业额 should be numeric") }
        #expect(CellValue.infer("007") == .text("007"))
        #expect(CellValue.infer("1,234.5") == .number(1234.5))
    }

    @Test("筛选、排序、隐藏行与选区统计")
    func query() {
        let s = FormulaTests.wb.sheets[0]
        var q = SheetQuery()
        #expect(q.visibleRows(in: s) == [0, 1, 2, 3, 4])
        q.filters[1] = .values(["上海"])
        #expect(q.visibleRows(in: s) == [0, 1, 3])
        q.filters = [2: .greater(90)]
        #expect(q.visibleRows(in: s) == [0, 1, 2])
        q.filters = [:]
        q.sortColumn = 2; q.ascending = false
        #expect(q.visibleRows(in: s) == [0, 2, 1, 3, 4])      // text "n/a" sorts after numbers
        q.hiddenRows = [1]
        #expect(q.visibleRows(in: s) == [0, 2, 3, 4])
        let st = SelectionStats([.number(1), .text("2"), .empty, .text("x"), .number(3)])
        #expect(st.sum == 6)
        #expect(st.numeric == 3)
        #expect(st.average == 2)
        #expect(st.nonEmpty == 4)
        #expect(q.distinctValues(in: s, column: 1).first?.0 == "上海")
    }

    @Test("带前缀的 xlsx（.NET Open XML SDK 写法：<x:row>、绝对路径、BOM）能读出内容")
    func prefixedXLSX() throws {
        let dir = TestTemp.dir("prefixed")
        let pkg = dir.appendingPathComponent("pkg")
        func put(_ path: String, _ s: String) throws {
            let f = pkg.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(s.utf8).write(to: f)
        }
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        try put("[Content_Types].xml", #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#)
        try put("xl/workbook.xml", #"<?xml version="1.0" encoding="utf-8"?><x:workbook xmlns:x="\#(main)"><x:sheets><x:sheet name="字段清单" sheetId="1" r:id="R1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></x:sheets></x:workbook>"#)
        try put("xl/_rels/workbook.xml.rels", "\u{FEFF}" + #"<?xml version="1.0" encoding="utf-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Type="worksheet" Target="/xl/worksheets/sheet1.xml" Id="R1"/><Relationship Type="sharedStrings" Target="/xl/sharedStrings.xml" Id="R2"/></Relationships>"#)
        try put("xl/sharedStrings.xml", #"<?xml version="1.0"?><x:sst xmlns:x="\#(main)"><x:si><x:t>表名</x:t></x:si></x:sst>"#)
        try put("xl/worksheets/sheet1.xml", #"<?xml version="1.0"?><x:worksheet xmlns:x="\#(main)"><x:sheetData><x:row r="1"><x:c r="A1" t="s"><x:v>0</x:v></x:c><x:c r="B1" t="inlineStr"><x:is><x:t>字段</x:t></x:is></x:c></x:row><x:row r="2"><x:c r="A2" t="inlineStr"><x:is><x:t>ods_order</x:t></x:is></x:c><x:c r="B2"><x:v>42</x:v></x:c></x:row></x:sheetData></x:worksheet>"#)
        let url = dir.appendingPathComponent("prefixed.xlsx")
        try Zip.pack(directory: pkg, to: url)
        let wb = try SpreadsheetReader.readXLSX(url: url)
        #expect(wb.sheets.first?.name == "字段清单")
        #expect(wb.sheets.first?.rows.count == 2)
        #expect(wb.sheets.first?.cell(0, 0) == .text("表名"))
        #expect(wb.sheets.first?.cell(0, 1) == .text("字段"))
        #expect(wb.sheets.first?.cell(1, 1) == .number(42))
    }
}
