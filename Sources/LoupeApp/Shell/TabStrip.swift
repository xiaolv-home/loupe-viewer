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

    /// Every change to the row of tabs moves the same way.
    static let motion = Animation.snappy(duration: 0.22)

    init(first: ViewerModel) {
        docs = [first]
        current = first
    }

    func insert(_ m: ViewerModel, after other: ViewerModel?) {
        let i = other.flatMap { o in docs.firstIndex { $0 === o } }.map { $0 + 1 } ?? docs.count
        withAnimation(Self.motion) { docs.insert(m, at: i) }
    }

    func remove(_ m: ViewerModel) {
        withAnimation(Self.motion) { docs.removeAll { $0 === m } }
    }

    func move(from: Int, to: Int) {
        guard docs.indices.contains(from), docs.indices.contains(to), from != to else { return }
        withAnimation(Self.motion) { docs.insert(docs.remove(at: from), at: to) }
    }

    /// While a tab is dragged by `translation`: past halfway over a neighbour, the two trade places.
    /// `shift` is how far reordering has already moved it. Returns where the tab sits relative to
    /// its slot.
    func reorder(_ doc: ViewerModel, translation: CGFloat, shift: inout CGFloat, step: CGFloat) -> CGFloat {
        var x = translation - shift
        while x > step / 2, let i = docs.firstIndex(where: { $0 === doc }), i + 1 < docs.count {
            move(from: i, to: i + 1)
            shift += step
            x -= step
        }
        while x < -step / 2, let i = docs.firstIndex(where: { $0 === doc }), i > 0 {
            move(from: i, to: i - 1)
            shift -= step
            x += step
        }
        return x
    }

    func select(_ m: ViewerModel) { current = m }

    /// The tab to show after `m` closes: the one to its right, else to its left.
    func neighbour(of m: ViewerModel) -> ViewerModel? {
        guard let i = docs.firstIndex(where: { $0 === m }) else { return nil }
        if i + 1 < docs.count { return docs[i + 1] }
        return i > 0 ? docs[i - 1] : nil
    }

    // MARK: Geometry

    static let chipMax: CGFloat = 200, chipMin: CGFloat = 72, gap: CGFloat = 4, plusWidth: CGFloat = 24

    private var room: CGFloat { max(Self.chipMin + 30, availableWidth - Self.plusWidth - 10) }
    var chipWidth: CGFloat { max(Self.chipMin, min(Self.chipMax, room / CGFloat(max(1, docs.count)) - Self.gap)) }
    /// What all the tabs need.
    var contentWidth: CGFloat { (chipWidth + Self.gap) * CGFloat(docs.count) - Self.gap }
    /// What they get: past this they scroll.
    var visibleWidth: CGFloat { min(room, contentWidth) }
    /// With too many tabs to fit, how far the row is shifted to keep the current one in view.
    var scrollOffset: CGFloat {
        guard contentWidth > visibleWidth, let i = docs.firstIndex(where: { $0 === current }) else { return 0 }
        let centre = CGFloat(i) * (chipWidth + Self.gap) + chipWidth / 2
        return min(max(0, centre - visibleWidth / 2), contentWidth - visibleWidth)
    }
    /// Right of this the strip is empty, and the window can be dragged by it.
    var usedWidth: CGFloat { visibleWidth + Self.gap + Self.plusWidth }
}

/// Holds the strip in the toolbar at a width that changes only with the window. A toolbar lays its
/// items out a moment after one of them changes size, so a strip sized to its tabs would make
/// everything beside it jump each time a tab came or went.
final class TabStripContainer: NSView {
    private var widthConstraint: NSLayoutConstraint!
    private let host: TabStripHost

    func setWidth(_ width: CGFloat) {
        if widthConstraint.constant != width { widthConstraint.constant = width }
    }

    @MainActor
    init(strip: TabStrip) {
        host = TabStripHost(rootView: strip)
        host.tabs = strip.tabs
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        widthConstraint = widthAnchor.constraint(equalToConstant: 400)
        NSLayoutConstraint.activate([
            widthConstraint,
            host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Past the last tab, clicks go through to the title bar, so the window can be dragged from there.
final class TabStripHost: NSHostingView<TabStrip> {
    weak var tabs: TabList?

    /// On a tab, dragging moves the tab rather than the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let tabs, convert(point, from: superview).x > tabs.usedWidth { return nil }
        return super.hitTest(point)
    }
}

/// Tabs in the title area: one chip per open document, × to close (the last one returns to
/// the home page), + for a new tab, drag to reorder. Switching only swaps the content, so it is
/// instant. Chips are placed by position rather than in a stack, so the one being dragged can
/// follow the pointer exactly while the others slide around it.
struct TabStrip: View {
    @ObservedObject var tabs: TabList
    var select: (ViewerModel) -> Void
    var close: (ViewerModel) -> Void
    var newTab: () -> Void
    @State private var dragged: ViewerModel?
    @State private var dragX: CGFloat = 0
    /// How far the row has already been reordered during this drag.
    @State private var dragShift: CGFloat = 0

    var body: some View {
        let chip = tabs.chipWidth
        let step = chip + TabList.gap
        HStack(spacing: TabList.gap) {
            ZStack(alignment: .leading) {
                ForEach(Array(tabs.docs.enumerated()), id: \.element.id) { index, doc in
                    let isDragged = dragged === doc
                    TabChip(model: doc, active: doc === tabs.current, width: chip, onSelect: { select(doc) }, onClose: { close(doc) })
                        .offset(x: CGFloat(index) * step + (isDragged ? dragX : 0))
                        .zIndex(isDragged ? 1 : 0)
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .leading)))
                        .transaction { if isDragged { $0.animation = nil } }
                        .gesture(reorder(doc))
                }
            }
            .frame(width: tabs.contentWidth, height: 26, alignment: .leading)
            .offset(x: -tabs.scrollOffset)
            .animation(TabList.motion, value: tabs.scrollOffset)
            .frame(width: tabs.visibleWidth, height: 30, alignment: .leading)
            .clipped()
            Button(action: newTab) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: TabList.plusWidth, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("新建标签页（⌘T）")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reorder(_ doc: ViewerModel) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if dragged !== doc {
                    dragged = doc
                    dragShift = 0
                    select(doc)
                }
                let step = tabs.chipWidth + TabList.gap
                let x = tabs.reorder(doc, translation: value.translation.width, shift: &dragShift, step: step)
                dragX = x
            }
            .onEnded { _ in
                dragged = nil
                dragShift = 0
                withAnimation(TabList.motion) { dragX = 0 }
            }
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
                Image(nsImage: FileIcons.icon(for: f.url)).resizable().frame(width: 14, height: 14)
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
