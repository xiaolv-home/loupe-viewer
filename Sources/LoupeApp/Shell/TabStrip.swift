import SwiftUI
import AppKit
import LoupeCore

/// The documents open in one window, and which one is showing.
@MainActor
final class TabList: ObservableObject {
    @Published private(set) var docs: [ViewerModel]
    @Published private(set) var current: ViewerModel
    /// Room for the strip in the toolbar (set by the window as it resizes).
    @Published var availableWidth: CGFloat = 600

    init(first: ViewerModel) {
        docs = [first]
        current = first
    }

    func insert(_ m: ViewerModel, after other: ViewerModel?) {
        let i = other.flatMap { o in docs.firstIndex { $0 === o } }.map { $0 + 1 } ?? docs.count
        docs.insert(m, at: i)
    }

    func remove(_ m: ViewerModel) { docs.removeAll { $0 === m } }
    func select(_ m: ViewerModel) { current = m }

    /// The tab to show after `m` closes: the one to its right, else to its left.
    func neighbour(of m: ViewerModel) -> ViewerModel? {
        guard let i = docs.firstIndex(where: { $0 === m }) else { return nil }
        if i + 1 < docs.count { return docs[i + 1] }
        return i > 0 ? docs[i - 1] : nil
    }
}

/// Tabs in the title area: one chip per open document, × to close (the last one returns to
/// the home page), + for a new tab. Switching only swaps the content, so it is instant.
struct TabStrip: View {
    @ObservedObject var tabs: TabList
    var select: (ViewerModel) -> Void
    var close: (ViewerModel) -> Void
    var newTab: () -> Void

    private let chipMax: CGFloat = 200, chipMin: CGFloat = 96

    var body: some View {
        let count = CGFloat(max(1, tabs.docs.count))
        let room = max(chipMin + 30, tabs.availableWidth - 34)
        let chip = max(chipMin, min(chipMax, room / count - 4))
        let total = min(room, (chip + 4) * count)
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tabs.docs, id: \.id) { doc in
                            TabChip(model: doc, active: doc === tabs.current, width: chip,
                                    onSelect: { select(doc) }, onClose: { close(doc) })
                                .id(doc.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(width: total)
                .onChange(of: tabs.current.id) { _, id in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
            Button(action: newTab) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("新建标签页（⌘T）")
        }
        .fixedSize()
    }
}

private struct TabChip: View {
    @ObservedObject var model: ViewerModel
    let active: Bool
    let width: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hover = false
    @State private var hoverClose = false

    private var dirty: Bool { model.renderer?.hasUnsavedChanges == true }

    var body: some View {
        HStack(spacing: 6) {
            if let f = model.file {
                Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path)).resizable().frame(width: 14, height: 14)
                Text(f.name).lineLimit(1).truncationMode(.middle)
            } else {
                Image(systemName: "house").font(.system(size: 10.5))
                Text("首页").lineLimit(1)
            }
            Spacer(minLength: 0)
            ZStack {
                if dirty && !hover {
                    Circle().fill(Color.primary.opacity(0.55)).frame(width: 7, height: 7)
                } else if hover || active {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color.primary.opacity(hoverClose ? 0.12 : 0)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverClose = $0 }
                    .help("关闭标签页（⌘W）")
                }
            }
            .frame(width: 16, height: 16)
        }
        .font(.system(size: 12, weight: active ? .semibold : .regular))
        .foregroundStyle(active ? Color.primary : Color.secondary)
        .padding(.leading, 9).padding(.trailing, 5)
        .frame(width: width, height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? Color(nsColor: Theme.sheet) : Color.primary.opacity(hover ? 0.06 : 0))
                .shadow(color: .black.opacity(active ? 0.08 : 0), radius: 1, y: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(active ? 0.1 : 0), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onSelect)
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded(onSelect))
        .contextMenu {
            Button("关闭标签页", action: onClose)
            if let u = model.file?.url {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                Button("拷贝路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(u.path, forType: .string)
                }
            }
        }
        .help(model.file?.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "首页")
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
