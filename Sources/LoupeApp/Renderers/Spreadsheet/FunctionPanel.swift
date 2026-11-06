import SwiftUI
import LoupeCore

/// ƒx: every supported function by category, searchable, with a plain explanation, how to
/// write it and a worked example. `insert(text, replace)` puts a template or the example
/// into the formula bar.
struct FunctionPanel: View {
    var insert: (_ text: String, _ replaceAll: Bool) -> Void
    @State private var query = ""
    @State private var category = "常用"
    @State private var selected: FunctionDoc? = FunctionCatalog.doc("SUM")

    private var list: [FunctionDoc] {
        query.isEmpty ? FunctionCatalog.all.filter { $0.category == category } : FunctionCatalog.search(query)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("搜索函数或用途，如 查找、求和", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                .padding(10)
                if query.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                        ForEach(FunctionCatalog.categories, id: \.self) { c in
                            Button { category = c; selected = FunctionCatalog.all.first { $0.category == c } } label: {
                                Text(c)
                                    .font(.system(size: 11, weight: c == category ? .semibold : .regular))
                                    .frame(maxWidth: .infinity).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(c == category ? Theme.emberSoft : .clear))
                                    .foregroundStyle(c == category ? Theme.ember : Color.secondary)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(list) { d in
                            Button { selected = d } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    Text(d.summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(selected == d ? Theme.emberSoft : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { insert(d.insertion, false) })
                        }
                        if list.isEmpty {
                            Text("没有找到").font(.system(size: 11.5)).foregroundStyle(.secondary).padding(14)
                        }
                    }
                }
            }
            .frame(width: 250)
            Divider()
            detail
                .frame(width: 380)
        }
        .frame(height: 430)
        .onChange(of: query) { _, _ in if let first = list.first { selected = first } }
    }

    @ViewBuilder private var detail: some View {
        if let d = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(d.name).font(.system(size: 20, weight: .bold, design: .monospaced))
                        Text(d.category).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text(d.summary).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    section("写法") {
                        Text(d.syntax).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
                    }
                    let names = d.argNames
                    if !names.isEmpty {
                        section("参数") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(n).font(.system(size: 12, weight: .semibold)).frame(minWidth: 70, alignment: .leading)
                                        Text(i < d.args.count ? d.args[i] : (n.hasPrefix("[") ? "可以省略" : ""))
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                    section("例子") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(d.example).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.ember).textSelection(.enabled)
                            Text(d.exampleNote).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack {
                        Button("插入 \(d.name)") { insert(d.insertion, false) }.keyboardShortcut(.defaultAction)
                        Button("用这个例子") { insert(d.example, true) }
                        Spacer()
                    }
                    Text("插入后在公式栏里填参数，回车写入当前单元格。条件和文字要用英文双引号，如 \"上海\"。")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        } else {
            Text("选择左侧的函数查看用法").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).textCase(nil)
            content()
        }
    }
}

/// One-line hint under the formula bar while typing inside a function call:
/// the syntax with the current argument emphasised, plus what that argument means.
struct FunctionHint: View {
    let doc: FunctionDoc
    let argument: Int

    var body: some View {
        let names = doc.argNames
        // Repeating arguments ("条件区域2, 条件2…") keep pointing at the last ones.
        let current = names.isEmpty ? -1 : (argument < names.count ? argument : names.count - 1)
        HStack(spacing: 0) {
            Text(doc.name + "(").font(.system(size: 11.5, design: .monospaced))
            ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                Text((i > 0 ? ", " : "") + n)
                    .font(.system(size: 11.5, weight: i == current ? .bold : .regular, design: .monospaced))
                    .foregroundStyle(i == current ? Theme.ember : Color.secondary)
            }
            Text(")").font(.system(size: 11.5, design: .monospaced))
            if current >= 0, current < doc.args.count {
                Text("　" + doc.args[current]).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("　" + doc.summary).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(Theme.emberSoft.opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5) }
    }
}
