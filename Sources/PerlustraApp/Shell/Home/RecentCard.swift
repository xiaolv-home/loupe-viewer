import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Small pictures of recent files, made by the system off the main thread and kept for the session.
@MainActor
enum RecentThumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func cached(for file: RecentFile) -> NSImage? { cache.object(forKey: key(file)) }

    static func load(for file: RecentFile) async -> NSImage? {
        if let known = cached(for: file) { return known }
        let request = QLThumbnailGenerator.Request(
            fileAt: file.url, size: CGSize(width: 296, height: 222), scale: 2, representationTypes: .thumbnail)
        guard let made = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        cache.setObject(made.nsImage, forKey: key(file))
        return made.nsImage
    }

    private static func key(_ file: RecentFile) -> NSString {
        "\(file.url.path)|\(file.modified?.timeIntervalSince1970 ?? 0)" as NSString
    }
}

/// One frame of the contact sheet: the file's first page on the table, its name and when it changed.
struct RecentCard: View {
    let file: RecentFile
    @ObservedObject var model: ViewerModel
    @State private var hover = false
    @State private var thumbnail: NSImage?

    var body: some View {
        Button {
            model.open(file.url)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                frame
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(hover ? Theme.ember : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(file.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        .contextMenu { menu }
        .task(id: file) { thumbnail = await RecentThumbnails.load(for: file) }
    }

    private var detail: String {
        [file.modified.map { RecentFile.timeLabel($0) }, file.folderName].compactMap { $0 }.joined(separator: " · ")
    }

    private var frame: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.primary.opacity(hover ? 0.085 : 0.05))
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                picture
                    .padding(10)
                    .offset(y: hover ? -2 : 0)
            }
            .overlay(alignment: .topTrailing) {
                if !file.typeToken.isEmpty && thumbnail != nil {
                    Text(file.typeToken)
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.62)))
                        .padding(5)
                }
            }
            .overlay {
                CropMarks(gap: 2, length: hover ? 9 : 0)
                    .stroke(Theme.ember, lineWidth: 1)
                    .opacity(hover ? 1 : 0)
            }
            .animation(.snappy(duration: 0.18), value: hover)
    }

    @ViewBuilder
    private var picture: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                .shadow(color: .black.opacity(0.32), radius: 4, y: 2)
        } else {
            VStack(spacing: 5) {
                Image(nsImage: FileIcons.icon(for: file.url)).resizable().frame(width: 40, height: 40)
                if !file.typeToken.isEmpty {
                    Text(file.typeToken).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("打开") { model.open(file.url) }
        Button("在新标签页打开") { AppDelegate.shared?.openInTab(file.url, from: model.windowController) }
        Divider()
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        Button("拷贝路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.url.path, forType: .string)
        }
        Divider()
        Button("从最近打开中移除") { RecentFiles.remove(file.url) }
    }
}

/// Narrows the contact sheet as you type. Esc empties it.
struct RecentSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("筛选", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 150, height: 22)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.055)))
    }
}
