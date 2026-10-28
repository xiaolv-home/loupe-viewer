import Foundation

public enum TokenKind: Int, Sendable, CaseIterable {
    case keyword, type, string, comment, number, key, function, preprocessor, tag, variable
    case inserted, deleted, heading, error, warning
}

public struct Token: Sendable {
    public var range: NSRange
    public var kind: TokenKind
}

/// Regex-driven single-pass tokenizer. Comments and strings are matched first by
/// alternation order, so keywords inside them are never coloured.
public final class SyntaxHighlighter: @unchecked Sendable {
    private let regex: NSRegularExpression
    private let groups: [(String, TokenKind)]
    public let language: String

    private static var cache: [String: SyntaxHighlighter] = [:]
    private static let cacheLock = NSLock()

    public static func forLanguage(_ lang: String) -> SyntaxHighlighter? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let h = cache[lang] { return h }
        guard let spec = LanguageSpec.spec(for: lang), let h = SyntaxHighlighter(language: lang, spec: spec) else { return nil }
        cache[lang] = h
        return h
    }

    init?(language: String, spec: LanguageSpec) {
        self.language = language
        var parts: [String] = []
        var groups: [(String, TokenKind)] = []
        for (i, rule) in spec.rules.enumerated() {
            let name = "g\(i)"
            parts.append("(?<\(name)>\(rule.pattern))")
            groups.append((name, rule.kind))
        }
        var opts: NSRegularExpression.Options = [.anchorsMatchLines]
        if spec.caseInsensitive { opts.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: parts.joined(separator: "|"), options: opts) else { return nil }
        self.regex = re
        self.groups = groups
    }

    /// Tokenizes `text`, polling `isCancelled` every few thousand matches.
    public func tokens(in text: String, range: NSRange? = nil, isCancelled: () -> Bool = { false }) -> [Token] {
        let ns = text as NSString
        let r = range ?? NSRange(location: 0, length: ns.length)
        var out: [Token] = []
        var count = 0
        var stop = false
        regex.enumerateMatches(in: text, options: [], range: r) { m, _, flag in
            guard let m else { return }
            count += 1
            if count % 4096 == 0 && isCancelled() { stop = true; flag.pointee = true; return }
            for (name, kind) in groups {
                let gr = m.range(withName: name)
                if gr.location != NSNotFound && gr.length > 0 {
                    out.append(Token(range: gr, kind: kind))
                    break
                }
            }
        }
        return stop ? [] : out
    }
}

struct Rule {
    var pattern: String
    var kind: TokenKind
}

struct LanguageSpec {
    var rules: [Rule]
    var caseInsensitive = false

    static func words(_ list: String) -> String {
        "\\b(?:" + list.split(separator: " ").joined(separator: "|") + ")\\b"
    }

    static let dq = #""(?:[^"\\\n]|\\.)*""#
    static let sq = #"'(?:[^'\\\n]|\\.)*'"#
    static let bq = #"`(?:[^`\\]|\\.)*`"#
    static let num = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)[a-zA-Z]*\b"#
    static let cBlock = #"/\*[\s\S]*?(?:\*/|\z)"#
    static let slashLine = #"//[^\n]*"#
    static let hashLine = #"#[^\n]*"#
    static let typeName = #"\b[A-Z][A-Za-z0-9_]*\b"#
    static let call = #"\b[a-zA-Z_][A-Za-z0-9_]*(?=\s*\()"#

    static func cFamily(_ kw: String, types: String = "", extra: [Rule] = [], strings: [String] = [dq, sq]) -> LanguageSpec {
        var r: [Rule] = [Rule(pattern: cBlock, kind: .comment), Rule(pattern: slashLine, kind: .comment)]
        r += strings.map { Rule(pattern: $0, kind: .string) }
        r += extra
        r.append(Rule(pattern: words(kw), kind: .keyword))
        if !types.isEmpty { r.append(Rule(pattern: words(types), kind: .type)) }
        r.append(Rule(pattern: num, kind: .number))
        r.append(Rule(pattern: typeName, kind: .type))
        r.append(Rule(pattern: call, kind: .function))
        return LanguageSpec(rules: r)
    }

    static func spec(for lang: String) -> LanguageSpec? {
        switch lang {
        case "swift":
            return cFamily("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as Any false is nil self Self super throws true try await async actor some any nonisolated isolated mutating nonmutating override final lazy weak unowned convenience required dynamic indirect optional get set willSet didSet consuming borrowing sending macro package",
                           extra: [Rule(pattern: #""""[\s\S]*?(?:"""|\z)"#, kind: .string), Rule(pattern: #"@\w+"#, kind: .preprocessor), Rule(pattern: #"#\w+"#, kind: .preprocessor)],
                           strings: [#""""[\s\S]*?(?:"""|\z)"#, dq])
        case "c", "cpp", "objc":
            return cFamily("auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false nullptr class namespace template typename public private protected virtual override final new delete this throw try catch using operator friend explicit constexpr noexcept static_cast dynamic_cast reinterpret_cast const_cast decltype mutable concept requires co_await co_return co_yield id self super nil YES NO BOOL instancetype",
                           extra: [Rule(pattern: #"^\s*#\s*\w+[^\n]*"#, kind: .preprocessor), Rule(pattern: #"@\w+"#, kind: .preprocessor)])
        case "java", "kotlin", "scala", "dart", "csharp":
            return cFamily("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null var val fun when object companion data sealed override open internal lateinit suspend in is as typealias inline reified yield async await late required extension mixin def trait match implicit lazy sealed using namespace readonly ref out params struct get set record let",
                           extra: [Rule(pattern: #""""[\s\S]*?(?:"""|\z)"#, kind: .string), Rule(pattern: #"@\w+"#, kind: .preprocessor)],
                           strings: [#""""[\s\S]*?(?:"""|\z)"#, dq, sq])
        case "javascript", "typescript":
            return cFamily("break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof new return super switch this throw try typeof var void while with yield let static async await of get set true false null undefined NaN Infinity enum implements interface package private protected public type namespace declare abstract readonly keyof infer as is satisfies any unknown never string number boolean symbol bigint object from",
                           extra: [Rule(pattern: #"/(?![*/])(?:[^/\\\n\[]|\\.|\[(?:[^\]\\\n]|\\.)*\])+/[gimsuyd]*(?=\s*[.,;)\]}]|\s*$)"#, kind: .string), Rule(pattern: #"@\w+"#, kind: .preprocessor)],
                           strings: [bq, dq, sq])
        case "go":
            return cFamily("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota",
                           types: "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any comparable",
                           strings: [bq, dq, sq])
        case "rust":
            return cFamily("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while yield union macro_rules",
                           types: "i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box Some None Ok Err",
                           extra: [Rule(pattern: #"#!?\[[^\]\n]*\]"#, kind: .preprocessor), Rule(pattern: #"\b\w+!"#, kind: .function), Rule(pattern: #"'[a-z_]\w*\b(?!')"#, kind: .variable)],
                           strings: [##"r#*"[\s\S]*?"#*"##, dq, #"'(?:[^'\\\n]|\\.){1,10}'"#])
        case "php":
            return cFamily("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield true false null",
                           extra: [Rule(pattern: hashLine, kind: .comment), Rule(pattern: #"\$\w+"#, kind: .variable)])
        case "python":
            return LanguageSpec(rules: [
                Rule(pattern: hashLine, kind: .comment),
                Rule(pattern: #"(?:[rRbBuUfF]{0,2})(?:"""[\s\S]*?(?:"""|\z)|'''[\s\S]*?(?:'''|\z))"#, kind: .string),
                Rule(pattern: #"(?:[rRbBuUfF]{0,2})(?:"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')"#, kind: .string),
                Rule(pattern: #"^\s*@[\w.]+"#, kind: .preprocessor),
                Rule(pattern: words("False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self cls print"), kind: .keyword),
                Rule(pattern: words("int float str bool list dict set tuple bytes object type range len super isinstance Exception ValueError TypeError KeyError"), kind: .type),
                Rule(pattern: num, kind: .number),
                Rule(pattern: typeName, kind: .type),
                Rule(pattern: call, kind: .function)
            ])
        case "ruby", "perl", "r", "elixir", "julia", "nim", "lua":
            let kw = "BEGIN END alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require require_relative attr_accessor attr_reader puts my our sub use local function elseif repeat goto foreach last unless library TRUE FALSE NULL NA Inf defmodule defp fn import alias quote unquote struct mutable abstract type proc let var const iterator"
            var r: [Rule] = []
            if lang == "lua" { r.append(Rule(pattern: #"--\[\[[\s\S]*?(?:\]\]|\z)"#, kind: .comment)); r.append(Rule(pattern: #"--[^\n]*"#, kind: .comment)) }
            else { r.append(Rule(pattern: hashLine, kind: .comment)) }
            r += [Rule(pattern: dq, kind: .string), Rule(pattern: sq, kind: .string),
                  Rule(pattern: #"[@$%][\w]+"#, kind: .variable), Rule(pattern: #":[a-zA-Z_]\w*"#, kind: .string),
                  Rule(pattern: words(kw), kind: .keyword), Rule(pattern: num, kind: .number),
                  Rule(pattern: typeName, kind: .type), Rule(pattern: call, kind: .function)]
            return LanguageSpec(rules: r)
        case "shell", "dockerfile", "makefile", "powershell", "batch", "cmake", "terraform", "vim":
            var kw = "if then else elif fi for while until do done case esac in function return local export readonly declare unset shift exit source alias set eval exec trap break continue select time echo printf cd test true false"
            if lang == "dockerfile" { kw += " FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS" }
            if lang == "makefile" { kw += " ifeq ifneq ifdef ifndef endif include define endef override PHONY" }
            if lang == "powershell" { kw += " param begin process end foreach switch try catch finally throw Write-Host" }
            if lang == "batch" { kw += " goto call setlocal endlocal rem pause errorlevel exist not" }
            var rules: [Rule] = [Rule(pattern: hashLine.replacingOccurrences(of: "#", with: "(?<![$\\w{])#"), kind: .comment)]
            if lang == "batch" { rules = [Rule(pattern: #"(?i)^\s*(?:rem\b|::)[^\n]*"#, kind: .comment)] }
            if lang == "vim" { rules = [Rule(pattern: #"^\s*"[^\n]*"#, kind: .comment)] }
            rules += [Rule(pattern: dq, kind: .string), Rule(pattern: sq, kind: .string),
                      Rule(pattern: #"\$\{[^}\n]*\}|\$\(?[\w@#?*!$-]+\)?|%\w+%"#, kind: .variable),
                      Rule(pattern: #"(?<=\s|^)--?[a-zA-Z][\w-]*"#, kind: .key),
                      Rule(pattern: words(kw), kind: .keyword), Rule(pattern: num, kind: .number)]
            if lang == "makefile" { rules.insert(Rule(pattern: #"^[\w.%/-]+(?=\s*:(?!=))"#, kind: .function), at: 1) }
            return LanguageSpec(rules: rules, caseInsensitive: lang == "batch" || lang == "powershell")
        case "sql":
            return LanguageSpec(rules: [
                Rule(pattern: #"--[^\n]*"#, kind: .comment), Rule(pattern: cBlock, kind: .comment),
                Rule(pattern: sq, kind: .string), Rule(pattern: dq, kind: .key), Rule(pattern: bq, kind: .key),
                Rule(pattern: words("select from where and or not insert into values update set delete create table view index drop alter add column primary key foreign references join inner left right full outer cross on as group by order having limit offset union all distinct case when then else end is null in exists between like ilike asc desc with recursive returning begin commit rollback transaction grant revoke truncate partition over window cast if replace function procedure trigger declare return returns language database schema use show describe explain analyze default constraint unique check cascade lateral interval true false"), kind: .keyword),
                Rule(pattern: words("int integer bigint smallint tinyint decimal numeric float double real varchar char text date time timestamp datetime boolean bool json jsonb blob clob uuid serial number varchar2 nvarchar"), kind: .type),
                Rule(pattern: num, kind: .number), Rule(pattern: call, kind: .function),
                Rule(pattern: #"[:@]\w+"#, kind: .variable)
            ], caseInsensitive: true)
        case "json":
            return LanguageSpec(rules: [
                Rule(pattern: slashLine, kind: .comment), Rule(pattern: cBlock, kind: .comment),
                Rule(pattern: #""(?:[^"\\\n]|\\.)*"(?=\s*:)"#, kind: .key),
                Rule(pattern: dq, kind: .string),
                Rule(pattern: words("true false null"), kind: .keyword),
                Rule(pattern: #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, kind: .number)
            ])
        case "yaml":
            return LanguageSpec(rules: [
                Rule(pattern: #"(?<![^\s])#[^\n]*"#, kind: .comment),
                Rule(pattern: #"^---|^\.\.\."#, kind: .preprocessor),
                Rule(pattern: #"^\s*(?:-\s+)?[^\s#:"'\-][^\n:#]*?(?=\s*:(?:\s|$))"#, kind: .key),
                Rule(pattern: dq, kind: .string), Rule(pattern: sq, kind: .string),
                Rule(pattern: #"[&*][\w-]+|![\w!]+"#, kind: .variable),
                Rule(pattern: words("true false null yes no on off True False Null ~"), kind: .keyword),
                Rule(pattern: #"(?<=:\s|-\s)-?\d+(?:\.\d+)?\b"#, kind: .number)
            ])
        case "toml", "ini":
            return LanguageSpec(rules: [
                Rule(pattern: #"^\s*[#;][^\n]*"#, kind: .comment),
                Rule(pattern: #"(?<=\s)#[^\n]*"#, kind: .comment),
                Rule(pattern: #"^\s*\[\[?[^\]\n]*\]\]?"#, kind: .heading),
                Rule(pattern: #"^\s*[\w.\-"' ]+?(?=\s*[=:])"#, kind: .key),
                Rule(pattern: #""""[\s\S]*?(?:"""|\z)"#, kind: .string),
                Rule(pattern: dq, kind: .string), Rule(pattern: sq, kind: .string),
                Rule(pattern: words("true false yes no on off"), kind: .keyword),
                Rule(pattern: #"\$\{[^}\n]*\}"#, kind: .variable),
                Rule(pattern: num, kind: .number)
            ], caseInsensitive: false)
        case "xml", "html":
            return LanguageSpec(rules: [
                Rule(pattern: #"<!--[\s\S]*?(?:-->|\z)"#, kind: .comment),
                Rule(pattern: #"<!\[CDATA\[[\s\S]*?(?:\]\]>|\z)"#, kind: .string),
                Rule(pattern: #"<[?!][^>\n]*>?"#, kind: .preprocessor),
                Rule(pattern: #"</?[A-Za-z][\w:.\-]*|/?>"#, kind: .tag),
                Rule(pattern: #"(?<=\s)[A-Za-z_:@][\w:.\-]*(?=\s*=)"#, kind: .key),
                Rule(pattern: dq, kind: .string), Rule(pattern: sq, kind: .string),
                Rule(pattern: #"&[#\w]+;"#, kind: .variable),
                Rule(pattern: #"\{\{[^}\n]*\}\}"#, kind: .variable)
            ])
        case "css":
            return LanguageSpec(rules: [
                Rule(pattern: cBlock, kind: .comment), Rule(pattern: slashLine.replacingOccurrences(of: "//", with: "(?<!:)//"), kind: .comment),
                Rule(pattern: dq, kind: .string), Rule(pattern: sq, kind: .string),
                Rule(pattern: #"@[\w-]+"#, kind: .preprocessor),
                Rule(pattern: #"[\w-]+(?=\s*:[^{};\n]*[;}\n])"#, kind: .key),
                Rule(pattern: #"#[0-9a-fA-F]{3,8}\b"#, kind: .number),
                Rule(pattern: #"-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg|fr|pt|ch)?\b"#, kind: .number),
                Rule(pattern: #"\$[\w-]+|--[\w-]+"#, kind: .variable),
                Rule(pattern: #"[.#][A-Za-z_][\w-]*"#, kind: .type),
                Rule(pattern: words("important inherit initial unset none auto"), kind: .keyword),
                Rule(pattern: call, kind: .function)
            ])
        case "diff":
            return LanguageSpec(rules: [
                Rule(pattern: #"^(?:diff|index|---|\+\+\+)[^\n]*"#, kind: .heading),
                Rule(pattern: #"^@@[^\n]*"#, kind: .type),
                Rule(pattern: #"^\+[^\n]*"#, kind: .inserted),
                Rule(pattern: #"^-[^\n]*"#, kind: .deleted)
            ])
        case "log":
            return LanguageSpec(rules: [
                Rule(pattern: #"\b(?:FATAL|ERROR|ERR|CRITICAL|CRIT|PANIC|SEVERE|EXCEPTION|Exception|Traceback|failed|FAILED)\b"#, kind: .error),
                Rule(pattern: #"\b(?:WARN|WARNING|Warning)\b"#, kind: .warning),
                Rule(pattern: #"\b(?:INFO|NOTICE)\b"#, kind: .keyword),
                Rule(pattern: #"\b(?:DEBUG|TRACE|VERBOSE)\b"#, kind: .comment),
                Rule(pattern: #"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?|\b\d{2}:\d{2}:\d{2}(?:\.\d+)?\b"#, kind: .number),
                Rule(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b"#, kind: .variable),
                Rule(pattern: #"https?://[^\s"'<>]+"#, kind: .string),
                Rule(pattern: dq, kind: .string)
            ])
        case "markdown":
            return LanguageSpec(rules: [
                Rule(pattern: #"^```[\s\S]*?(?:^```|\z)"#, kind: .string),
                Rule(pattern: #"`[^`\n]+`"#, kind: .string),
                Rule(pattern: #"^#{1,6}\s[^\n]*"#, kind: .heading),
                Rule(pattern: #"^\s*(?:[-*+]|\d+\.)\s(?:\[[ xX]\]\s)?"#, kind: .keyword),
                Rule(pattern: #"^>[^\n]*"#, kind: .comment),
                Rule(pattern: #"!?\[[^\]\n]*\]\([^)\n]*\)"#, kind: .type),
                Rule(pattern: #"\*\*[^*\n]+\*\*|__[^_\n]+__"#, kind: .key),
                Rule(pattern: #"\$\$[\s\S]*?\$\$|\$[^$\n]+\$"#, kind: .variable),
                Rule(pattern: #"<!--[\s\S]*?(?:-->|\z)"#, kind: .comment)
            ])
        case "haskell", "clojure", "tex", "protobuf", "graphql", "zig", "asm":
            var rules: [Rule] = []
            switch lang {
            case "haskell": rules = [Rule(pattern: #"\{-[\s\S]*?(?:-\}|\z)"#, kind: .comment), Rule(pattern: #"--[^\n]*"#, kind: .comment)]
            case "clojure", "asm": rules = [Rule(pattern: #";[^\n]*"#, kind: .comment)]
            case "tex": rules = [Rule(pattern: #"(?<!\\)%[^\n]*"#, kind: .comment), Rule(pattern: #"\\[A-Za-z@]+"#, kind: .keyword), Rule(pattern: #"\$[^$\n]*\$"#, kind: .string)]
            case "graphql": rules = [Rule(pattern: hashLine, kind: .comment)]
            default: rules = [Rule(pattern: slashLine, kind: .comment), Rule(pattern: cBlock, kind: .comment)]
            }
            rules += [Rule(pattern: dq, kind: .string),
                      Rule(pattern: words("module where import data type class instance let in case of if then else do deriving newtype defn def ns require fn loop recur message service rpc returns enum oneof repeated optional syntax package option query mutation subscription fragment on schema input interface union scalar extend const var pub fn struct comptime try return mov push pop call ret jmp"), kind: .keyword),
                      Rule(pattern: num, kind: .number), Rule(pattern: typeName, kind: .type)]
            return LanguageSpec(rules: rules)
        default:
            return nil
        }
    }
}
