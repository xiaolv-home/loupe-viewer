import SwiftUI
import AppKit
import LoupeCore

enum RecentFiles {
    private static let key = "recentFiles"

    static func add(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(30)), forKey: key)
    }

    /// Forgets recent files inside `folder` (both Loupe's list and the system's Open Recent).
    @MainActor
    static func purge(under folder: URL) {
        let prefix = folder.standardizedFileURL.path + "/"
        let own = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { !$0.hasPrefix(prefix) }
        UserDefaults.standard.set(own, forKey: key)
        let dc = NSDocumentController.shared
        let keep = dc.recentDocumentURLs.filter { !$0.standardizedFileURL.path.hasPrefix(prefix) }
        dc.clearRecentDocuments(nil)
        for u in keep.reversed() { dc.noteNewRecentDocumentURL(u) }
    }

    static func all() -> [URL] {
        let fromDocs = NSDocumentController.shared.recentDocumentURLs
        let own = (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        return (own + fromDocs).filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}

/// Crop marks around a rectangle, drawn as a SwiftUI shape. `extend` grows the marks
/// (used as the drop affordance).
struct CropMarks: Shape {
    var gap: CGFloat = 6
    var length: CGFloat = 14
    var animatableData: CGFloat {
        get { length }
        set { length = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        for (x, y, dx, dy) in [(r.minX, r.minY, -1.0, -1.0), (r.maxX, r.minY, 1.0, -1.0),
                               (r.minX, r.maxY, -1.0, 1.0), (r.maxX, r.maxY, 1.0, 1.0)] {
            p.move(to: CGPoint(x: x + dx * gap, y: y)); p.addLine(to: CGPoint(x: x + dx * (gap + length), y: y))
            p.move(to: CGPoint(x: x, y: y + dy * gap)); p.addLine(to: CGPoint(x: x, y: y + dy * (gap + length)))
        }
        return p
    }
}

/// Start page laid out like the title page of a print proof: one left-aligned column,
/// hairline rules, a colour legend and a numbered list of recent files.
struct EmptyStateView: View {
    @ObservedObject var model: ViewerModel
    @State private var recents: [URL] = []
    @State private var shown = false

    private let categories: [(FormatCategory, String)] = [
        (.document, "PDF · Office · iWork"), (.image, "照片 · RAW · HDR"), (.media, "视频 · 音频"),
        (.code, "文本 · 代码 · Markdown"), (.data, "CSV · JSON · Plist"), (.archive, "压缩包 · 文件夹"),
        (.font, "TTF · OTF · WOFF"), (.web, "HTML · SVG")
    ]

    var body: some View {
        GeometryReader { geo in
            let column = min(500, max(280, geo.size.width - 120))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header.reveal(shown, 0)
                    title.padding(.top, 40).reveal(shown, 1)
                    rule.padding(.top, 30).reveal(shown, 2)
                    openRow.reveal(shown, 2)
                    rule.reveal(shown, 2)
                    legend(width: column).padding(.top, 22).reveal(shown, 3)
                    if !recents.isEmpty {
                        recentList.padding(.top, 34).reveal(shown, 4)
                    }
                }
                .frame(width: column, alignment: .leading)
                .padding(.vertical, 34)
                .padding(.horizontal, 30)
                .overlay(
                    CropMarks(gap: 8, length: model.isDropTargeted ? 30 : 14)
                        .stroke(model.isDropTargeted ? Theme.ember : Color.primary.opacity(0.32), lineWidth: model.isDropTargeted ? 1.5 : 0.75)
                        .animation(.spring(duration: 0.35, bounce: 0.15), value: model.isDropTargeted)
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear {
            recents = RecentFiles.all()
            shown = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            RegistrationMark(size: 12, color: .primary.opacity(0.55))
            Text("LOUPE")
                .font(.system(size: 10, weight: .semibold)).tracking(3)
            Text("文件查看器").font(.system(size: 10)).tracking(1.5).foregroundStyle(.secondary)
            Spacer()
            Text("离线 · 只读").font(.system(size: 10)).tracking(1.5).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary.opacity(0.75))
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                Text("Loupe")
                    .font(.system(size: 60, weight: .semibold))
                    .tracking(-2.4)
                Text("览")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Theme.ember)
                    .padding(.top, 10)
            }
            Text("一个窗口，看清每一种文件。")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }

    private var rule: some View {
        Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 0.5)
    }

    private var openRow: some View {
        HStack(spacing: 12) {
            Text(model.isDropTargeted ? "松开以打开" : "将文件拖到窗口中")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.isDropTargeted ? Theme.ember : .primary)
                .animation(.easeOut(duration: 0.15), value: model.isDropTargeted)
            Spacer()
            OpenButton()
        }
        .padding(.vertical, 14)
    }

    private func legend(width: CGFloat) -> some View {
        let cols = width > 420 ? 2 : 1
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .leading), count: cols),
                         alignment: .leading, spacing: 9) {
            ForEach(categories, id: \.0) { c, detail in
                HStack(spacing: 9) {
                    Rectangle().fill(Theme.tint(c)).frame(width: 9, height: 9)
                    Text(Theme.categoryName(c)).font(.system(size: 12, weight: .semibold)).frame(width: 30, alignment: .leading)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "最近打开")
                Spacer()
                Button("清除") { RecentFiles.clear(); withAnimation { recents = [] } }
                    .buttonStyle(.plain).font(.system(size: 10.5)).tracking(1).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(recents.prefix(6).enumerated()), id: \.element) { i, url in
                    RecentRow(index: i + 1, url: url) { model.open(url) }
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                }
            }
        }
    }
}

private extension View {
    /// One-time staggered entrance: fade and settle 6pt upward.
    func reveal(_ shown: Bool, _ step: Int) -> some View {
        self.opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .animation(.easeOut(duration: 0.38).delay(Double(step) * 0.05), value: shown)
    }
}

private struct OpenButton: View {
    @State private var hover = false
    var body: some View {
        Button { AppDelegate.shared?.showOpenPanel(nil) } label: {
            HStack(spacing: 10) {
                Text("打开文件").font(.system(size: 12.5, weight: .semibold))
                Text("⌘O").font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.18)))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.ember.opacity(hover ? 0.88 : 1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct RecentRow: View {
    let index: Int
    let url: URL
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(String(format: "%02d", index))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(hover ? Theme.ember : Color.secondary.opacity(0.7))
                    .frame(width: 18, alignment: .leading)
                Text(url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(hover ? Theme.ember : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 16)
                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
