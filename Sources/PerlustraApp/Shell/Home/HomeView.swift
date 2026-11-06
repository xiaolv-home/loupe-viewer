import AppKit
import PerlustraCore
import SwiftUI

/// The start page: fine engraved lines under a loupe, the two things you came to do, and a contact sheet
/// of what you had open.
struct HomeView: View {
    @ObservedObject var model: ViewerModel
    @State private var recents: [RecentFile] = []
    @State private var folders: [URL] = []
    @State private var query = ""
    @State private var showsAll = false
    @State private var shown = false

    private static let cardWidth: CGFloat = 148
    private static let cardGap: CGFloat = 18
    private static let cardHeight: CGFloat = 176

    var body: some View {
        GeometryReader { geo in
            let margin = max(40, (geo.size.width - 1120) / 2)
            let heroHeight = min(max(geo.size.height * 0.56, 280), 480)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(wide: geo.size.width > 760, margin: margin)
                        .frame(maxWidth: .infinity, minHeight: heroHeight, maxHeight: heroHeight, alignment: .leading)
                        .background(GuillocheCanvas(isDropTargeted: model.isDropTargeted, titleEnd: margin + (geo.size.width > 760 ? 372 : 268)))
                    below(width: geo.size.width - margin * 2, roomBelow: geo.size.height - heroHeight)
                        .padding(.horizontal, margin)
                        .padding(.bottom, 26)
                        .reveal(shown, 3)
                }
                .frame(minHeight: geo.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: RecentFiles.didChange)) { _ in
            Task { await reload() }
        }
        .onAppear { shown = true }
    }

    private func reload() async {
        let listed = RecentFiles.listed()
        let found = await Task.detached(priority: .userInitiated) { RecentFiles.details(of: listed) }.value
        recents = found
        folders = AppEnvironment.isScripted ? [] : Array(FolderBrowser.recentFolders.prefix(5))
    }

    // MARK: Hero

    private func hero(wide: Bool, margin: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 7) {
                Text("Perlustra")
                    .font(.system(size: wide ? 84 : 60, weight: .regular, design: .serif))
                    .tracking(wide ? -2.8 : -2.0)
                Text("览")
                    .font(.system(size: wide ? 17 : 14, weight: .heavy))
                    .foregroundStyle(Theme.ember)
                    .padding(.top, wide ? 20 : 14)
            }
            .reveal(shown, 0)
            Text("一个窗口，看清每一种文件。")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .reveal(shown, 1)
            HStack(spacing: 10) {
                HomeButton(title: "打开文件", key: "⌘O", isPrimary: true) {
                    NSApp.sendAction(#selector(AppActions.showOpenPanel(_:)), to: nil, from: nil)
                }
                HomeButton(title: "新建文稿", key: "⌘N", isPrimary: false) {
                    NSApp.sendAction(#selector(AppDelegate.newMarkdownDocument(_:)), to: AppDelegate.shared, from: nil)
                }
            }
            .padding(.top, 26)
            .reveal(shown, 2)
            Text(model.isDropTargeted ? "松开以打开" : "也可以把文件拖到窗口里")
                .font(.system(size: 11.5))
                .foregroundStyle(model.isDropTargeted ? Theme.ember : Color.secondary.opacity(0.8))
                .animation(.easeOut(duration: 0.15), value: model.isDropTargeted)
                .padding(.top, 12)
                .reveal(shown, 2)
        }
        .padding(.leading, margin)
    }

    // MARK: Below the fold

    @ViewBuilder
    private func below(width: CGFloat, roomBelow: CGFloat) -> some View {
        if recents.isEmpty {
            formats(width: width).padding(.top, 8)
        } else {
            let columns = max(2, Int((width + Self.cardGap) / (Self.cardWidth + Self.cardGap)))
            let rows = max(1, Int((roomBelow - 74) / (Self.cardHeight + Self.cardGap)))
            let matches = RecentFiles.matching(recents, query: query)
            let limit = (showsAll || !query.isEmpty) ? matches.count : columns * rows
            VStack(alignment: .leading, spacing: 14) {
                header(total: matches.count, showing: min(limit, matches.count))
                if matches.isEmpty {
                    Text("没有找到「\(query)」").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 60)
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: Self.cardGap, alignment: .top), count: columns),
                        alignment: .leading, spacing: Self.cardGap
                    ) {
                        ForEach(matches.prefix(limit)) { file in
                            RecentCard(file: file, model: model)
                        }
                    }
                }
                if !folders.isEmpty && query.isEmpty { folderLine }
            }
        }
    }

    private func header(total: Int, showing: Int) -> some View {
        HStack(spacing: 12) {
            SectionLabel(text: "最近打开")
            if total > showing || showsAll {
                Button(showsAll ? "收起" : "全部 \(total) 个") { showsAll.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.ember)
            }
            Spacer()
            if recents.count > 6 { RecentSearchField(query: $query) }
            Button("清除") { RecentFiles.clear() }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(height: 22)
    }

    private var folderLine: some View {
        HStack(spacing: 14) {
            SectionLabel(text: "文件夹")
            ForEach(folders, id: \.self) { folder in
                FolderLink(folder: folder) {
                    guard let controller = model.windowController else { return }
                    controller.browser.show(folder)
                    if !controller.isSidebarVisible { controller.toggleFileSidebar(nil) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    /// For a first launch, when there is nothing to go back to: what the app can open.
    private func formats(width: CGFloat) -> some View {
        let kinds: [(FormatCategory, String)] = [
            (.document, "PDF · Office · iWork"), (.image, "照片 · RAW · HDR"), (.media, "视频 · 音频"), (.code, "文本 · 代码 · Markdown"),
            (.data, "表格 · JSON · Plist"), (.archive, "压缩包 · 文件夹"), (.font, "TTF · OTF · WOFF"), (.web, "HTML · SVG"),
        ]
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .leading), count: width > 900 ? 4 : 2),
            alignment: .leading, spacing: 10
        ) {
            ForEach(kinds, id: \.0) { kind, detail in
                HStack(spacing: 9) {
                    Rectangle().fill(Theme.tint(kind)).frame(width: 9, height: 9)
                    Text(Theme.categoryName(kind)).font(.system(size: 12, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
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
            .animation(.easeOut(duration: 0.42).delay(Double(step) * 0.06), value: shown)
    }
}

private struct HomeButton: View {
    let title: String
    let key: String
    let isPrimary: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(key).font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .opacity(isPrimary ? 0.78 : 0.55)
            }
            .foregroundStyle(isPrimary ? Color.white : Color.primary)
            .padding(.horizontal, 15).frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isPrimary ? Theme.ember.opacity(hover ? 0.88 : 1) : Color.primary.opacity(hover ? 0.11 : 0.065))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct FolderLink: View {
    let folder: URL
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: 10))
                Text(folder.lastPathComponent).font(.system(size: 11.5)).lineLimit(1)
            }
            .foregroundStyle(hover ? Theme.ember : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
    }
}
