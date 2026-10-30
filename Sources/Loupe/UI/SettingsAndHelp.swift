import SwiftUI
import AppKit
import LoupeCore

/// 设置: 通用 and AI tabs.
struct SettingsRoot: View {
    static let tabKey = "settingsTab"
    @AppStorage(SettingsRoot.tabKey) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            SettingsView(settings: .shared)
                .tabItem { Label("通用", systemImage: "gearshape") }.tag("general")
            AISettingsView()
                .frame(width: 560, height: 640)
                .tabItem { Label("AI", systemImage: "sparkles") }.tag("ai")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var mpvStatus = MPVLibrary.statusDescription

    var body: some View {
        Form {
            Section("窗口") {
                Picker("打开新文件时", selection: $settings.singleWindow) {
                    Text("在标签页中打开").tag(true)
                    Text("打开新窗口").tag(false)
                }
                Toggle("默认显示文件夹侧栏", isOn: $settings.showSidebar)
                Toggle("同目录浏览包含隐藏文件", isOn: $settings.showHiddenSiblings)
            }
            Section("文本与图像") {
                Toggle("文本默认自动换行", isOn: $settings.wrapText)
                HStack {
                    Text("语法高亮上限")
                    Spacer()
                    Slider(value: $settings.highlightLimitMB, in: 0.5...10, step: 0.5).frame(width: 160)
                    Text(String(format: "%.1f MB", settings.highlightLimitMB)).font(Theme.mono(11)).frame(width: 56, alignment: .trailing)
                }
                Toggle("图片默认以 1:1 原始像素显示", isOn: $settings.imageStartsActualSize)
                Picker("Excel 等表格默认打开", selection: $settings.spreadsheetOpensOriginal) {
                    Text("表格（可选择、求和、计算）").tag(false)
                    Text("原样（系统预览，只看不算）").tag(true)
                }
                Toggle("允许编辑表格（改单元格、插删行列、保存）", isOn: $settings.spreadsheetEditing)
                Picker("Markdown 打开时", selection: $settings.markdownOpensForWriting) {
                    Text("写作（像 Typora 一样边写边排版）").tag(true)
                    Text("阅读（排版好的页面）").tag(false)
                }
                Toggle("本地网页运行脚本（离线阅读器、导出的报表等；始终断网，只能读本网页所在文件夹）", isOn: $settings.webPagesRunScripts)
            }
            Section("iWork") {
                Toggle("使用已安装的 Pages / Keynote / Numbers 生成完整预览", isOn: $settings.iworkExport)
                Text("首次使用时 macOS 会请求「自动化」权限。生成的 PDF 缓存在本机，文件修改后自动失效。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("视频（mpv）") {
                LabeledContent("状态") {
                    Text(mpvStatus).font(Theme.mono(11)).foregroundStyle(MPVLibrary.isAvailable ? .green : .secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    TextField("libmpv 路径（留空自动检测）", text: $settings.mpvPath)
                    Button("选择…") {
                        let p = NSOpenPanel()
                        p.canChooseFiles = true
                        p.allowsOtherFileTypes = true
                        p.directoryURL = URL(fileURLWithPath: "/opt/homebrew/lib")
                        if p.runModal() == .OK, let u = p.url { settings.mpvPath = u.path }
                        mpvStatus = MPVLibrary.statusDescription
                    }
                }
                Toggle("所有视频都优先用 mpv 播放", isOn: $settings.preferMPV)
                if !MPVLibrary.isAvailable {
                    HStack {
                        Text("安装：").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("brew install mpv").font(Theme.mono(11)).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.ember)
        .onChange(of: settings.mpvPath) { _, _ in mpvStatus = MPVLibrary.statusDescription }
    }
}

struct ShortcutsView: View {
    struct Group: Identifiable { let id = UUID(); let title: String; let items: [(String, String)] }
    let groups: [Group] = [
        Group(title: "文件", items: [("⌘O", "打开"), ("⇧⌘N", "新建窗口"), ("⌘W", "关闭"), ("⇧⌘R", "在 Finder 中显示"),
                                    ("⇧⌘O", "用默认应用打开"), ("⌥⌘C", "拷贝路径"), ("⌘I", "显示 / 隐藏简介")]),
        Group(title: "浏览", items: [("←  →", "同文件夹上一个 / 下一个"), ("⌘[  ⌘]", "上一个 / 下一个文件"), ("⌃⌘S", "文件夹侧栏"), ("⌘J", "AI 助手"),
                                    ("⌃⌘F", "全屏幕")]),
        Group(title: "查看", items: [("⌘+  ⌘−", "放大 / 缩小"), ("⌘0", "实际大小（1:1 像素）"), ("⌘9", "适应窗口"),
                                    ("⌘L  ⌘R", "向左 / 向右旋转"), ("⌘U", "源码 / 渲染切换"), ("⌥⌘L", "自动换行"),
                                    ("⌥⌘P", "全屏放映（演示文稿）")]),
        Group(title: "Markdown 写作", items: [("⌘N", "新建 Markdown 文档"), ("⌘1–⌘6  ⌘0", "标题 / 正文"), ("⌘B  ⌘I  ⌘U", "加粗 / 斜体 / 下划线"),
                                         ("⌘K  ⌃`", "链接 / 行内代码"), ("⌥⌘C  ⌥⌘B", "代码块 / 公式块"), ("⌥⌘O  ⌥⌘U", "有序 / 无序列表"),
                                         ("⌥⌘T  ⌥⌘Q", "表格 / 引用"), ("⌘/", "写作 ⇄ 源码"), ("⌃⌘1", "大纲")]),
        Group(title: "查找", items: [("⌘F", "查找"), ("⌘G", "查找下一个"), ("⇧⌘G", "查找上一个")]),
        Group(title: "影音", items: [("空格", "播放 / 暂停"), ("⇧⌘P", "播放 / 暂停（菜单）"), (",  .", "逐帧后退 / 前进（暂停时）"),
                                    ("J  L", "后退 / 前进 10 秒"), ("↑  ↓", "音量")])
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    RegistrationMark(size: 22, color: Theme.ember)
                    Text("键盘快捷键").font(.system(size: 20, weight: .semibold))
                }
                .padding(.top, 8)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 22) {
                    ForEach(groups) { g in
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: g.title)
                            ForEach(g.items, id: \.0) { k, v in
                                HStack {
                                    Text(k).font(Theme.mono(12, .semibold)).foregroundStyle(Theme.ember)
                                        .frame(width: 84, alignment: .leading)
                                    Text(v).font(.system(size: 12.5))
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .frame(width: 600, height: 520)
    }
}
