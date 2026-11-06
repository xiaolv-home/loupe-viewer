import SwiftUI
import AppKit
import LoupeCore

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
                        Button {
                            session.input = s; session.send()
                        } label: {
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
                            Button {
                                session.open(s.id)
                            } label: {
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
                                Button {
                                    session.pinnedSkill = s
                                } label: {
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
            return [
                "看看我「文稿」文件夹里最近有哪些文件，按类型整理成一份清单（Excel）",
                "帮我写一份本周工作周报的模板（Word）",
            ]
        }
        if let own = tabs.current.renderer?.aiSuggestions { return own }
        switch f.format.family {
        case .markdown:
            return [
                "帮我润色这篇文档，改得更通顺专业，直接改在编辑器里",
                "给这篇文档加一个目录和摘要", "把它排版成一份 Word 文档",
            ]
        case .pdf, .office, .iwork, .text:
            return [
                "概括这份文件的要点，列出需要我注意或处理的事项",
                "如果这是合同：逐条审阅风险，出一份审阅意见书（Word）",
                "如果这是简历：按招聘方视角点评，并生成一份优化后的简历（Word）",
                "把里面的关键数据整理成 Excel 表",
            ]
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
