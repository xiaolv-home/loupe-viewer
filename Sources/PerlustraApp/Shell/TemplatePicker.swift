import AppKit
import PerlustraCore
import SwiftUI

/// 模版库: pick a template and see what it holds, with the places to fill in marked.
@MainActor
enum TemplatesWindow {
    private(set) static var window: NSWindow?

    static func show(use: @escaping (MarkdownTemplate) -> Void) {
        let picker = TemplatePicker(templates: MarkdownTemplates.all()) { template in
            window?.close()
            use(template)
        }
        if let window {
            window.contentViewController = NSHostingController(rootView: picker)
        } else {
            let w = NSWindow(contentViewController: NSHostingController(rootView: picker))
            w.title = "模版库"
            w.backgroundColor = Theme.surface
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 880, height: 600))
            w.minSize = NSSize(width: 640, height: 420)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct TemplatePicker: View {
    let templates: [MarkdownTemplate]
    let use: (MarkdownTemplate) -> Void
    @State private var selection: MarkdownTemplate.ID?
    @State private var query = ""

    private var matches: [MarkdownTemplate] { MarkdownTemplate.matching(templates, query: query) }
    private var groups: [String] {
        var seen = Set<String>()
        return matches.map(\.group).filter { seen.insert($0).inserted }
    }
    private var chosen: MarkdownTemplate? { matches.first { $0.id == selection } ?? matches.first }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TemplateSearchField(query: $query).padding(10)
                List(selection: $selection) {
                    ForEach(groups, id: \.self) { group in
                        Section(group) {
                            ForEach(matches.filter { $0.group == group }) { template in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.title).font(.system(size: 12.5, weight: .medium))
                                    if !template.summary.isEmpty {
                                        Text(template.summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 2)
                                .tag(template.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .contextMenu(
                    forSelectionType: MarkdownTemplate.ID.self, menu: { _ in },
                    primaryAction: { ids in
                        if let id = ids.first, let template = templates.first(where: { $0.id == id }) { use(template) }
                    })
                Divider()
                Button {
                    MarkdownTemplates.revealOwnFolder()
                } label: {
                    Label("打开我的模版文件夹", systemImage: "folder").font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(10)
                .help("把 Markdown 文件放进去，就会出现在「我的模版」里")
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            preview.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: Theme.surface))
        .onAppear { selection = selection ?? matches.first?.id }
        .onChange(of: query) { selection = matches.first?.id }
    }

    @ViewBuilder
    private var preview: some View {
        if let chosen {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(chosen.title).font(.system(size: 17, weight: .semibold))
                    Text("\(MarkdownTemplate.blanks(in: chosen.document()).count) 项待填").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("使用这个模版") { use(chosen) }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                Divider()
                ScrollView {
                    Text(Self.marked(chosen.document()))
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
        } else {
            Text("没有找到「\(query)」").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The template's text with the places to fill in picked out.
    private static func marked(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        for blank in Set(MarkdownTemplate.blanks(in: text)) {
            var from = out.startIndex
            while let found = out[from...].range(of: blank) {
                out[found].foregroundColor = Theme.ember
                from = found.upperBound
            }
        }
        return out
    }
}

private struct TemplateSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("搜索模版", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                .onExitCommand { query = "" }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.055)))
    }
}
