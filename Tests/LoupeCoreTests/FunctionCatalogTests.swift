import Testing
@testable import LoupeCore

@Suite("函数说明")
struct FunctionCatalogTests {
    @Test("每个支持的函数都有说明，说明里没有引擎不支持的函数")
    func coverage() {
        let documented = Set(FunctionCatalog.all.map(\.name))
        #expect(documented == Set(FormulaEngine.supportedFunctions))
        #expect(FunctionCatalog.all.count == documented.count)               // no duplicates
        for d in FunctionCatalog.all { #expect(FunctionCatalog.categories.contains(d.category), "\(d.name)") }
    }

    @Test("每个例子都是能解析的公式")
    func examplesParse() throws {
        for d in FunctionCatalog.all {
            #expect(throws: Never.self, "\(d.name): \(d.example)") { _ = try FormulaParser.parse(d.example) }
            #expect(d.example.uppercased().contains(d.name + "("), "\(d.name)")
            // Every function an example uses must be one Loupe can compute.
            let called = d.example.matches(of: try! Regex("([A-Z][A-Z0-9]*)\\(")).compactMap { $0.output[1].substring.map(String.init) }
            for c in called { #expect(FormulaEngine.supportedFunctions.contains(c), "\(d.name) 的例子用了不支持的 \(c)") }
        }
    }

    @Test("输入提示：找到光标所在的函数和第几个参数")
    func hint() {
        #expect(FunctionCatalog.context(beforeCursor: "=COUNTIF(B:B, ")?.doc.name == "COUNTIF")
        #expect(FunctionCatalog.context(beforeCursor: "=COUNTIF(B:B, ")?.argument == 1)
        #expect(FunctionCatalog.context(beforeCursor: "=IFERROR(VLOOKUP(A2, ")?.doc.name == "VLOOKUP")
        #expect(FunctionCatalog.context(beforeCursor: "=IFERROR(VLOOKUP(A2, T!A:C, 3, FALSE), ")?.doc.name == "IFERROR")
        #expect(FunctionCatalog.context(beforeCursor: "=IF(A1=\"a,b\", ")?.argument == 1)       // comma inside a string
        #expect(FunctionCatalog.context(beforeCursor: "=SUM(A1:A3)") == nil)
        #expect(FunctionCatalog.search("查找").contains { $0.name == "VLOOKUP" })
        #expect(FunctionCatalog.search("vlo").first?.name == "VLOOKUP")
    }
}
