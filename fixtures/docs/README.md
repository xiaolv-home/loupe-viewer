# Loupe 示例文档

这是一段 **Markdown**，包含 *斜体*、`行内代码` 与 [链接](https://example.com)。

## 表格

| 格式 | 渲染器 | 状态 |
|:-----|:------:|-----:|
| PDF | PDFKit | ✅ |
| 图片 | ImageIO | ✅ |

## 任务列表

- [x] 支持表格
- [x] 支持任务列表
- [ ] 支持魔法

## 公式

行内公式 $E = mc^2$，以及块级公式：

$$
\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
$$

## 代码

```swift
struct Greeting {
    let text = "你好"
    func say() { print(text) }
}
```

## 图表

```mermaid
graph LR
  A[打开文件] --> B{识别格式}
  B -->|PDF| C[PDFKit]
  B -->|图片| D[ImageIO]
  B -->|未知| E[十六进制]
```

> 引用：文档中的脚本不会被执行。

<img src="https://example.com/remote.png" alt="远程图片（应被拦截）">
<script>document.body.innerHTML = "脚本被执行了！"</script>

![本地图片](../images/photo.jpg)
