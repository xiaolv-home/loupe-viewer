import AppKit
import PerlustraCore

/// One open document, as the AI sees it. A request keeps working on the document it started on,
/// even if the user switches tabs meanwhile.
@MainActor
protocol AIDocument: AnyObject {
    var file: FileContext? { get }
    var renderer: Renderer? { get }
}

/// What the AI needs from the window it works in.
@MainActor
protocol AIWorkspace: AnyObject {
    var aiDocument: AIDocument? { get }
    /// The folder the sidebar is showing.
    var aiBrowsingFolder: URL? { get }
    /// Shows a file: its tab if it is open, otherwise in a new one.
    func aiOpen(_ url: URL)
}

/// A renderer that lets the AI work on the open document with its own tools
/// (tables: read, calculate, summarise, add columns, filter; Markdown: edit).
@MainActor
protocol AIDocumentTools: AnyObject {
    /// What is open and selected, in a line or two (sent with each request).
    var aiContext: String { get }
    var aiTools: [AIToolSpec] { get }
    func aiRun(_ name: String, _ args: AIJSON) async -> AIToolOutput
}

extension AIJSON {
    /// A list argument the model may also have written as a single value or "A, B".
    var stringList: [String] {
        if let a = array { return a.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if let s = string {
            return s.split(whereSeparator: { $0 == "," || $0 == "，" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }
}
