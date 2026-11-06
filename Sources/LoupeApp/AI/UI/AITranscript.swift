import SwiftUI
import AppKit
import LoupeCore

/// The conversation: requests, answers, and every action the AI took (with its result).
struct AITranscript: View {
    @ObservedObject var session: AISession
    @ObservedObject private var follow: AIScrollFollow

    init(session: AISession) {
        self.session = session
        self.follow = session.scrollFollow
    }

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
                .background(AIScrollFollowProbe(follow: follow))
            }
            .overlay(alignment: .bottom) {
                if !follow.following {
                    Button {
                        follow.resume()
                        proxy.scrollTo("end", anchor: .bottom)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down")
                            if waitingForApproval { Text("等你确认") }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(waitingForApproval ? Theme.ember : Color.primary.opacity(0.75))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color(nsColor: Theme.sheet)))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("回到最新内容")
                    .padding(.bottom, 8)
                }
            }
            .onChange(of: session.items) { old, new in
                if startedSomethingNew(old, new) { follow.resume() }
                if follow.shouldStick { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var waitingForApproval: Bool {
        session.items.contains { if case .approval(_, decided: nil) = $0.kind { return true }; return false }
    }

    /// The user sent a message or opened another conversation, so they want to see the newest part.
    private func startedSomethingNew(_ old: [AIItem], _ new: [AIItem]) -> Bool {
        if old.first?.id != new.first?.id { return true }
        guard new.count > old.count else { return false }
        return new[old.count...].contains { if case .user = $0.kind { return true }; return false }
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
            AIFileCard(url: url, workspace: session.workspace)
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
    weak var workspace: AIWorkspace?

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
                guard let workspace else { NSWorkspace.shared.open(url); return }
                workspace.aiOpen(url)
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

