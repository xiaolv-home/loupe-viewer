import Testing
import Foundation
@testable import LoupeCore

@Suite("插入删除行列")
struct StructureTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/office/structure.xlsx")

    func copyFixture() throws -> URL {
        let dir = TestTemp.dir("struct")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("structure.xlsx")
        try FileManager.default.copyItem(at: Self.fixture, to: f)
        return f
    }

    @Test("引用平移：相对/绝对、区域、整行整列、跨表、字符串不动")
    func shifting() {
        #expect(FormulaRefs.shifted("=B3*C3", rows: 2, cols: 0) == "=B5*C5")
        #expect(FormulaRefs.shifted("=$B$3+B$3+$B3", rows: 1, cols: 1) == "=$B$3+C$3+$B4")
        #expect(FormulaRefs.shifted("=SUM(A:A)+\"A1\"", rows: 5, cols: 1) == "=SUM(B:B)+\"A1\"")
        #expect(FormulaRefs.shifted("=LOG10(A1)", rows: 1, cols: 0) == "=LOG10(A2)")
        #expect(FormulaRefs.shifted("=A1", rows: -1, cols: 0) == "=#REF!")
        #expect(FormulaRefs.shifted("='My Sheet'!A1+数据!B2", rows: 1, cols: 0) == "='My Sheet'!A2+数据!B3")
        #expect(FormulaRefs.shifted("=IF(TRUE,1.5,#N/A)", rows: 3, cols: 3) == "=IF(TRUE,1.5,#N/A)")
    }

    @Test("插入/删除时调整引用：区域扩张收缩、删到的变 #REF!、只改指向本表的")
    func adjusting() {
        let ins = StructOp.insertRows(at: 4, count: 2)        // before row 5
        #expect(FormulaRefs.adjusted("=SUM(D3:D6)", for: ins, targetSheet: "S", formulaSheet: "S") == "=SUM(D3:D8)")
        #expect(FormulaRefs.adjusted("=D4+D5+$D$5", for: ins, targetSheet: "S", formulaSheet: "S") == "=D4+D7+$D$7")
        #expect(FormulaRefs.adjusted("=D5", for: ins, targetSheet: "S", formulaSheet: "T") == "=D5")
        #expect(FormulaRefs.adjusted("=S!D5", for: ins, targetSheet: "S", formulaSheet: "T") == "=S!D7")
        #expect(FormulaRefs.adjusted("=SUM(A:A)", for: ins, targetSheet: "S", formulaSheet: "S") == "=SUM(A:A)")
        let del = StructOp.deleteRows(at: 3, count: 2)        // rows 4–5
        #expect(FormulaRefs.adjusted("=SUM(D3:D6)", for: del, targetSheet: "S", formulaSheet: "S") == "=SUM(D3:D4)")
        #expect(FormulaRefs.adjusted("=D4*2", for: del, targetSheet: "S", formulaSheet: "S") == "=#REF!*2")
        #expect(FormulaRefs.adjusted("=SUM(D4:D5)", for: del, targetSheet: "S", formulaSheet: "S") == "=SUM(#REF!)")
        let delC = StructOp.deleteColumns(at: 1, count: 1)    // column B
        #expect(FormulaRefs.adjusted("=B3*C3", for: delC, targetSheet: "S", formulaSheet: "S") == "=#REF!*B3")
        #expect(FormulaRefs.adjusted("=SUM(A1:D1)", for: delC, targetSheet: "S", formulaSheet: "S") == "=SUM(A1:C1)")
    }

    @Test("读取共享公式：从属单元格按位置展开")
    func sharedFormulas() throws {
        let wb = try SpreadsheetReader.readXLSX(url: Self.fixture)
        let s = wb.sheets[0]
        #expect(s.formulas[Sheet.key(2, 3)] == "=B3*C3")
        #expect(s.formulas[Sheet.key(4, 3)] == "=B5*C5")
        #expect(s.cell(4, 3) == .number(24))
        #expect(s.cell(6, 3) == CellValue.number(84.5))
        #expect(s.customHeightRows.contains(0))
        #expect(s.defaultRowHeight == 15)
    }

    @Test("插入两行后保存：公式、合并、条件格式、名称、跨表引用都跟着移动")
    func insertRowsRoundTrip() throws {
        let file = try copyFixture()
        var wb = try SpreadsheetReader.readXLSX(url: file)
        let op = StructOp.insertRows(at: 4, count: 2)
        wb.apply(op, sheet: 0)
        var s = wb.sheets[0]
        #expect(s.formulas[Sheet.key(8, 3)] == "=SUM(D3:D8)")
        #expect(s.formulas[Sheet.key(6, 3)] == "=B7*C7")
        #expect(s.merges.contains(MergeRange(r0: 9, c0: 0, r1: 10, c1: 1)))
        #expect(wb.sheets[1].formulas[Sheet.key(0, 0)] == "=数据!D9")
        // Fill the new rows like a user would.
        s.rows[4] = [.text("梨"), .number(1), .number(3)]
        s.formulas[Sheet.key(4, 3)] = "=B5*C5"
        s.rows[4].append(.number(3))
        wb.sheets[0] = s
        var edited: [Int: Set<Int>] = [0: [Sheet.key(4, 0), Sheet.key(4, 1), Sheet.key(4, 2), Sheet.key(4, 3)]]
        for si in wb.sheets.indices { edited[si, default: []].formUnion(wb.sheets[si].formulas.keys) }
        try XLSXPatcher.save(base: file, to: file, workbook: wb, edited: edited, structure: [0: [op]])

        let back = try SpreadsheetReader.readXLSX(url: file)
        let b = back.sheets[0]
        #expect(b.cell(4, 0) == .text("梨"))
        #expect(b.cell(6, 0) == .text("橙子"))
        #expect(b.formulas[Sheet.key(8, 3)] == "=SUM(D3:D8)")
        #expect(b.formulas[Sheet.key(7, 3)] == "=B8*C8")
        #expect(b.merges.contains(MergeRange(r0: 9, c0: 0, r1: 10, c1: 1)))
        #expect(b.merges.contains(MergeRange(r0: 0, c0: 0, r1: 0, c1: 3)))
        #expect(b.customHeightRows.contains(0))
        #expect(back.sheets[1].formulas[Sheet.key(0, 0)] == "=数据!D9")
        #expect(back.style(0, 1, 0)?.fill != nil)                    // header row keeps its fill
        let xml = try sheetXML(file)
        #expect(xml.contains("sqref=\"B3:B8\""))                    // conditional format grew
        #expect(xml.contains("sqref=\"C3:C8\""))                    // validation grew
        #expect(!xml.contains("t=\"shared\""))
        let w = try partXML(file, "xl/workbook.xml")
        #expect(w.contains("数据!$D$9"))
        try openpyxlCheck(file)
    }

    @Test("删除列与行后保存：被删引用变 #REF!，列宽跟着移动")
    func deleteRoundTrip() throws {
        let file = try copyFixture()
        var wb = try SpreadsheetReader.readXLSX(url: file)
        let ops: [StructOp] = [.deleteColumns(at: 1, count: 1), .deleteRows(at: 3, count: 1)]
        for op in ops { wb.apply(op, sheet: 0) }
        let s = wb.sheets[0]
        #expect(s.cell(3, 0) == .text("橙子"))
        #expect(s.cell(3, 1) == .number(6))                        // 单价 moved into B
        #expect(s.formulas[Sheet.key(5, 2)] == "=SUM(C3:C5)")
        #expect(s.formulas[Sheet.key(2, 2)] == "=#REF!*B3")
        #expect(s.columnWidths[2] == 12)
        var edited: [Int: Set<Int>] = [:]
        for si in wb.sheets.indices { edited[si, default: []].formUnion(wb.sheets[si].formulas.keys) }
        try XLSXPatcher.save(base: file, to: file, workbook: wb, edited: edited, structure: [0: ops])
        let back = try SpreadsheetReader.readXLSX(url: file)
        let b = back.sheets[0]
        #expect(b.cell(3, 0) == .text("橙子"))
        #expect(b.formulas[Sheet.key(5, 2)] == "=SUM(C3:C5)")
        #expect(b.columnWidths[0] == 16)
        #expect(b.columnWidths[2] == 12)
        #expect(b.merges.contains(MergeRange(r0: 0, c0: 0, r1: 0, c1: 2)))
        #expect(b.merges.contains(MergeRange(r0: 6, c0: 0, r1: 7, c1: 0)))
        let xml = try sheetXML(file)
        #expect(!xml.contains("conditionalFormatting"))            // its range (column B) is gone
        #expect(xml.contains("sqref=\"B3:B5\""))                   // validation followed 单价
        try openpyxlCheck(file)
    }

    @Test("改列宽、行高后保存")
    func layoutSave() throws {
        let file = try copyFixture()
        var wb = try SpreadsheetReader.readXLSX(url: file)
        wb.sheets[0].columnWidths[2] = 25
        wb.sheets[0].rowHeights[4] = 40
        wb.sheets[0].customHeightRows.insert(4)
        var lay = SheetLayoutEdits()
        lay.cols = [2]
        lay.rows = [4, 0]
        wb.sheets[0].rowHeights[0] = 33
        try XLSXPatcher.save(base: file, to: file, workbook: wb, edited: [:], layout: [0: lay])
        let b = try SpreadsheetReader.readXLSX(url: file).sheets[0]
        #expect(b.columnWidths[2] == 25)
        #expect(b.columnWidths[0] == 16)
        #expect(b.rowHeights[4] == 40)
        #expect(b.rowHeights[0] == 33)
        #expect(b.cell(4, 0) == .text("橙子"))
        try openpyxlCheck(file)
    }

    // MARK: helpers

    func partXML(_ file: URL, _ part: String) throws -> String {
        let parts = try ArchiveReader.extractAll(url: file) { $0 == part }
        return String(decoding: try #require(parts[part]), as: UTF8.self)
    }

    func sheetXML(_ file: URL) throws -> String { try partXML(file, "xl/worksheets/sheet1.xml") }

    /// A second, independent reader must accept the file too (when openpyxl is installed).
    func openpyxlCheck(_ file: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", "import sys, openpyxl; wb = openpyxl.load_workbook(sys.argv[1]); print(wb.sheetnames)", file.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if msg.contains("No module named") { return }
        #expect(p.terminationStatus == 0, "openpyxl: \(msg)")
    }
}
