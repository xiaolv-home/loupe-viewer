import Testing
import Foundation
@testable import LoupeCore

/// 条件格式里的数据条和色阶。原来一律不画，进度表里的进度条全没了。
@Suite("条件格式：数据条和色阶")
struct ConditionalFormatTests {
    static func sheet(_ body: String, extra: String = "") -> Sheet {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main" xmlns:xm="http://schemas.microsoft.com/office/excel/2006/main">
        <sheetData>\(body)</sheetData>\(extra)</worksheet>
        """
        let p = SheetXMLParser(shared: [], dateStyles: [], color: { a in a["rgb"].flatMap(RGBA.init(hex:)) })
        p.run(Data(xml.utf8))
        return p.makeSheet(name: "S")
    }

    /// 和用户那份工作计划一样：Excel 2007 的规则 + 2010 扩展（渐变、边框、长度 0~100、自动最小/最大）。
    static let progress = sheet("""
        <row r="2"><c r="E2"><v>1</v></c></row>
        <row r="6"><c r="E6"><v>0.85</v></c></row>
        <row r="10"><c r="E10"><v>0.2</v></c></row>
        <row r="14"><c r="E14"><v>0</v></c></row>
        <row r="18"><c r="E18"><v>0</v></c></row>
        """, extra: """
        <mergeCells count="1"><mergeCell ref="E2:H5"/></mergeCells>
        <conditionalFormatting sqref="E2:H21"><cfRule type="dataBar" priority="1"><dataBar><cfvo type="min"/><cfvo type="max"/><color rgb="FF638EC6"/></dataBar><extLst><ext uri="{B025F937-C7B1-47D3-B67F-A62EFF666E3E}"><x14:id>{ebe2}</x14:id></ext></extLst></cfRule></conditionalFormatting>
        <extLst><ext uri="{78C0D931-6437-407d-A8EE-F0AAD7539E65}"><x14:conditionalFormattings><x14:conditionalFormatting><x14:cfRule type="dataBar" id="{ebe2}"><x14:dataBar minLength="0" maxLength="100" border="1" negativeBarBorderColorSameAsPositive="0"><x14:cfvo type="autoMin"/><x14:cfvo type="autoMax"/><x14:borderColor rgb="FF638EC6"/><x14:negativeFillColor rgb="FFFF0000"/><x14:axisColor rgb="FF000000"/></x14:dataBar></x14:cfRule><xm:sqref>E2:H21</xm:sqref></x14:conditionalFormatting></x14:conditionalFormattings></ext></extLst>
        """)

    @Test("读出数据条：2010 扩展覆盖 2007 的长度和阈值，颜色沿用基础规则")
    func readsDataBar() throws {
        let s = Self.progress
        #expect(s.conditionalFormats.count == 1)
        #expect(s.otherConditionalFormats == 0)
        let rule = try #require(s.conditionalFormats.first)
        #expect(rule.ranges == [MergeRange(r0: 1, c0: 4, r1: 20, c1: 7)])
        guard case .dataBar(let bar) = rule.kind else { Issue.record("应是数据条"); return }
        #expect(bar.color == RGBA(hex: "638EC6"))
        #expect(bar.border == RGBA(hex: "638EC6"))
        #expect(bar.negativeColor == RGBA(hex: "FF0000"))
        #expect(bar.minLength == 0 && bar.maxLength == 100)
        #expect(bar.low.kind == .autoMin && bar.high.kind == .autoMax)
        #expect(bar.gradient)
    }

    @Test("条长按数值比例：100% 满格、85%、20%、0 没有条")
    func barLengths() throws {
        let cells = ConditionalFormatting.evaluate(Self.progress)
        func to(_ r: Int) -> Double? { cells[Sheet.key(r, 4)]?.bar?.to }
        #expect(to(1) == 1)
        #expect(abs((to(5) ?? 0) - 0.85) < 1e-9)
        #expect(abs((to(9) ?? 0) - 0.2) < 1e-9)
        #expect(to(13) == 0)
        #expect(cells[Sheet.key(1, 4)]?.bar?.from == 0)
        #expect(cells[Sheet.key(1, 4)]?.showValue == true)
    }

    @Test("只有 2007 规则时：最小/最大取实际值，最短 10%、最长 90%")
    func legacyBar() throws {
        let s = Self.sheet("""
            <row r="1"><c r="A1"><v>10</v></c></row><row r="2"><c r="A2"><v>20</v></c></row><row r="3"><c r="A3"><v>30</v></c></row>
            """, extra: """
            <conditionalFormatting sqref="A1:A3"><cfRule type="dataBar" priority="1"><dataBar><cfvo type="min"/><cfvo type="max"/><color rgb="FF63BE7B"/></dataBar></cfRule></conditionalFormatting>
            """)
        let cells = ConditionalFormatting.evaluate(s)
        #expect(abs((cells[Sheet.key(0, 0)]?.bar?.to ?? 0) - 0.1) < 1e-9)
        #expect(abs((cells[Sheet.key(1, 0)]?.bar?.to ?? 0) - 0.5) < 1e-9)
        #expect(abs((cells[Sheet.key(2, 0)]?.bar?.to ?? 0) - 0.9) < 1e-9)
    }

    @Test("有正有负：按比例放坐标轴，负数往左长")
    func negativeAxis() throws {
        let s = Self.sheet("""
            <row r="1"><c r="A1"><v>-50</v></c></row><row r="2"><c r="A2"><v>150</v></c></row><row r="3"><c r="A3"><v>75</v></c></row>
            """, extra: """
            <conditionalFormatting sqref="A1:A3"><cfRule type="dataBar" priority="1"><dataBar><cfvo type="min"/><cfvo type="max"/><color rgb="FF638EC6"/></dataBar></cfRule></conditionalFormatting>
            """)
        let cells = ConditionalFormatting.evaluate(s)
        let neg = try #require(cells[Sheet.key(0, 0)]?.bar), pos = try #require(cells[Sheet.key(2, 0)]?.bar)
        #expect(neg.axis == 0.25 && neg.negative && neg.from == 0 && neg.to == 0.25)
        #expect(!pos.negative && pos.from == 0.25 && abs(pos.to - 0.625) < 1e-9)
    }

    @Test("三色色阶：两端和中位数对上颜色，中间插值")
    func colorScale() throws {
        let s = Self.sheet("""
            <row r="1"><c r="A1"><v>0</v></c></row><row r="2"><c r="A2"><v>50</v></c></row><row r="3"><c r="A3"><v>100</v></c></row><row r="4"><c r="A4"><v>25</v></c></row>
            """, extra: """
            <conditionalFormatting sqref="A1:A4"><cfRule type="colorScale" priority="1"><colorScale><cfvo type="min"/><cfvo type="percentile" val="50"/><cfvo type="max"/><color rgb="FFF8696B"/><color rgb="FFFFEB84"/><color rgb="FF63BE7B"/></colorScale></cfRule></conditionalFormatting>
            """)
        let cells = ConditionalFormatting.evaluate(s)
        #expect(cells[Sheet.key(0, 0)]?.fill == RGBA(hex: "F8696B"))
        #expect(cells[Sheet.key(2, 0)]?.fill == RGBA(hex: "63BE7B"))
        // 中位数是 (25+50)/2 = 37.5；25 在 0 和 37.5 之间的 2/3 处。
        let mid = try #require(cells[Sheet.key(3, 0)]?.fill)
        #expect(mid.r == UInt8((248 + (255 - 248) * 2.0 / 3).rounded()))
        #expect(cells[Sheet.key(3, 0)]?.bar == nil)
    }

    @Test("按值变色等规则不画，但会记下来提示；格子里富文本的颜色不会被当成条件格式")
    func otherRules() throws {
        let s = Self.sheet("""
            <row r="1"><c r="A1" t="inlineStr"><is><r><rPr><color rgb="FFFF0000"/></rPr><t>红</t></r></is></c><c r="B1"><v>3</v></c></row>
            """, extra: """
            <conditionalFormatting sqref="B1"><cfRule type="cellIs" dxfId="0" priority="1" operator="greaterThan"><formula>2</formula></cfRule></conditionalFormatting>
            """)
        #expect(s.conditionalFormats.isEmpty)
        #expect(s.otherConditionalFormats == 1)
        #expect(s.richText[Sheet.key(0, 0)]?.first?.color == RGBA(hex: "FF0000"))
    }

    @Test("插入行后数据条的范围跟着走")
    func movesWithRows() throws {
        var wb = Workbook(sheets: [Self.progress], source: "")
        wb.apply(.insertRows(at: 0, count: 2), sheet: 0)
        #expect(wb.sheets[0].conditionalFormats.first?.ranges == [MergeRange(r0: 3, c0: 4, r1: 22, c1: 7)])
        #expect(ConditionalFormatting.evaluate(wb.sheets[0])[Sheet.key(3, 4)]?.bar?.to == 1)
    }
}
