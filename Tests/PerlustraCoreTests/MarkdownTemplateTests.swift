import Foundation
import Testing

@testable import PerlustraCore

@Suite("Markdown 模版")
struct MarkdownTemplateTests {
    private var builtIn: [MarkdownTemplate] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PerlustraApp/Resources/templates")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap { file in
            (try? String(contentsOf: file, encoding: .utf8)).map { MarkdownTemplate(fileName: file.lastPathComponent, text: $0) }
        }
    }

    @Test("读取头部信息，正文里不留头部")
    func header() {
        let t = MarkdownTemplate(fileName: "01-a.md", text: "---\ntitle: 指标卡\ngroup: 需求\nsummary: 说明: 带冒号\n---\n\n# 正文\n")
        #expect(t.title == "指标卡")
        #expect(t.group == "需求")
        #expect(t.summary == "说明: 带冒号")
        #expect(t.body == "# 正文\n")
    }

    @Test("没有头部的文件用文件名，归到我的模版")
    func noHeader() {
        let t = MarkdownTemplate(fileName: "我的周报.md", text: "# 周报\r\n内容\r\n")
        #expect(t.title == "我的周报")
        #expect(t.group == MarkdownTemplate.ownGroup)
        #expect(t.body == "# 周报\n内容\n")
    }

    @Test("新文档填好今天的日期")
    func today() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9))!
        let t = MarkdownTemplate(fileName: "a.md", text: "日期：〔今天〕 负责人：〔姓名〕\n")
        #expect(t.document(on: date, calendar: calendar) == "日期：2026-03-09 负责人：〔姓名〕\n")
    }

    @Test("找出待填项，年份编号不算")
    func blanks() {
        #expect(MarkdownTemplate.blanks(in: "〔表名〕和〔字段〕，文号〔2024〕3 号，【注意】") == ["〔表名〕", "〔字段〕"])
        #expect(MarkdownTemplate.blanks(in: "没有待填项").isEmpty)
    }

    @Test("搜索要包含每个词")
    func search() {
        let list = [
            MarkdownTemplate(fileName: "a.md", text: "---\ntitle: 故障复盘\ngroup: 运维\nsummary: 根因\n---\n时间线\n"),
            MarkdownTemplate(fileName: "b.md", text: "---\ntitle: 周报\ngroup: 汇报\nsummary: 进展\n---\n计划\n"),
        ]
        #expect(MarkdownTemplate.matching(list, query: "").count == 2)
        #expect(MarkdownTemplate.matching(list, query: "运维 时间线").map(\.title) == ["故障复盘"])
        #expect(MarkdownTemplate.matching(list, query: "不存在").isEmpty)
    }

    @Test("内置模版都能用")
    func shipped() {
        let all = builtIn
        #expect(all.count == 15)
        #expect(Set(all.map(\.title)).count == all.count)
        for t in all {
            #expect(t.group != MarkdownTemplate.ownGroup, "\(t.id) 缺头部")
            #expect(!t.summary.isEmpty, "\(t.id) 缺说明")
            #expect(t.body.hasPrefix("# "), "\(t.id) 要以一级标题开头")
            #expect(MarkdownTemplate.blanks(in: t.document()).count >= 3, "\(t.id) 待填项太少")
            #expect(!t.document().contains("〔今天〕"))
        }
    }
}
