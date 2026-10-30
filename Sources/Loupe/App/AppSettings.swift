import Foundation
import SwiftUI

/// Set when the debug harness drives the app (tests, screenshots): it then leaves no trace in
/// the user's history — no recent files, remembered folder, window size or sidebar layout.
enum AppEnvironment {
    @MainActor static var isScripted = false
}

/// User preferences backed by UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var singleWindow: Bool { didSet { d.set(singleWindow, forKey: "singleWindow") } }
    @Published var showSidebar: Bool { didSet { d.set(showSidebar, forKey: "showSidebar") } }
    @Published var iworkExport: Bool { didSet { d.set(iworkExport, forKey: "iworkExport") } }
    @Published var mpvPath: String { didSet { d.set(mpvPath, forKey: "mpvPath"); MPVLibrary.reset() } }
    @Published var preferMPV: Bool { didSet { d.set(preferMPV, forKey: "preferMPV") } }
    @Published var wrapText: Bool { didSet { d.set(wrapText, forKey: "wrapText") } }
    @Published var imageStartsActualSize: Bool { didSet { d.set(imageStartsActualSize, forKey: "imageStartsActualSize") } }
    @Published var highlightLimitMB: Double { didSet { d.set(highlightLimitMB, forKey: "highlightLimitMB") } }
    @Published var showHiddenSiblings: Bool { didSet { d.set(showHiddenSiblings, forKey: "showHiddenSiblings") } }
    @Published var spreadsheetOpensOriginal: Bool { didSet { d.set(spreadsheetOpensOriginal, forKey: "spreadsheetOpensOriginal") } }
    /// Tables are for looking and calculating; changing cells is opt-in.
    @Published var spreadsheetEditing: Bool { didSet { d.set(spreadsheetEditing, forKey: "spreadsheetEditing") } }
    /// Local web pages (offline readers, exported reports) run their own scripts — confined to
    /// their folder, with every network request blocked.
    @Published var webPagesRunScripts: Bool { didSet { d.set(webPagesRunScripts, forKey: "webPagesRunScripts") } }
    /// Markdown opens in the Typora-style writer (otherwise as a typeset page to read).
    @Published var markdownOpensForWriting: Bool { didSet { d.set(markdownOpensForWriting, forKey: "markdownOpensForWriting") } }

    private init() {
        d.register(defaults: [
            "singleWindow": true, "showSidebar": false, "iworkExport": true, "mpvPath": "",
            "preferMPV": false, "wrapText": true, "imageStartsActualSize": false,
            "highlightLimitMB": 2.0, "showHiddenSiblings": false, "spreadsheetOpensOriginal": false, "spreadsheetEditing": false, "webPagesRunScripts": true, "markdownOpensForWriting": true
        ])
        singleWindow = d.bool(forKey: "singleWindow")
        showSidebar = d.bool(forKey: "showSidebar")
        iworkExport = d.bool(forKey: "iworkExport")
        mpvPath = d.string(forKey: "mpvPath") ?? ""
        preferMPV = d.bool(forKey: "preferMPV")
        wrapText = d.bool(forKey: "wrapText")
        imageStartsActualSize = d.bool(forKey: "imageStartsActualSize")
        highlightLimitMB = d.double(forKey: "highlightLimitMB")
        showHiddenSiblings = d.bool(forKey: "showHiddenSiblings")
        spreadsheetOpensOriginal = d.bool(forKey: "spreadsheetOpensOriginal")
        spreadsheetEditing = d.bool(forKey: "spreadsheetEditing")
        webPagesRunScripts = d.bool(forKey: "webPagesRunScripts")
        markdownOpensForWriting = d.bool(forKey: "markdownOpensForWriting")
    }

    var highlightLimitBytes: Int { Int(highlightLimitMB * 1024 * 1024) }
}
