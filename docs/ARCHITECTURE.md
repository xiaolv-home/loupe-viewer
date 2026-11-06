# 架构

Loupe 是一个不联网优先的 macOS 文件查看器：打开一个文件，挑一个合适的渲染器显示它。这份文档讲代码怎么分层、为什么这样分。分层规则由 `scripts/check-architecture.py` 执行，CI 里违反就失败，所以这里写的都是真实状态。

## 三个目标

```
Sources/Loupe        入口，只有一行：LoupeApplication.run()
Sources/LoupeApp     应用：窗口、渲染器、AI 面板（依赖 AppKit / SwiftUI / WebKit）
Sources/LoupeCore    纯逻辑：格式识别、表格、公式、AI 协议（不依赖任何界面框架）
```

把应用放进库而不是可执行目标，是为了让 `Tests/LoupeAppTests` 能 `@testable import`。

## LoupeApp 的分层

依赖只能朝下，不能反过来：

```
App, Shell      窗口、菜单、标签页、版口（知道一切）
AI/UI           AI 面板
AI, AI/Tools    会话和工具（只通过协议接触窗口与文档）
Renderers       每种文件怎么显示（不知道窗口是谁）
Services        跨渲染器的服务（导出、草稿）
DesignSystem    配色和通用控件
Base            设置、日志
```

外壳和渲染器之间、AI 和外壳之间只通过协议说话：

| 协议 | 定义在 | 作用 |
|---|---|---|
| `Renderer` | Renderers | 外壳需要从渲染器知道的一切：视图、状态、命令、降级说明、AI 建议 |
| `RenderHost` | Renderers | 渲染器需要窗口做的事：进度、横幅、降级、打开文件 |
| `FormatCommandHandling` | Renderers | 能接受「格式」菜单命令的文档 |
| `AppActions` | Renderers | 经响应链发送的应用级动作，视图不用认识 `AppDelegate` |
| `AIDocumentTools` | AI/Tools | 渲染器给 AI 提供的专属工具 |
| `AIWorkspace`, `AIDocument` | AI/Tools | AI 需要窗口和文档做的事 |

只有 `RendererRegistry` 能点名具体的渲染器。需要在外壳里判断「它是不是表格」时，正确的做法是给 `Renderer` 加一项能力，让它自己回答。

`AI/UI` 还会读 `TabList` 来知道当前标签页，所以它算外壳的一部分，不算 AI 内核。

## LoupeCore 的分层

```
AI                               模型接口、工具循环、技能
Spreadsheet, Formula,            表格引擎：这四个互相引用，算一个整体
  Drawing, Chart
Text, Archive                    CSV、高亮、JSON、压缩包
Detection                        格式与编码识别
Support, Security                零散工具、路径边界（不依赖任何人）
```

这些是同一个模块里的文件夹，不是独立模块：表格引擎的循环里到处是跨文件的调用，拆成模块要把内部类型全部公开，还会失去跨模块优化。边界由架构检查保证。

## 打开一个文件时发生了什么

1. `ViewerModel` 在后台建 `FileContext`（读文件头、识别格式）。
2. `RendererRegistry.chain(for:)` 给出按顺序尝试的渲染器，比如 Markdown → 纯文本 → 十六进制。
3. 依次尝试 `makeView`。失败就换下一个，并记下原因。
4. 接手的渲染器用 `fallbackNote` 说明自己为什么在这里；如果显示的是损坏文件的原始内容，还会弹横幅。

渲染器是一次性的：一个文件一个实例，换文件时调用 `cleanup()`。

## 网页内容

Markdown、HTML 走 WKWebView。所有资源经 `loupe://` 协议提供（`loupe://app/` 是应用自带的，`loupe://file/` 是用户文件），外网请求一律被内容规则拦截。写作模式基于 Vditor，`writer.js` 不往编辑器 DOM 里加东西，专注模式、查找高亮和下划线都用样式规则或 CSS Highlight API，否则可能被写进文件。

## 调试代码

`AppAutomation` 的 `--probe` 留在正式版里，CI 用它检查打包好的应用。截图、脚本化操作和所有 `debug*` 钩子都在 `#if DEBUG` 里，不会进正式包。

## 怎么加一种新格式

1. 在 `Renderers/` 下写一个实现 `Renderer` 的类。
2. 在 `RendererRegistry.chain(for:)` 里排好它的位置，并在 `RendererRegistryTests` 里写明。
3. 在 `fixtures/` 放一个样例，并加进 `scripts/verify-renderers.py`。
4. 需要外壳配合时加协议能力，不要让外壳判断类型。
