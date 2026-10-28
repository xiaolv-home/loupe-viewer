import Testing
@testable import LoupeCore

@Suite("跨文件引用（像 WPS 那样）")
struct ExternalRefTests {
    /// 门店表.xlsx：编号 → 门店名、城市（第一张表叫「门店」，第二张「备用」）。
    static let stores: Workbook = {
        var s = Sheet(name: "门店", rows: [
            [.text("编号"), .text("门店"), .text("城市")],
            [.text("S01"), .text("南京东路店"), .text("上海")],
            [.text("S02"), .text("国贸店"), .text("北京")],
            [.text("S03"), .text("西湖店"), .text("杭州")]
        ])
        s.columnCount = 3
        return Workbook(sheets: [s, Sheet(name: "备用", rows: [[.number(42)]])], source: "")
    }()

    static let sales: Workbook = {
        let s = Sheet(name: "销售", rows: [
            [.text("编号"), .text("金额")],
            [.text("S02"), .number(100)],
            [.text("S03"), .number(250)],
            [.text("S09"), .number(7)]
        ])
        return Workbook(sheets: [s], source: "")
    }()

    func eval(_ f: String, rowOffset: Int = 0) -> FValue {
        FormulaEngine.evaluate(f, in: FormulaContext(workbook: Self.sales, sheet: 0, rowOffset: rowOffset,
                                                     externalWorkbooks: ["门店表.xlsx": Self.stores]))
    }

    @Test("VLOOKUP 到另一个文件的指定工作表、默认第一张表、带引号的写法")
    func lookups() {
        #expect(eval("=VLOOKUP(A2,[门店表.xlsx]门店!A:C,2,FALSE)") == .text("国贸店"))
        #expect(eval("=VLOOKUP(\"S03\",'[门店表.xlsx]门店'!$A$1:$C$4,3,0)") == .text("杭州"))
        #expect(eval("=[门店表.xlsx]备用!A1*2") == .number(84))
        #expect(eval("=IFERROR(VLOOKUP(A4,[门店表.xlsx]门店!A:C,2,0),\"无\")") == .text("无"))
        #expect(eval("=COUNTIF([门店表.xlsx]门店!C:C,\"北京\")") == .number(1))
    }

    @Test("填充成一列时，相对引用逐行移动，外部区域用 $ 固定")
    func fillDown() {
        let f = "=VLOOKUP(A2,[门店表.xlsx]门店!$A:$C,2,0)"
        #expect(eval(f, rowOffset: 0) == .text("国贸店"))
        #expect(eval(f, rowOffset: 1) == .text("西湖店"))
    }

    @Test("找不到文件或工作表时给出能看懂的提示")
    func missing() {
        if case .error(let e) = eval("=[其他.xlsx]Sheet1!A1") { #expect(e.contains("找不到文件「其他.xlsx」")) } else { Issue.record("expected error") }
        if case .error(let e) = eval("=[门店表.xlsx]不存在!A1") { #expect(e.contains("没有工作表")) } else { Issue.record("expected error") }
    }

    @Test("列出公式里引用的外部文件；插删行列不改外部引用")
    func namesAndShifting() {
        #expect(FormulaEngine.externalBookNames(in: "=VLOOKUP(A2,[门店表.xlsx]门店!A:C,2,0)+'[另一个 表.xlsx]S'!B1&\"[不是]\"") == ["门店表.xlsx", "另一个 表.xlsx"])
        let op = StructOp.insertRows(at: 0, count: 1)
        #expect(FormulaRefs.adjusted("=[门店表.xlsx]门店!A2+门店!A2", for: op, targetSheet: "门店", formulaSheet: "销售")
                == "=[门店表.xlsx]门店!A2+门店!A3")
    }
}
