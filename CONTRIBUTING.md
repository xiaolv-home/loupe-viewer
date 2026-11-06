# 参与开发

只需要 Command Line Tools，不需要完整 Xcode。

## 常用命令

```bash
scripts/build-app.sh debug      # 只编译本机架构，最快
```

```bash
scripts/check.sh                # 提交前跑这个：格式、架构、单元测试、构建、端到端
```

```bash
scripts/lint.sh --fix           # 按 .swift-format 整理格式
```

重构前后想确认界面没变：

```bash
scripts/visual-check.py baseline   # 改之前
```

```bash
scripts/check.sh --visual          # 改之后
```

## 规范

- **分层**：看 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。违反分层规则或文件超过 600 行，架构检查会失败。
- **测试**：纯逻辑放 `LoupeCore`，测试写在 `LoupeCoreTests`；渲染器选择、协议行为这类写在 `LoupeAppTests`。用 Swift Testing，因为 XCTest 只随完整 Xcode 提供。
- **注释**：写为什么，不写做了什么。
- **界面文字**：说人话，不出现引擎名（PDFKit、Hex）。
- **设计**：「校样」风格：纸张、裁切标记、一种专色，不加循环动画。

## 提交

- 信息用中文，格式是「模块：说明」，例如 `表格：原文件隐藏的工作表默认也隐藏`。正文写为什么。
- 直接推 `main`，不开 PR。推送后 CI 会跑测试、打包和端到端检查。

## 发布

1. 改 `Sources/LoupeApp/Info.plist` 的版本号。
2. 把 `CHANGELOG.md` 的「未发布」挪到新版本下，并写 `docs/releases/v<版本>.md`。
3. 打标签 `v<版本>` 并推送，CI 会建 Release（标签和版本号不一致会失败）。

## 隐私

测试和截图只用 `fixtures/` 里的样例。调试参数不写入「最近打开」、侧栏位置和窗口布局。
