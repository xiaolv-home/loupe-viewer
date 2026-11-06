// Markdown → sanitised HTML with tables, task lists, footnotes, KaTeX and Mermaid.
// Runs inside Loupe's WKWebView; all assets come from loupe://app, the network is blocked.
(function () {
  "use strict";

  function mathPlugin(md) {
    // $$…$$ blocks
    md.block.ruler.after("blockquote", "math_block", function (state, start, end, silent) {
      let pos = state.bMarks[start] + state.tShift[start];
      let max = state.eMarks[start];
      if (pos + 2 > max || state.src.slice(pos, pos + 2) !== "$$") return false;
      if (silent) return true;
      let first = state.src.slice(pos + 2, max);
      let content = "";
      let line = start;
      let found = false;
      if (first.trim().endsWith("$$") && first.trim().length > 2) {
        content = first.trim().slice(0, -2);
        found = true;
      } else {
        content = first + "\n";
        while (++line < end) {
          let s = state.src.slice(state.bMarks[line] + state.tShift[line], state.eMarks[line]);
          if (s.trim().endsWith("$$")) { content += s.trim().slice(0, -2); found = true; break; }
          content += s + "\n";
        }
      }
      if (!found) return false;
      state.line = line + 1;
      let token = state.push("math_block", "math", 0);
      token.content = content;
      token.map = [start, state.line];
      return true;
    }, { alt: ["paragraph", "reference", "blockquote", "list"] });

    // $…$ inline (not "$ " and not escaped)
    md.inline.ruler.after("escape", "math_inline", function (state, silent) {
      let src = state.src, pos = state.pos;
      if (src[pos] !== "$" || src[pos + 1] === "$" || src[pos + 1] === " ") return false;
      let end = pos + 1;
      while ((end = src.indexOf("$", end)) !== -1) {
        if (src[end - 1] !== "\\" && src[end - 1] !== " ") break;
        end++;
      }
      if (end === -1 || end === pos + 1) return false;
      if (!silent) {
        let token = state.push("math_inline", "math", 0);
        token.content = src.slice(pos + 1, end);
      }
      state.pos = end + 1;
      return true;
    });

    function render(tex, display) {
      // KaTeX is loaded only when a document has math; until it arrives the formula shows
      // as code, and the page renders again once it is ready.
      if (!window.katex) { needsMath = true; return "<code>" + md.utils.escapeHtml(tex) + "</code>"; }
      try { return katex.renderToString(tex, { displayMode: display, throwOnError: false, output: "html" }); }
      catch (e) { return '<span class="math-error">' + md.utils.escapeHtml(String(e.message || e)) + "</span>"; }
    }
    md.renderer.rules.math_inline = (t, i) => render(t[i].content, false);
    md.renderer.rules.math_block = (t, i) => '<div class="katex-display">' + render(t[i].content, true) + "</div>\n";
  }

  const md = window.markdownit({
    html: true,
    linkify: true,
    typographer: true,
    highlight: function (code, lang) {
      if (lang === "mermaid") return "";
      try {
        if (lang && hljs.getLanguage(lang)) return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
        if (code.length < 20000) return hljs.highlightAuto(code).value;
      } catch (e) {}
      return md.utils.escapeHtml(code);
    }
  })
    .use(window.markdownitFootnote)
    .use(window.markdownitTaskLists, { enabled: false, label: true })
    .use(mathPlugin);

  // Mermaid fences become placeholders rendered after sanitising.
  const defaultFence = md.renderer.rules.fence;
  md.renderer.rules.fence = function (tokens, idx, opts, env, self) {
    const t = tokens[idx];
    const lang = (t.info || "").trim().split(/\s+/)[0];
    if (lang === "mermaid") {
      env.mermaid = (env.mermaid || 0) + 1;
      return '<div class="mermaid" data-src="' + encodeURIComponent(t.content) + '"></div>\n';
    }
    const html = defaultFence(tokens, idx, opts, env, self);
    return lang ? html.replace("<pre>", '<pre data-lang="' + md.utils.escapeHtml(lang) + '">') : html;
  };

  let needsMath = false;
  let katexLoaded = null;
  function loadKatex() {
    if (katexLoaded) return katexLoaded;
    katexLoaded = new Promise(function (resolve, reject) {
      const s = document.createElement("script");
      s.src = "loupe://app/vendor/katex/katex.min.js";
      s.onload = resolve;
      s.onerror = reject;
      document.head.appendChild(s);
    });
    return katexLoaded;
  }

  let mermaidLoaded = null;
  function loadMermaid() {
    if (mermaidLoaded) return mermaidLoaded;
    mermaidLoaded = new Promise(function (resolve, reject) {
      const s = document.createElement("script");
      s.src = "loupe://app/vendor/mermaid.min.js";
      s.onload = resolve;
      s.onerror = reject;
      document.head.appendChild(s);
    });
    return mermaidLoaded;
  }

  function dark() { return window.matchMedia("(prefers-color-scheme: dark)").matches; }

  async function renderMermaid() {
    const nodes = Array.from(document.querySelectorAll(".mermaid[data-src]"));
    if (!nodes.length) return;
    try { await loadMermaid(); } catch (e) { return; }
    const d = dark();
    window.mermaid.initialize({
      startOnLoad: false, securityLevel: "strict", theme: "base",
      fontFamily: "-apple-system, PingFang SC, sans-serif",
      themeVariables: {
        background: "transparent",
        primaryColor: d ? "#2B2C31" : "#FFFFFF",
        primaryBorderColor: d ? "#FF6A3D" : "#D9481C",
        primaryTextColor: d ? "#E9E5DD" : "#1E1D1B",
        lineColor: d ? "rgba(233,229,221,.55)" : "rgba(30,29,27,.55)",
        secondaryColor: d ? "#232428" : "#F4F1EA",
        tertiaryColor: d ? "#232428" : "#F4F1EA",
        fontSize: "14px"
      }
    });
    let i = 0;
    for (const n of nodes) {
      const src = decodeURIComponent(n.getAttribute("data-src"));
      try {
        const { svg } = await window.mermaid.render("mmd" + (i++) + "_" + Date.now(), src);
        n.innerHTML = svg;
      } catch (e) {
        n.innerHTML = '<div class="mermaid-error"></div>';
        n.firstChild.textContent = "Mermaid 图表解析失败：" + (e.message || e);
      }
    }
  }

  let lastSource = "";
  window.loupeRender = function (source) {
    lastSource = source;
    needsMath = false;
    const html = md.render(source, {});
    if (needsMath) loadKatex().then(function () { window.loupeRender(lastSource); }, function () {});
    const clean = DOMPurify.sanitize(html, {
      ADD_ATTR: ["data-src", "data-lang", "target"],
      FORBID_TAGS: ["style", "form", "iframe", "object", "embed"],
      ALLOWED_URI_REGEXP: /^(?:(?:loupe|https?|mailto|data):|[^a-z]|[a-z+.-]+(?:[^a-z+.\-:]|$))/i
    });
    const doc = document.getElementById("doc");
    doc.innerHTML = clean;
    // Remote images are never fetched; show a quiet placeholder instead.
    doc.querySelectorAll("img").forEach(function (img) {
      const src = img.getAttribute("src") || "";
      if (/^https?:/i.test(src)) {
        const span = document.createElement("span");
        span.className = "blocked";
        span.textContent = "已阻止远程图片 · " + (img.getAttribute("alt") || src);
        img.replaceWith(span);
      }
    });
    renderMermaid();
    return doc.innerText.length;
  };

  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function () {
    if (document.querySelector(".mermaid")) window.loupeRender(lastSource);
  });
})();
