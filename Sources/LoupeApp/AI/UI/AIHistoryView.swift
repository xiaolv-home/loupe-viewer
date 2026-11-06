import SwiftUI
import AppKit
import LoupeCore

/// 历史对话: every saved conversation, newest first, grouped by day; open one to carry on,
/// delete the ones you do not need.
struct AIHistoryView: View {
    @ObservedObject var session: AISession
    @ObservedObject var store = AIConversations.shared
    var close: () -> Void
    @State private var query = ""
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("搜索对话", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 12).padding(.vertical, 10)

            let groups = store.grouped(matching: query)
            if groups.isEmpty {
                VStack(spacing: 6) {
                    Text(query.isEmpty ? "还没有对话" : "没有找到相关对话").font(.system(size: 12.5, weight: .medium))
                    Text(query.isEmpty ? "和 AI 的每次对话都会自动保存在这台 Mac 上。" : "换个关键词试试").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                        ForEach(groups, id: \.0) { title, items in
                            Text(title).font(Theme.label).foregroundStyle(.secondary)
                                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 3)
                            ForEach(items) { s in
                                AIHistoryRow(summary: s, current: s.id == session.conversation?.id, disabled: session.running,
                                             open: { session.open(s.id); close() },
                                             delete: { session.deleteConversation(s.id) })
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
                Divider()
                HStack {
                    Text("\(store.list.count) 个对话，保存在本机").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("全部删除…") { confirmClear = true }.buttonStyle(.link).font(.system(size: 11))
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
            }
        }
        .confirmationDialog("删除全部 \(store.list.count) 个对话？", isPresented: $confirmClear) {
            Button("全部删除", role: .destructive) {
                session.newChat()
                store.deleteAll()
            }
        } message: { Text("删除后无法恢复。") }
    }
}

private struct AIHistoryRow: View {
    let summary: AIConversations.Summary
    let current: Bool
    let disabled: Bool
    let open: () -> Void
    let delete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title.isEmpty ? "（无标题）" : summary.title)
                    .font(.system(size: 12.5, weight: current ? .semibold : .medium)).lineLimit(1)
                if !summary.preview.isEmpty {
                    Text(summary.preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(Self.time(summary.updated))
                    if let f = summary.file { Text("· " + f).lineLimit(1).truncationMode(.middle) }
                }
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if hover {
                Button(action: delete) { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("删除这个对话")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(current ? Theme.emberSoft : Color.primary.opacity(hover ? 0.05 : 0)))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if !disabled { open() } }
        .opacity(disabled && !current ? 0.5 : 1)
        .contextMenu {
            Button("打开") { open() }.disabled(disabled)
            Button("删除", role: .destructive, action: delete)
        }
        .help(disabled ? "AI 正在工作，停下后再切换对话" : summary.model)
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDateInToday(d) || Calendar.current.isDateInYesterday(d) ? "HH:mm"
            : Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日 HH:mm" : "yyyy年M月d日"
        return f.string(from: d)
    }
}
