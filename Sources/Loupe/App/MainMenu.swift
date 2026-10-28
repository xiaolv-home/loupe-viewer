import AppKit

/// Builds the Chinese main menu. Viewer actions travel the responder chain to the
/// key ViewerWindowController; app-level actions target the delegate.
@MainActor
enum MainMenu {
    static func build(delegate: AppDelegate) -> NSMenu {
        let main = NSMenu()

        // App
        let app = submenu(main, "Loupe")
        add(app, "关于 Loupe", #selector(AppDelegate.showAbout(_:)), target: delegate)
        app.addItem(.separator())
        add(app, "设置…", #selector(AppDelegate.showSettings(_:)), ",", target: delegate)
        app.addItem(.separator())
        let services = NSMenu()
        let si = app.addItem(withTitle: "服务", action: nil, keyEquivalent: "")
        si.submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        add(app, "隐藏 Loupe", #selector(NSApplication.hide(_:)), "h")
        add(app, "隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "全部显示", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "退出 Loupe", #selector(NSApplication.terminate(_:)), "q")

        // File
        let file = submenu(main, "文件")
        add(file, "打开…", #selector(AppDelegate.showOpenPanel(_:)), "o", target: delegate)
        let recentItem = file.addItem(withTitle: "打开最近使用", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "打开最近使用")
        recent.identifier = NSUserInterfaceItemIdentifier("recent")
        recent.delegate = delegate
        recentItem.submenu = recent
        add(file, "新建窗口", #selector(AppDelegate.newViewerWindow(_:)), "n", target: delegate)
        add(file, "新建标签页", #selector(NSResponder.newWindowForTab(_:)), "t")
        file.addItem(.separator())
        add(file, "关闭标签页", #selector(ViewerWindowController.closeTabAction(_:)), "w")
        add(file, "关闭窗口", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        add(file, "保存", #selector(ViewerWindowController.loupeSave(_:)), "s")
        add(file, "另存为…", #selector(ViewerWindowController.loupeSaveAs(_:)), "s", [.command, .shift])
        add(file, "导出当前视图为 CSV…", #selector(ViewerWindowController.loupeExportCSV(_:)))
        add(file, "导出当前视图为 Excel…", #selector(ViewerWindowController.loupeExportXLSX(_:)))
        file.addItem(.separator())
        add(file, "在 Finder 中显示", #selector(ViewerWindowController.revealInFinder(_:)), "r", [.command, .shift])
        add(file, "用默认应用打开", #selector(ViewerWindowController.openWithDefaultApp(_:)), "o", [.command, .shift])
        add(file, "拷贝路径", #selector(ViewerWindowController.copyPath(_:)), "c", [.command, .option])
        add(file, "显示简介", #selector(ViewerWindowController.toggleInfoPanel(_:)), "i")

        // Edit
        let edit = submenu(main, "编辑")
        add(edit, "撤销", Selector(("undo:")), "z")
        add(edit, "重做", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "剪切", #selector(NSText.cut(_:)), "x")
        add(edit, "拷贝", #selector(NSText.copy(_:)), "c")
        add(edit, "粘贴", #selector(NSText.paste(_:)), "v")
        add(edit, "删除", #selector(NSText.delete(_:)))
        add(edit, "全选", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "查找…", #selector(ViewerWindowController.loupeFind(_:)), "f")
        add(edit, "查找下一个", #selector(ViewerWindowController.loupeFindNext(_:)), "g")
        add(edit, "查找上一个", #selector(ViewerWindowController.loupeFindPrevious(_:)), "g", [.command, .shift])

        // View
        let view = submenu(main, "显示")
        add(view, "放大", #selector(ViewerWindowController.loupeZoomIn(_:)), "=")
        add(view, "缩小", #selector(ViewerWindowController.loupeZoomOut(_:)), "-")
        add(view, "实际大小", #selector(ViewerWindowController.loupeActualSize(_:)), "0")
        add(view, "适应窗口", #selector(ViewerWindowController.loupeZoomToFit(_:)), "9")
        view.addItem(.separator())
        add(view, "向左旋转", #selector(ViewerWindowController.loupeRotateLeft(_:)), "l")
        add(view, "向右旋转", #selector(ViewerWindowController.loupeRotateRight(_:)), "r")
        view.addItem(.separator())
        add(view, "切换源码 / 渲染", #selector(ViewerWindowController.loupeToggleSource(_:)), "u")
        add(view, "自动换行", #selector(ViewerWindowController.loupeToggleWrap(_:)), "l", [.command, .option])
        add(view, "播放 / 暂停", #selector(ViewerWindowController.loupePlayPause(_:)), "p", [.command, .shift])
        add(view, "全屏放映", #selector(ViewerWindowController.loupeSlideshow(_:)), "p", [.command, .option])
        view.addItem(.separator())
        add(view, "显示文件夹侧栏", #selector(ViewerWindowController.toggleFileSidebar(_:)), "s", [.command, .control])
        add(view, "显示 AI 助手", #selector(ViewerWindowController.toggleAIPanel(_:)), "j")
        add(view, "进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        // Go
        let go = submenu(main, "前往")
        add(go, "下一个标签页", #selector(ViewerWindowController.nextTab(_:)), "]", [.command, .shift])
        add(go, "上一个标签页", #selector(ViewerWindowController.previousTab(_:)), "[", [.command, .shift])
        go.addItem(.separator())
        add(go, "上一个文件", #selector(ViewerWindowController.previousFile(_:)), "[")
        add(go, "下一个文件", #selector(ViewerWindowController.nextFile(_:)), "]")

        // Window
        let win = submenu(main, "窗口")
        add(win, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(win, "缩放", #selector(NSWindow.performZoom(_:)))
        win.addItem(.separator())
        add(win, "前置全部窗口", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = win

        // Help
        let help = submenu(main, "帮助")
        add(help, "键盘快捷键", #selector(AppDelegate.showShortcuts(_:)), "/", target: delegate)
        NSApp.helpMenu = help
        return main
    }

    @discardableResult
    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        item.submenu = m
        return m
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                            _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        item.target = target
        menu.addItem(item)
        return item
    }
}
