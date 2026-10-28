import Testing
import Foundation
@testable import LoupeCore

@Suite("表格文档（编辑状态，与界面无关）")
struct DocumentTests {
    func doc() throws -> SpreadsheetDocument {
        SpreadsheetDocument(workbook: try SpreadsheetReader.readXLSX(url: StructureTests.fixture))
    }

    @Test("编辑 → 撤销还原；公式联动重算")
    func editUndo() throws {
        var d = try doc()
        #expect(!d.hasChanges)
        let undo = d.apply([CellChange(sheet: 0, row: 3, col: 1, value: .number(20), formula: nil)])
        #expect(d.hasChanges)
        #expect(d.workbook.sheets[0].cell(3, 3) == .number(40))          // =B4*C4
        #expect(d.workbook.sheets[1].cell(0, 0) == .number(104.5))       // 汇总!A1 = 数据!D7
        d.apply(undo)
        #expect(d.workbook.sheets[0].cell(3, 1) == .number(10))
        #expect(d.workbook.sheets[0].cell(3, 3) == .number(20))
    }

    @Test("输入解析：公式、日期格式单元格、布尔、前导零文本")
    func parse() throws {
        let d = try doc()
        #expect(d.parseInput("=A1", sheet: 0, row: 0, col: 0).1 == "=A1")
        #expect(d.parseInput("true", sheet: 0, row: 0, col: 0).0 == .bool(true))
        #expect(d.parseInput("007", sheet: 0, row: 0, col: 0).0 == .text("007"))
        #expect(d.parseInput("12.5", sheet: 0, row: 0, col: 0).0 == .number(12.5))
    }

    @Test("插入行：待保存的编辑跟着移动，公式全部标记重写，查询状态同步")
    func performMovesEdits() throws {
        var d = try doc()
        d.apply([CellChange(sheet: 0, row: 5, col: 0, value: .text("葡萄2"), formula: nil)])
        d.perform([.insertRows(at: 3, count: 1)], sheet: 0)
        #expect(d.edited[0]?.contains(Sheet.key(6, 0)) == true)
        #expect(d.edited[0]?.contains(Sheet.key(5, 0)) == false)
        #expect(d.edited[1]?.contains(Sheet.key(0, 0)) == true)            // cross-sheet formula rewritten
        #expect(d.structure[0] == [.insertRows(at: 3, count: 1)])
        var q = SheetQuery()
        q.headerRowIndex = 1
        q.filters[2] = .greater(1)
        q.apply(.insertColumns(at: 0, count: 2))
        #expect(q.filters[4] != nil && q.filters[2] == nil)
        q.apply(.deleteRows(at: 0, count: 1))
        #expect(q.headerRowIndex == 0)
    }

    @Test("CSV 调列宽不算修改；xlsx 算")
    func layoutDirty() throws {
        var d = try doc()
        d.setColumnWidth(20, sheet: 0, column: 0)
        #expect(d.hasChanges)
        var c = SpreadsheetDocument(workbook: try SpreadsheetReader.readDelimited(url: StructureTests.fixture.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("data/sales-utf8.csv"), delimiter: 44))
        c.setColumnWidth(20, sheet: 0, column: 0)
        #expect(!c.hasChanges)
    }

    @Test("合并：只留左上角、吸收重叠的合并；取消合并；保存后另一个读取器也认")
    func mergeUnmerge() throws {
        let src = StructureTests.fixture
        let dir = TestTemp.dir("merge")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("m.xlsx")
        try FileManager.default.copyItem(at: src, to: file)
        var d = SpreadsheetDocument(workbook: try SpreadsheetReader.readXLSX(url: file))
        let m = MergeRange(r0: 2, c0: 0, r1: 3, c1: 1)           // A3:B4 (苹果 3 / 香蕉 10)
        #expect(d.cellsClearedByMerging(m, sheet: 0) == 3)
        d.merge(m, sheet: 0)
        #expect(d.workbook.sheets[0].cell(2, 0) == .text("苹果"))
        #expect(d.workbook.sheets[0].cell(3, 0).isEmpty)
        #expect(d.workbook.sheets[0].merges.contains(m))
        #expect(d.unmerge(MergeRange(r0: 0, c0: 0, r1: 0, c1: 0), sheet: 0) == 1)   // A1 → splits A1:D1
        #expect(d.hasChanges)
        _ = try d.write(to: file, base: file, sheet: 0)
        let back = try SpreadsheetReader.readXLSX(url: file).sheets[0]
        #expect(Set(back.merges) == Set([MergeRange(r0: 7, c0: 0, r1: 8, c1: 1), m]))
        #expect(back.cell(3, 0).isEmpty)
        try StructureTests().openpyxlCheck(file)
    }
}
