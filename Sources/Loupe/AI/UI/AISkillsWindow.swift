import SwiftUI
import AppKit
import LoupeCore

/// 技能库: the skills the AI has, a curated market of good ones on GitHub, and install-from-link.
enum AISkillsWindow {
    @MainActor private static var window: NSWindow?

    /// `market` opens on 技能市场 the first time the window is made.
    @MainActor static func show(market: Bool = false) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: AISkillsView(tab: market ? 1 : 0)))
            w.title = "技能库"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 760, height: 560))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AISkillsView: View {
    @ObservedObject var skills = AISkills.shared
    @State var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("已有技能（\(skills.all.count)）").tag(0)
                Text("技能市场").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 280).padding(.vertical, 10)
            Divider()
            if tab == 0 { InstalledSkills() } else { SkillMarket() }
        }
        .frame(minWidth: 620, minHeight: 420)
    }
}

private struct InstalledSkills: View {
    @ObservedObject var skills = AISkills.shared
    @State private var selection: Skill.ID?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                Section("Loupe 自带") { ForEach(skills.all.filter(\.builtIn)) { row($0) } }
                Section("已安装") {
                    if skills.all.filter({ !$0.builtIn }).isEmpty {
                        Text("还没有安装。去「技能市场」挑选，或粘贴 GitHub 链接安装。").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(skills.all.filter { !$0.builtIn }) { row($0) }
                }
            }
            .frame(minWidth: 240, idealWidth: 260)
            Group {
                if let s = skills.all.first(where: { $0.id == selection }) { SkillDetail(skill: s) }
                else { Text("选择一个技能查看说明").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .frame(minWidth: 320)
        }
    }

    private func row(_ s: Skill) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { skills.isEnabled(s) }, set: { skills.setEnabled(s, $0) })).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(s.description).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .tag(s.id)
    }
}

private struct SkillDetail: View {
    let skill: Skill
    @ObservedObject var skills = AISkills.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(skill.name).font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([skill.skillFile]) }.controlSize(.small)
                if !skill.builtIn {
                    Button("移除") { skills.remove(skill) }.controlSize(.small)
                }
            }
            Text(skill.description).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let src = skill.source, let u = URL(string: src) {
                Link(src.replacingOccurrences(of: "https://", with: ""), destination: u).font(.system(size: 11))
            }
            let files = skill.resourceFiles()
            if !files.isEmpty {
                Text("附带 \(files.count) 个参考文件").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                Text(skill.instructions()).font(.system(size: 11.5)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
    }
}

private struct SkillMarket: View {
    @ObservedObject var skills = AISkills.shared
    @State private var link = ""
    @State private var message = ""
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                TextField("粘贴 GitHub 链接安装任意技能，如 github.com/owner/repo 或其中的技能文件夹", text: $link)
                    .textFieldStyle(.roundedBorder).onSubmit { install(link) }
                Button("安装") { install(link) }.disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || skills.installing[link] != nil)
            }
            .padding(12)
            if !message.isEmpty {
                Text(message).font(.system(size: 11)).foregroundStyle(failed ? Color(nsColor: .systemRed) : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 6)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text("下面是挑过的、内容扎实、许可证允许使用的技能。安装后会出现在「已有技能」里，AI 遇到相关任务会自动使用。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(SkillCatalog.categories, id: \.self) { cat in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(cat).font(.system(size: 13, weight: .semibold))
                            ForEach(SkillCatalog.entries.filter { $0.category == cat }) { e in entry(e) }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func entry(_ e: SkillCatalog.Entry) -> some View {
        let installed = skills.installed(from: e)
        let busy = skills.installing[e.url]
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(e.title).font(.system(size: 12.5, weight: .semibold))
                    ForEach(e.tags, id: \.self) { t in
                        Text(t).font(.system(size: 9.5, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                Text(e.summary).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link(e.url.replacingOccurrences(of: "https://github.com/", with: ""), destination: URL(string: e.url)!).font(.system(size: 10.5))
            }
            Spacer()
            if let busy {
                Text(busy).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !installed.isEmpty {
                Menu("已安装 \(installed.count)") {
                    Button("重新安装（更新）") { install(e.url) }
                    Button("移除") { installed.forEach { skills.remove($0) } }
                }
                .fixedSize().controlSize(.small)
            } else {
                Button("安装") { install(e.url) }.controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private func install(_ url: String) {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        message = ""
        Task {
            do {
                let got = try await skills.install(u)
                failed = false
                message = "已安装 \(got.count) 个技能：" + got.map(\.name).prefix(12).joined(separator: "、")
                if u == link { link = "" }
            } catch {
                failed = true
                message = "安装失败：" + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}
