import SwiftUI
import AppKit
import PerlustraCore

/// Renders the model's Markdown answer: headings, lists, quotes, tables and code as blocks,
/// emphasis and links inline.
struct AIMarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownParser.blocks(text).enumerated()), id: \.offset) { _, b in view(b) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ b: MarkdownBlock) -> some View {
        switch b {
        case .heading(let level, let t):
            inline(t).font(.system(size: level <= 1 ? 15 : level == 2 ? 13.5 : 12.5, weight: .semibold)).padding(.top, 3)
        case .paragraph(let lines):
            inline(lines.joined(separator: "\n")).font(.system(size: 12.5)).lineSpacing(2.5)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, t in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(i + 1)." : "•").font(.system(size: 12.5)).foregroundStyle(Theme.ember).frame(minWidth: 10, alignment: .trailing)
                        inline(t).font(.system(size: 12.5)).lineSpacing(2.5)
                    }
                }
            }
        case .quote(let lines):
            inline(lines.joined(separator: "\n")).font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.leading, 9)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.ember.opacity(0.6)).frame(width: 2) }
        case .code(let t):
            Text(t).font(Theme.mono(11)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, c in inline(c).font(.system(size: 11.5, weight: .semibold)) } }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow { ForEach(Array(r.enumerated()), id: \.offset) { _, c in inline(c).font(.system(size: 11.5)) } }
                    }
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        case .rule:
            Divider()
        }
    }

    private func inline(_ s: String) -> Text {
        let t = s.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
        let a = (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t)
        return Text(a)
    }
}
