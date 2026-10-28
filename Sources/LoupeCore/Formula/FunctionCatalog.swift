import Foundation

/// Plain-Chinese help for every function the engine supports: what it does, how to write it
/// and a worked example. Shown in the ƒx panel and as a live hint while typing a formula.
public struct FunctionDoc: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let category: String
    /// "COUNTIF(区域, 条件)"; optional arguments in [ ], repeatable ones end with "…".
    public let syntax: String
    public let summary: String
    public let example: String
    public let exampleNote: String
    /// Extra notes per argument, in order.
    public let args: [String]

    /// Argument names as written in `syntax` ("区域", "[匹配方式]", "数值2…").
    public var argNames: [String] {
        guard let a = syntax.firstIndex(of: "("), let b = syntax.lastIndex(of: ")"), a < b else { return [] }
        let inner = syntax[syntax.index(after: a)..<b]
        return inner.isEmpty ? [] : inner.components(separatedBy: ", ")
    }

    /// What to put in the formula bar when the function is picked: "=COUNTIF(".
    public var insertion: String { argNames.isEmpty ? "\(name)()" : "\(name)(" }
}

public enum FunctionCatalog {
    public static let categories = ["常用", "条件统计", "查找引用", "逻辑判断", "数学", "文本", "日期", "信息"]

    public static func doc(_ name: String) -> FunctionDoc? { byName[name.uppercased()] }

    /// Functions whose name or description contains the query (case-insensitive).
    public static func search(_ q: String) -> [FunctionDoc] {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(t) || $0.summary.localizedCaseInsensitiveContains(t) || $0.category.contains(t) }
            .sorted { a, b in
                let ap = a.name.uppercased().hasPrefix(t.uppercased()), bp = b.name.uppercased().hasPrefix(t.uppercased())
                return ap != bp ? ap : false
            }
    }

    /// Which function call the cursor is in, and which argument (0-based), for the live hint.
    /// `text` is the formula up to the cursor.
    public static func context(beforeCursor text: String) -> (doc: FunctionDoc, argument: Int)? {
        var stack: [(name: String, arg: Int)] = []
        var word = ""
        var inString = false
        for ch in text {
            if inString { if ch == "\"" { inString = false }; continue }
            switch ch {
            case "\"": inString = true; word = ""
            case "(": stack.append((word.uppercased(), 0)); word = ""
            case ")": if !stack.isEmpty { stack.removeLast() }; word = ""
            case ",": if !stack.isEmpty { stack[stack.count - 1].arg += 1 }; word = ""
            default:
                if ch.isLetter || ch.isNumber || ch == "." || ch == "_" { word.append(ch) } else { word = "" }
            }
        }
        for frame in stack.reversed() { if let d = doc(frame.name) { return (d, frame.arg) } }
        return nil
    }

    private static let byName: [String: FunctionDoc] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    private static func f(_ name: String, _ cat: String, _ syntax: String, _ summary: String,
                          _ example: String, _ note: String, _ args: [String] = []) -> FunctionDoc {
        FunctionDoc(name: name, category: cat, syntax: syntax, summary: summary, example: example, exampleNote: note, args: args)
    }

    public static let all: [FunctionDoc] = [
        // 常用
        f("SUM", "常用", "SUM(数值1, 数值2…)", "把数字加起来。可以写单元格、区域或数字，文字会被跳过。",
          "=SUM(D2:D100)", "D2 到 D100 所有数字的合计", ["要相加的单元格或区域", "还可以继续写更多区域"]),
        f("AVERAGE", "常用", "AVERAGE(数值1, 数值2…)", "求平均值。空格和文字不算进去。",
          "=AVERAGE(E2:E31)", "E 列 30 天的日均值"),
        f("COUNT", "常用", "COUNT(数值1, 数值2…)", "数一数有多少个格子是数字。",
          "=COUNT(D2:D100)", "D 列填了数字的格子数"),
        f("COUNTA", "常用", "COUNTA(值1, 值2…)", "数一数有多少个格子不是空的（文字、数字都算）。",
          "=COUNTA(A2:A100)", "A 列一共填了几行"),
        f("COUNTBLANK", "常用", "COUNTBLANK(区域)", "数一数区域里有多少个空格子。",
          "=COUNTBLANK(C2:C100)", "C 列还有几行没填"),
        f("MAX", "常用", "MAX(数值1, 数值2…)", "找出最大的数。", "=MAX(D2:D100)", "D 列里最大的金额"),
        f("MIN", "常用", "MIN(数值1, 数值2…)", "找出最小的数。", "=MIN(D2:D100)", "D 列里最小的金额"),
        f("MEDIAN", "常用", "MEDIAN(数值1, 数值2…)", "中位数：从小到大排好后正中间那个数，不受极端值影响。",
          "=MEDIAN(D2:D100)", "D 列金额的中位数"),
        f("LARGE", "常用", "LARGE(区域, 第几大)", "取第几大的数。", "=LARGE(D2:D100, 3)", "D 列第 3 大的金额"),
        f("SMALL", "常用", "SMALL(区域, 第几小)", "取第几小的数。", "=SMALL(D2:D100, 1)", "等同于最小值"),
        f("PRODUCT", "数学", "PRODUCT(数值1, 数值2…)", "把数字全部相乘。", "=PRODUCT(B2, C2)", "数量 × 单价"),
        f("STDEV", "数学", "STDEV(数值1, 数值2…)", "样本标准差，衡量数据波动有多大。", "=STDEV(D2:D31)", "30 天销售额的波动"),
        f("VAR", "数学", "VAR(数值1, 数值2…)", "样本方差（标准差的平方）。", "=VAR(D2:D31)", "30 天销售额的方差"),

        // 条件统计
        f("SUMIF", "条件统计", "SUMIF(条件区域, 条件, [求和区域])", "只把满足条件的行加起来。条件可以写 \"上海\"、\">100\"、\"<>0\"、\"*店\"（* 代表任意文字）。",
          "=SUMIF(B:B, \"上海\", D:D)", "B 列是「上海」的那些行，D 列金额的合计",
          ["用来判断条件的那一列", "条件，文字要加英文双引号", "要相加的那一列；省略时就加条件区域本身"]),
        f("SUMIFS", "条件统计", "SUMIFS(求和区域, 条件区域1, 条件1, 条件区域2, 条件2…)", "多个条件同时满足才加。注意求和区域写在最前面。",
          "=SUMIFS(D:D, B:B, \"上海\", C:C, \">=2026-10-01\")", "上海、10 月 1 日以后的金额合计",
          ["要相加的那一列", "第一个条件所在的列", "第一个条件", "可以继续成对写更多条件"]),
        f("COUNTIF", "条件统计", "COUNTIF(区域, 条件)", "数一数区域里有多少个格子满足条件。",
          "=COUNTIF(B:B, \"上海\")", "B 列里有几行是「上海」",
          ["要检查的区域", "条件：\"上海\"、\">100\"、\"<>\"（不为空）、\"*看板\"（以看板结尾）"]),
        f("COUNTIFS", "条件统计", "COUNTIFS(区域1, 条件1, 区域2, 条件2…)", "多个条件同时满足的行数。",
          "=COUNTIFS(B:B, \"上海\", D:D, \">1000\")", "上海且金额超过 1000 的行数"),
        f("AVERAGEIF", "条件统计", "AVERAGEIF(条件区域, 条件, [求平均区域])", "满足条件的行的平均值。",
          "=AVERAGEIF(B:B, \"上海\", D:D)", "上海门店的平均金额"),
        f("AVERAGEIFS", "条件统计", "AVERAGEIFS(求平均区域, 条件区域1, 条件1, 条件区域2, 条件2…)", "多个条件同时满足的行的平均值。",
          "=AVERAGEIFS(D:D, B:B, \"上海\", C:C, \"堂食\")", "上海堂食的平均金额"),
        f("MAXIFS", "条件统计", "MAXIFS(取值区域, 条件区域1, 条件1…)", "满足条件的行里的最大值。",
          "=MAXIFS(D:D, B:B, \"上海\")", "上海门店的最高金额"),
        f("MINIFS", "条件统计", "MINIFS(取值区域, 条件区域1, 条件1…)", "满足条件的行里的最小值。",
          "=MINIFS(D:D, B:B, \"上海\")", "上海门店的最低金额"),
        f("SUMPRODUCT", "条件统计", "SUMPRODUCT(区域1, 区域2…)", "两列（或多列）逐行相乘再加总，比如数量×单价的总额。",
          "=SUMPRODUCT(B2:B10, C2:C10)", "每行数量×单价，再全部加起来"),

        // 查找引用
        f("VLOOKUP", "查找引用", "VLOOKUP(要找的值, 表格区域, 第几列, [是否近似])", "在表格区域的第一列里找某个值，返回同一行第几列的内容。最常用的「查表」。",
          "=VLOOKUP(A2, 门店表!A:C, 3, FALSE)", "拿 A2 的门店名到「门店表」A 列里找，返回那一行第 3 列（C 列）",
          ["要找的值，比如门店名、编号", "被查的表，要找的值必须在它的第一列", "返回这个区域里的第几列（从 1 数）", "精确查找写 FALSE；省略或 TRUE 是近似查找（要求第一列已排序）"]),
        f("HLOOKUP", "查找引用", "HLOOKUP(要找的值, 表格区域, 第几行, [是否近似])", "和 VLOOKUP 一样，只是横着找：在第一行里找，返回第几行。",
          "=HLOOKUP(\"10月\", A1:M5, 3, FALSE)", "在第 1 行找「10月」，返回该列第 3 行"),
        f("XLOOKUP", "查找引用", "XLOOKUP(要找的值, 查找列, 返回列, [找不到时], [匹配方式])", "更好用的查找：查找列和返回列分开写，可以往左查，找不到时可以给默认值。",
          "=XLOOKUP(A2, 门店表!B:B, 门店表!A:A, \"无\")", "在 B 列找 A2，返回同行 A 列；找不到显示「无」",
          ["要找的值", "在哪一列里找", "找到后返回哪一列的内容", "找不到时显示什么（可省略）", "0 精确（默认）；-1 找不到取下一个较小的；1 取下一个较大的；2 支持 * ? 通配"]),
        f("INDEX", "查找引用", "INDEX(区域, 第几行, [第几列])", "取区域里第几行第几列的值。常和 MATCH 搭配。",
          "=INDEX(C2:C100, 5)", "C2:C100 里的第 5 个，也就是 C6"),
        f("MATCH", "查找引用", "MATCH(要找的值, 区域, [匹配方式])", "返回值在区域里排第几（位置号）。",
          "=INDEX(C:C, MATCH(\"西湖店\", A:A, 0))", "先用 MATCH 找到「西湖店」在第几行，再用 INDEX 取那一行的 C 列",
          ["要找的值", "一行或一列", "0 精确匹配；1（默认）找不大于它的最大值，要求升序；-1 反之"]),
        f("XMATCH", "查找引用", "XMATCH(要找的值, 区域, [匹配方式])", "MATCH 的新版本，默认就是精确匹配。",
          "=XMATCH(\"西湖店\", A:A)", "「西湖店」在 A 列第几行"),
        f("CHOOSE", "查找引用", "CHOOSE(序号, 值1, 值2…)", "按序号从后面几个值里挑一个。",
          "=CHOOSE(2, \"一季度\", \"二季度\", \"三季度\")", "结果是「二季度」"),
        f("ROWS", "查找引用", "ROWS(区域)", "区域有几行。", "=ROWS(A2:A100)", "结果是 99"),
        f("COLUMNS", "查找引用", "COLUMNS(区域)", "区域有几列。", "=COLUMNS(A1:F1)", "结果是 6"),

        // 逻辑判断
        f("IF", "逻辑判断", "IF(条件, 成立时, [不成立时])", "如果条件成立返回一个值，否则返回另一个值。",
          "=IF(D2>=10000, \"达标\", \"未达标\")", "D2 满 1 万显示达标，否则未达标",
          ["判断条件，如 D2>=10000、B2=\"上海\"", "条件成立时的结果", "条件不成立时的结果（省略则为 FALSE）"]),
        f("IFS", "逻辑判断", "IFS(条件1, 结果1, 条件2, 结果2…)", "多个条件依次判断，返回第一个成立条件对应的结果，免得 IF 套 IF。",
          "=IFS(D2>=10000, \"优\", D2>=5000, \"良\", TRUE, \"差\")", "按金额分三档；最后的 TRUE 表示「其他情况」"),
        f("SWITCH", "逻辑判断", "SWITCH(表达式, 值1, 结果1, 值2, 结果2…, [默认结果])", "把一个值和一串候选比较，等于谁就返回谁的结果。",
          "=SWITCH(B2, \"mt\", \"美团\", \"elm\", \"饿了么\", \"其他\")", "把平台代码翻译成中文"),
        f("IFERROR", "逻辑判断", "IFERROR(值, 出错时)", "公式出错（#N/A、#DIV/0! 等）时改为显示指定内容。",
          "=IFERROR(VLOOKUP(A2, 门店表!A:C, 3, FALSE), \"未找到\")", "查不到时显示「未找到」而不是 #N/A"),
        f("IFNA", "逻辑判断", "IFNA(值, 是#N/A时)", "只在结果是 #N/A（查不到）时替换。",
          "=IFNA(XMATCH(A2, B:B), 0)", "找不到时返回 0"),
        f("AND", "逻辑判断", "AND(条件1, 条件2…)", "所有条件都成立才是 TRUE。",
          "=IF(AND(D2>0, E2>0), \"正常\", \"检查\")", "两个数都大于 0 才算正常"),
        f("OR", "逻辑判断", "OR(条件1, 条件2…)", "任意一个条件成立就是 TRUE。",
          "=IF(OR(B2=\"上海\", B2=\"北京\"), \"一线\", \"其他\")", "上海或北京归为一线"),
        f("NOT", "逻辑判断", "NOT(条件)", "把 TRUE 变 FALSE，FALSE 变 TRUE。", "=NOT(ISBLANK(A2))", "A2 不为空时为 TRUE"),
        f("XOR", "逻辑判断", "XOR(条件1, 条件2…)", "成立的条件个数为奇数时为 TRUE。", "=XOR(D2>0, E2>0)", "两者恰好一个大于 0"),

        // 数学
        f("ROUND", "数学", "ROUND(数值, 保留几位小数)", "四舍五入。", "=ROUND(D2/E2, 2)", "相除后保留两位小数",
          ["要处理的数", "小数位数；0 取整；-2 表示到百位"]),
        f("ROUNDUP", "数学", "ROUNDUP(数值, 保留几位小数)", "总是往上进位。", "=ROUNDUP(3.21, 1)", "结果 3.3"),
        f("ROUNDDOWN", "数学", "ROUNDDOWN(数值, 保留几位小数)", "总是往下舍去。", "=ROUNDDOWN(3.29, 1)", "结果 3.2"),
        f("INT", "数学", "INT(数值)", "向下取整。", "=INT(7.9)", "结果 7"),
        f("ABS", "数学", "ABS(数值)", "绝对值（去掉负号）。", "=ABS(D2-E2)", "两数相差多少，不管谁大"),
        f("MOD", "数学", "MOD(被除数, 除数)", "相除后的余数。", "=MOD(A2, 7)", "A2 除以 7 的余数，比如第几周余几天"),
        f("POWER", "数学", "POWER(底数, 指数)", "乘方。", "=POWER(1.05, 3)", "1.05 的 3 次方"),
        f("SQRT", "数学", "SQRT(数值)", "平方根。", "=SQRT(16)", "结果 4"),
        f("CEILING", "数学", "CEILING(数值, 倍数)", "向上取到最近的倍数。", "=CEILING(23, 5)", "结果 25"),
        f("FLOOR", "数学", "FLOOR(数值, 倍数)", "向下取到最近的倍数。", "=FLOOR(23, 5)", "结果 20"),
        f("SIGN", "数学", "SIGN(数值)", "正数 1、负数 -1、零 0。", "=SIGN(E2)", "看增长还是下降"),
        f("PI", "数学", "PI()", "圆周率 3.14159…", "=PI()*2^2", "半径 2 的圆面积"),
        f("RAND", "数学", "RAND()", "0 到 1 之间的随机数，每次重算都会变。", "=RAND()", "抽样时打乱顺序"),

        // 文本
        f("CONCAT", "文本", "CONCAT(文本1, 文本2…)", "把几段文字拼在一起。也可以直接用 & 连接。",
          "=CONCAT(B2, \"-\", A2)", "例如「上海-南京东路店」；等同于 =B2&\"-\"&A2"),
        f("CONCATENATE", "文本", "CONCATENATE(文本1, 文本2…)", "CONCAT 的旧名字，用法相同。", "=CONCATENATE(A2, B2)", "把 A2 和 B2 接起来"),
        f("TEXTJOIN", "文本", "TEXTJOIN(分隔符, 是否跳过空格, 文本1…)", "用分隔符把一串值连起来，可以跳过空格子。",
          "=TEXTJOIN(\"、\", TRUE, A2:A10)", "把 A2:A10 用顿号连成一句"),
        f("LEN", "文本", "LEN(文本)", "文字有几个字符。", "=LEN(A2)", "A2 的字数"),
        f("LEFT", "文本", "LEFT(文本, [取几个字])", "从左边取几个字。", "=LEFT(A2, 2)", "取前两个字，比如城市名"),
        f("RIGHT", "文本", "RIGHT(文本, [取几个字])", "从右边取几个字。", "=RIGHT(A2, 4)", "取最后 4 位，比如手机尾号"),
        f("MID", "文本", "MID(文本, 从第几个开始, 取几个字)", "从中间取一段。", "=MID(A2, 7, 8)", "从身份证号第 7 位取 8 位，就是出生日期"),
        f("FIND", "文本", "FIND(要找的字, 文本, [从第几个开始])", "某段文字在第几个位置（区分大小写），找不到是 #VALUE!。",
          "=FIND(\"店\", A2)", "「店」在 A2 的第几个字"),
        f("SEARCH", "文本", "SEARCH(要找的字, 文本, [从第几个开始])", "同 FIND，但不区分大小写。", "=SEARCH(\"bi\", A2)", "找 BI / bi 的位置"),
        f("SUBSTITUTE", "文本", "SUBSTITUTE(文本, 旧文字, 新文字)", "把文字里的某段换成另一段。", "=SUBSTITUTE(A2, \"店\", \"\")", "去掉 A2 里的「店」字"),
        f("REPLACE", "文本", "REPLACE(文本, 从第几个开始, 替换几个, 新文字)", "按位置替换。", "=REPLACE(A2, 4, 4, \"****\")", "把手机号中间 4 位打码"),
        f("UPPER", "文本", "UPPER(文本)", "转成大写。", "=UPPER(A2)", "abc → ABC"),
        f("LOWER", "文本", "LOWER(文本)", "转成小写。", "=LOWER(A2)", "ABC → abc"),
        f("PROPER", "文本", "PROPER(文本)", "每个单词首字母大写。", "=PROPER(A2)", "hello world → Hello World"),
        f("TRIM", "文本", "TRIM(文本)", "去掉多余的空格。", "=TRIM(A2)", "清理粘贴进来的数据"),
        f("REPT", "文本", "REPT(文本, 重复几次)", "把文字重复几遍。", "=REPT(\"★\", E2)", "按评分画星星"),
        f("EXACT", "文本", "EXACT(文本1, 文本2)", "两段文字是否完全一样（区分大小写）。", "=EXACT(A2, B2)", "核对两列是否一致"),
        f("VALUE", "文本", "VALUE(文本)", "把看起来像数字的文字变成真正的数字。", "=VALUE(\"1,234\")", "结果 1234"),
        f("TEXT", "文本", "TEXT(数值, 格式)", "把数字或日期按格式变成文字。",
          "=TEXT(C2, \"yyyy年m月d日\")", "日期显示成「2026年10月23日」；金额可用 \"#,##0.00\"，百分比用 \"0.0%\"",
          ["要格式化的数字或日期", "格式代码，如 \"0.00\"、\"#,##0\"、\"0%\"、\"yyyy-mm-dd\""]),

        // 日期
        f("TODAY", "日期", "TODAY()", "今天的日期。", "=TODAY()-C2", "距 C2 那天过了多少天"),
        f("NOW", "日期", "NOW()", "现在的日期和时间。", "=NOW()", "当前时刻"),
        f("DATE", "日期", "DATE(年, 月, 日)", "用年月日拼出一个日期。", "=DATE(2026, 10, 1)", "2026 年 10 月 1 日"),
        f("YEAR", "日期", "YEAR(日期)", "取年份。", "=YEAR(C2)", "C2 是哪一年"),
        f("MONTH", "日期", "MONTH(日期)", "取月份（1–12）。", "=MONTH(C2)", "C2 是几月"),
        f("DAY", "日期", "DAY(日期)", "取几号（1–31）。", "=DAY(C2)", "C2 是几号"),
        f("WEEKDAY", "日期", "WEEKDAY(日期)", "星期几：周日 1，周一 2 … 周六 7。", "=WEEKDAY(C2)", "判断是否周末"),
        f("DAYS", "日期", "DAYS(结束日期, 开始日期)", "两个日期相差几天。", "=DAYS(\"2026-12-31\", TODAY())", "离年底还有几天"),
        f("DATEDIF", "日期", "DATEDIF(开始日期, 结束日期, 单位)", "两个日期相差几年 / 几个月 / 几天。",
          "=DATEDIF(C2, TODAY(), \"Y\")", "开业满几年；单位 \"M\" 是月，\"D\" 是天",
          ["较早的日期", "较晚的日期", "\"Y\" 年、\"M\" 月、\"D\" 天"]),
        f("EDATE", "日期", "EDATE(日期, 加几个月)", "几个月之后（或之前，用负数）的同一天。", "=EDATE(C2, 3)", "C2 三个月后"),
        f("EOMONTH", "日期", "EOMONTH(日期, 加几个月)", "几个月后那个月的最后一天。", "=EOMONTH(C2, 0)", "C2 所在月的月底"),

        // 信息
        f("ISBLANK", "信息", "ISBLANK(值)", "是不是空格子。", "=ISBLANK(A2)", "A2 没填时为 TRUE"),
        f("ISNUMBER", "信息", "ISNUMBER(值)", "是不是数字。", "=ISNUMBER(SEARCH(\"店\", A2))", "常用来判断「包含某字」"),
        f("ISTEXT", "信息", "ISTEXT(值)", "是不是文字。", "=ISTEXT(D2)", "检查数字列里混进的文字"),
        f("ISERROR", "信息", "ISERROR(值)", "是不是错误值。", "=ISERROR(D2/E2)", "除数为 0 时为 TRUE"),
        f("ISNA", "信息", "ISNA(值)", "是不是 #N/A（查不到）。", "=ISNA(MATCH(A2, B:B, 0))", "A2 不在 B 列时为 TRUE"),
        f("ISEVEN", "信息", "ISEVEN(数值)", "是不是偶数。", "=ISEVEN(A2)", "偶数为 TRUE"),
        f("ISODD", "信息", "ISODD(数值)", "是不是奇数。", "=ISODD(A2)", "奇数为 TRUE"),
        f("NA", "信息", "NA()", "生成 #N/A，表示「暂无数据」。", "=IF(D2=\"\", NA(), D2)", "空值不参与图表"),
    ]
}
