import Testing
@testable import LoupeCore

@Suite("保存时只写用户改过的地方（编辑器的规整不落盘）")
struct LineMergeTests {
    // On disk, as the user wrote it.
    let original = """
    # 周报

    这是第一段。

    - [x] 已完成
    - [ ] 待办
    | 区域 | 营业额 |
    | --- | ---: |
    | 华东 | 1 |

    结尾。
    """
    // How the editor tidies it (task markers, blank line, table padding).
    let base = """
    # 周报

    这是第一段。

    - [X]  已完成
    - [ ]  待办


    | 区域 | 营业额 |
    | ---- | -----: |
    | 华东 |      1 |

    结尾。
    """

    @Test("没改就原样不动")
    func untouched() {
        #expect(LineMerge.merge(original: original, base: base, edited: base) == original)
    }

    @Test("改一段：只有那一段变，其余保留原写法")
    func oneParagraph() {
        let edited = base.replacingOccurrences(of: "这是第一段。", with: "## 这是第一段，改过了。")
        let out = LineMerge.merge(original: original, base: base, edited: edited)
        #expect(out == original.replacingOccurrences(of: "这是第一段。", with: "## 这是第一段，改过了。"))
    }

    @Test("在末尾加内容、删掉开头的行")
    func appendAndDelete() {
        let edited = base.replacingOccurrences(of: "# 周报\n\n", with: "") + "\n\n新加的一行"
        let out = LineMerge.merge(original: original, base: base, edited: edited)
        #expect(out.hasPrefix("这是第一段。"))
        #expect(out.hasSuffix("结尾。\n\n新加的一行"))
        #expect(out.contains("- [x] 已完成"))
        #expect(out.contains("| --- | ---: |"))
    }

    @Test("改了编辑器规整过的表格：用编辑器的版本")
    func editInsideTidied() {
        let edited = base.replacingOccurrences(of: "| 华东 |      1 |", with: "| 华东 |      2 |")
        let out = LineMerge.merge(original: original, base: base, edited: edited)
        #expect(out.contains("| 华东 |      2 |"))
        #expect(out.contains("- [x] 已完成"))
        #expect(out.hasPrefix("# 周报\n\n这是第一段。"))
    }
}
