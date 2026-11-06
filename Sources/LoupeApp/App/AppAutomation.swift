import AppKit
import LoupeCore

/// Command-line automation used by the test scripts:
///   --probe                 print which engine rendered each file (JSON lines) and quit
///   --delay S  --size WxH  --appearance dark|light  --inspector  --sidebar
/// Debug builds also take these (see AppAutomation+Debug.swift); release builds ignore them:
///   --snapshot DIR          save a PNG of the window per file into DIR
///   --stress DIR --rounds N open every file in DIR N times and report memory
///   --cmd NAME              run a scripted step
@MainActor
final class AppAutomation {
    enum Mode {
        case none, probe
        #if DEBUG
        case snapshot(URL), stress(URL, Int)
        #endif
    }
    private(set) var mode: Mode = .none
    var delay: Double = 1.2
    var hold: Double = 0
    var size: NSSize?
    var appearance: NSAppearance.Name?
    var showInspector = false
    var showSidebar = false
    #if DEBUG
    var commands: [String] = []
    var captureOverride: NSWindow?
    #endif
    var isActive: Bool { if case .none = mode { return false }; return true }

    func parse(_ args: [String]) -> [URL] {
        var urls: [URL] = []
        var i = 1
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--probe": mode = .probe
            #if DEBUG
            case "--snapshot": if let d = next() { mode = .snapshot(URL(fileURLWithPath: d)) }
            case "--stress":
                if let d = next() { mode = .stress(URL(fileURLWithPath: d), 2) }
            case "--rounds":
                if let n = next().flatMap(Int.init), case .stress(let d, _) = mode { mode = .stress(d, n) }
            case "--cmd": if let c = next() { commands.append(c) }
            #endif
            case "--delay": delay = next().flatMap(Double.init) ?? delay
            case "--hold": hold = next().flatMap(Double.init) ?? 0
            case "--size":
                if let s = next() {
                    let p = s.split(separator: "x").compactMap { Double($0) }
                    if p.count == 2 { size = NSSize(width: p[0], height: p[1]) }
                }
            case "--appearance": appearance = next() == "dark" ? .darkAqua : .aqua
            case "--inspector": showInspector = true
            case "--sidebar": showSidebar = true
            default:
                if a.hasPrefix("-") {
                    // Skip system arguments such as -NSDocumentRevisionsDebugMode YES / -psn_…
                    if !a.hasPrefix("-psn"), i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1 }
                } else {
                    urls.append(URL(fileURLWithPath: a).standardizedFileURL)
                }
            }
            i += 1
        }
        return urls
    }

    func run(urls: [URL], app: AppDelegate) {
        if let appearance { NSApp.appearance = NSAppearance(named: appearance) }
        guard let wc = app.newWindow(), let window = wc.window else { exit(2) }
        if let size { window.setContentSize(size); window.center() }
        wc.showWindow(nil)
        if showInspector { wc.toggleInfoPanel(nil) }
        if showSidebar { wc.toggleFileSidebar(nil) }
        Task { @MainActor in
            switch mode {
            case .probe: await probe(urls, wc)
            #if DEBUG
            case .snapshot(let dir): await snapshot(urls, wc, dir)
            case .stress(let dir, let rounds): await stress(dir, rounds, wc)
            #endif
            case .none: break
            }
            if hold > 0 { print("holding pid \(getpid())"); fflush(stdout); await sleep(hold) }
            exit(0)
        }
    }

    func load(_ url: URL, _ wc: ViewerWindowController, timeout: Double = 20) async -> (String, [String]) {
        await withCheckedContinuation { (cont: CheckedContinuation<(String, [String]), Never>) in
            var done = false
            wc.model.onLoadFinished = { engine, failures in
                guard !done else { return }
                done = true
                cont.resume(returning: (engine, failures))
            }
            wc.open(url)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !done else { return }
                done = true
                cont.resume(returning: ("timeout", []))
            }
        }
    }

    func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private func probe(_ urls: [URL], _ wc: ViewerWindowController) async {
        for u in urls {
            let (engine, failures) = await load(u, wc)
            await sleep(0.3)
            let f = wc.model.file
            let obj: [String: Any] = [
                "file": u.lastPathComponent,
                "family": f?.format.family.rawValue ?? "?",
                "token": f?.format.token ?? "?",
                "engine": engine,
                "mismatch": f?.format.extensionMismatch ?? false,
                "status": wc.model.statusText,
                "failures": failures
            ]
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
               let s = String(data: d, encoding: .utf8) {
                print(s)
                fflush(stdout)
            }
        }
    }
}
