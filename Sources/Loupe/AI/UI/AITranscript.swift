import SwiftUI
import AppKit
import LoupeCore

/// The conversation: requests, answers, and every action the AI took (with its result).
struct AITranscript: View {
    @ObservedObject var session: AISession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.items) { item in
                        AIItemView(item: item, session: session).id(item.id)
                    }
                    Color.clear.frame(height: 4).id("end")
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
            }
            .onChange(of: session.items) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

private struct AIItemView: View {
    let item: AIItem
    @ObservedObject var session: AISession

    var body: some View {
        switch item.kind {
        case .user(let text, let context):
            VStack(alignment: .trailing, spacing: 3) {
                if let context { Text(context).font(.system(size: 10.5)).foregroundStyle(Theme.ember) }
                Text(text).font(.system(size: 12.5)).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 30)
        case .assistant(let text):
            AIMarkdownText(text: text)
        case .reasoning(let text):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 { AIReasoningView(text: text) }
        case .tool(let name, let summary, let result, let failed):
            AIToolRow(name: name, summary: summary, result: result, failed: failed, running: session.running && result == nil)
        case .file(let url):
            AIFileCard(url: url, window: session.window)
        case .approval(let a, let decided):
            AIApprovalCard(approval: a, decided: decided) { session.decide(a, $0) }
        case .images(let thumbs):
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach(Array(thumbs.enumerated()), id: \.offset) { _, t in AIThumbnail(base64: t, size: 64) }
            }
        case .note(let text, let isError):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle").font(.system(size: 10.5))
                Text(text).font(.system(size: 11.5)).textSelection(.enabled)
            }
            .foregroundStyle(isError ? Color(nsColor: .systemRed) : .secondary)
        }
    }
}

/// A small picture from base64 JPEG.
struct AIThumbnail: View {
    let base64: String
    var size: CGFloat
    var body: some View {
        Group {
            if let d = Data(base64Encoded: base64), let img = NSImage(data: d) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

private struct AIReasoningView: View {
    let text: String
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .semibold))
                    Text("思考过程").font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            if open {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1.5) }
            }
        }
    }
}

private struct AIToolRow: View {
    let name: String
    let summary: String
    let result: String?
    let failed: Bool
    let running: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Group {
                if result == nil && running { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
                else { Image(systemName: failed ? "xmark.circle.fill" : icon).font(.system(size: 10.5)).foregroundStyle(failed ? Color(nsColor: .systemRed) : Theme.ember) }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).font(.system(size: 11.5)).foregroundStyle(.primary.opacity(0.85)).lineLimit(3).textSelection(.enabled)
                if let result, !result.isEmpty {
                    Text(result).font(Theme.mono(10.5)).foregroundStyle(failed ? Color(nsColor: .systemRed) : .secondary)
                        .lineLimit(4).textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var icon: String {
        switch name {
        case "read_file", "read_cells": return "doc.text.magnifyingglass"
        case "view_image": return "eye"
        case "list_folder": return "folder"
        case "search_text": return "magnifyingglass"
        case "write_file", "create_spreadsheet", "export_view": return "doc.badge.plus"
        case "open_file": return "arrow.up.forward.square"
        case "use_skill": return "sparkles"
        case "run_command": return "terminal"
        case "calculate", "add_column": return "function"
        case "summarize": return "tablecells"
        case "sheet_overview": return "tablecells.badge.ellipsis"
        case "filter_view": return "line.3.horizontal.decrease.circle"
        case "select_cells": return "scope"
        case "edit_document", "rewrite_document": return "pencil"
        default: return "gearshape"
        }
    }
}

private struct AIFileCard: View {
    let url: URL
    weak var window: ViewerWindowController?

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            Button("打开") {
                guard let w = window else { NSWorkspace.shared.open(url); return }
                if let d = w.document(for: url) { w.select(d) } else { w.addTab(url) }
            }
            .controlSize(.small)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                .controlSize(.small).help("在 Finder 中显示")
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: Theme.sheet)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.ember.opacity(0.35)))
    }
}

private struct AIApprovalCard: View {
    let approval: AIApproval
    let decided: Bool?
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(approval.title).font(.system(size: 12, weight: .semibold))
            Text(approval.detail).font(Theme.mono(11)).textSelection(.enabled)
                .padding(7).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
            if let decided {
                Text(decided ? "已允许" : "已拒绝").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack {
                    Spacer()
                    Button("拒绝") { decide(false) }
                    Button("允许") { decide(true) }.keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.emberSoft))
    }
}

/// Renders the model's Markdown answer: headings, lists, quotes, tables and code as blocks,
/// emphasis and links inline.
struct AIMarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownParser.blocks(text).enumerated()), id: \.offset) { _, b in view(b) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ b: MarkdownBlock) -> some View {
        switch b {
        case .heading(let level, let t):
            inline(t).font(.system(size: level <= 1 ? 15 : level == 2 ? 13.5 : 12.5, weight: .semibold)).padding(.top, 3)
        case .paragraph(let lines):
            inline(lines.joined(separator: "\n")).font(.system(size: 12.5)).lineSpacing(2.5)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, t in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(i + 1)." : "•").font(.system(size: 12.5)).foregroundStyle(Theme.ember).frame(minWidth: 10, alignment: .trailing)
                        inline(t).font(.system(size: 12.5)).lineSpacing(2.5)
                    }
                }
            }
        case .quote(let lines):
            inline(lines.joined(separator: "\n")).font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.leading, 9)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.ember.opacity(0.6)).frame(width: 2) }
        case .code(let t):
            Text(t).font(Theme.mono(11)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, c in inline(c).font(.system(size: 11.5, weight: .semibold)) } }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow { ForEach(Array(r.enumerated()), id: \.offset) { _, c in inline(c).font(.system(size: 11.5)) } }
                    }
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        case .rule:
            Divider()
        }
    }

    private func inline(_ s: String) -> Text {
        let t = s.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
        let a = (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t)
        return Text(a)
    }
}

/// The empty panel: what the AI can do with the file that is open, in one click.
struct AIWelcome: View {
    @ObservedObject var session: AISession
    @ObservedObject var tabs: TabList
    var showHistory: () -> Void
    @ObservedObject var skills = AISkills.shared
    @ObservedObject var store = AIConversations.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("让 AI 真正动手").font(.system(size: 15, weight: .semibold))
                    Text("它会读文件、用公式引擎精确计算、汇总筛选、直接改 Markdown，并把结果做成 Word / PDF / Excel 文件放在原文件旁边。原文件不会被改。")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("试试").font(Theme.label).foregroundStyle(.secondary)
                    ForEach(suggestions, id: \.self) { s in
                        Button { session.input = s; session.send() } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.turn.down.right").font(.system(size: 9.5)).foregroundStyle(Theme.ember).padding(.top, 2)
                                Text(s).font(.system(size: 12)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.045)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !store.list.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("最近的对话").font(Theme.label).foregroundStyle(.secondary)
                            Spacer()
                            Button("全部（\(store.list.count)）…", action: showHistory).buttonStyle(.link).font(.system(size: 11))
                        }
                        ForEach(store.list.prefix(3)) { s in
                            Button { session.open(s.id) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "bubble.left").font(.system(size: 10)).foregroundStyle(.secondary)
                                    Text(s.title).font(.system(size: 12)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 3).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !skills.enabled.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("技能（\(skills.enabled.count)）").font(Theme.label).foregroundStyle(.secondary)
                            Spacer()
                            Button("技能库…") { AISkillsWindow.show() }.buttonStyle(.link).font(.system(size: 11))
                        }
                        AIFlow(spacing: 6) {
                            ForEach(skills.enabled.prefix(16)) { s in
                                Button { session.pinnedSkill = s } label: {
                                    Text(s.name).font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Capsule().strokeBorder(Theme.ember.opacity(0.4)))
                                }
                                .buttonStyle(.plain).help(s.description)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var suggestions: [String] {
        guard let f = tabs.current.file else {
            return ["看看我「文稿」文件夹里最近有哪些文件，按类型整理成一份清单（Excel）",
                    "帮我写一份本周工作周报的模板（Word）"]
        }
        if tabs.current.renderer is SpreadsheetRenderer {
            return ["先看懂这张表：有哪些列、多少行、有没有空值和异常值",
                    "按第一个分类列分组汇总金额，存成新的 Excel，并告诉我排名前 5",
                    "找出明显异常的数字（比如负数、远超平均的值），选中给我看",
                    "根据这张表写一份分析报告（Word），要有关键数字和结论"]
        }
        switch f.format.family {
        case .markdown:
            return ["帮我润色这篇文档，改得更通顺专业，直接改在编辑器里",
                    "给这篇文档加一个目录和摘要", "把它排版成一份 Word 文档"]
        case .pdf, .office, .iwork, .text:
            return ["概括这份文件的要点，列出需要我注意或处理的事项",
                    "如果这是合同：逐条审阅风险，出一份审阅意见书（Word）",
                    "如果这是简历：按招聘方视角点评，并生成一份优化后的简历（Word）",
                    "把里面的关键数据整理成 Excel 表"]
        case .image:
            return ["识别图片里的文字，整理成文档", "如果是表格截图，把它还原成 Excel"]
        default:
            return ["这个文件是什么？里面有什么值得注意的？"]
        }
    }
}

/// Wraps children onto as many lines as needed.
struct AIFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > w { x = 0; y += line + spacing; line = 0 }
            x += sz.width + spacing
            line = max(line, sz.height)
        }
        return CGSize(width: w, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            line = max(line, sz.height)
        }
    }
}
