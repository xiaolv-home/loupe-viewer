import AppKit
import LoupeCore

/// The AI edits Markdown where the user is looking (writer, source or the page), and nothing is
/// saved until the user saves.
extension MarkdownRenderer: AIDocumentTools {
    var aiContext: String {
        "当前打开的是 Markdown 文档（\(currentSource.count) 字），可以用 edit_document / rewrite_document 直接修改它（改动出现在编辑器里，用户按 ⌘S 才保存，⌘Z 可撤销）。"
    }

    var aiTools: [AIToolSpec] {
        [
            AIToolSpec("edit_document", "修改当前打开的 Markdown 文档：把 find 换成 replace。find 必须和原文一字不差且只出现一次（不唯一时多带几个字），all=true 时替换所有出现处。改动会显示在编辑器里，可撤销。",
                       Schema.object(["find": Schema.string("要替换的原文"), "replace": Schema.string("替换成的内容"),
                                      "all": Schema.boolean("替换所有出现处")], required: ["find", "replace"])),
            AIToolSpec("rewrite_document", "用新内容整篇替换当前 Markdown 文档（大幅改写、重排结构时用）。可撤销，用户保存前不会写入文件。",
                       Schema.object(["content": Schema.string("新的完整内容")], required: ["content"]))
        ]
    }

    func aiRun(_ name: String, _ args: AIJSON) async -> AIToolOutput {
        let text = await documentText()
        switch name {
        case "edit_document":
            guard let find = args["find"]?.string, !find.isEmpty else { return .error("缺少 find") }
            let replace = args["replace"]?.string ?? ""
            let count = text.components(separatedBy: find).count - 1
            if count == 0 { return .error("文档里找不到这段原文（注意空格、标点要完全一致）。先用 read_file 看一下当前内容。") }
            if count > 1 && args["all"]?.bool != true {
                return .error("这段原文出现了 \(count) 次，请多带一些上下文让它唯一，或设 all=true")
            }
            replaceDocument(text.replacingOccurrences(of: find, with: replace))
            return AIToolOutput("已修改 \(count) 处（未保存，用户可 ⌘Z 撤销）")
        case "rewrite_document":
            guard let content = args["content"]?.string else { return .error("缺少 content") }
            replaceDocument(content)
            return AIToolOutput("已整篇替换为 \(content.count) 字的新内容（未保存，用户可 ⌘Z 撤销）")
        default:
            return .error("未知工具 \(name)")
        }
    }
}
