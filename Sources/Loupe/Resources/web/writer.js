// Loupe's Markdown writer: Vditor in instant-render mode (Typora-style: the text is laid out as
// you type, the Markdown marks show only where the caret is), with Typora's shortcuts, images
// pasted into ./assets, and a small bridge to the app. Everything is local; nothing loads from
// the network.
(function () {
  "use strict";
  const BASE = "loupe://app/vditor";
  const bridge = window.webkit.messageHandlers.writer;
  let editor = null;
  let mode = "ir";
  let changeTimer = null;

  const post = (m) => bridge.postMessage(m);
  const dark = () => window.matchMedia("(prefers-color-scheme: dark)").matches;

  let lastSent = null;
  function scheduleChange() {
    clearTimeout(changeTimer);
    changeTimer = setTimeout(() => {
      const v = editor.getValue();
      if (v !== lastSent) { lastSent = v; post({ type: "change", markdown: v }); }
    }, 120);
  }

  function applyTheme() {
    if (!editor) return;
    const d = dark();
    editor.setTheme(d ? "dark" : "classic", d ? "dark" : "light", d ? "github-dark" : "github",
                    BASE + "/dist/css/content-theme");
  }
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", applyTheme);

  // Pasted or dropped pictures are saved by the app next to the document (./assets/…), then
  // linked with a relative path, the way Typora does by default.
  async function upload(files) {
    for (const file of files) {
      if (!file.type.startsWith("image/")) continue;
      const data = await new Promise((resolve) => {
        const r = new FileReader();
        r.onload = () => resolve(String(r.result).split(",")[1] || "");
        r.readAsDataURL(file);
      });
      const path = await bridge.postMessage({ type: "image", name: file.name || "image.png", data });
      if (path) editor.insertValue(`![${file.name ? file.name.replace(/\.[^.]+$/, "") : ""}](${encodeURI(path)})`);
    }
    scheduleChange();
    return null;
  }

  function create(markdown, m, outline) {
    if (editor) editor.destroy();
    mode = m;
    editor = new Vditor("vditor", {
      value: markdown,
      mode: m,
      cdn: BASE,
      lang: "zh_CN",
      icon: "ant",
      height: "100%",
      cache: { enable: false },
      placeholder: "开始写作…",
      // The toolbar stays hidden (Typora has none); its buttons carry the commands and shortcuts.
      toolbar: ["headings", "bold", "italic", "strike", "link", "list", "ordered-list", "check", "outdent", "indent",
                "quote", "line", "code", "inline-code", "table", "outline", "undo", "redo"],
      toolbarConfig: { hide: true, pin: false },
      outline: { enable: !!outline, position: "left" },
      counter: { enable: false },
      tab: "    ",
      preview: {
        mode: "editor",
        delay: 300,
        hljs: { style: dark() ? "github-dark" : "github", lineNumber: false },
        math: { engine: "KaTeX", inlineDigit: true },
        markdown: { toc: true, mark: true, footnotes: true, autoSpace: false, sanitize: true, codeBlockPreview: true, mathBlockPreview: true },
        theme: { current: dark() ? "dark" : "light", path: BASE + "/dist/css/content-theme" }
      },
      upload: { accept: "image/*", handler: upload },
      link: { isOpen: false, click: (el) => post({ type: "link", href: el.getAttribute("href") || el.textContent }) },
      input: scheduleChange,
      after: () => {
        applyTheme();
        caretToStart();
        post({ type: "ready", mode });
      }
    });
  }

  /// Opens at the top with the caret at the beginning (focusing alone would jump to the end).
  function caretToStart() {
    const el = area();
    if (!el) return;
    el.focus({ preventScroll: true });
    const r = document.createRange();
    r.setStart(el, 0);
    r.collapse(true);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
    el.scrollTop = 0;
    window.scrollTo(0, 0);
  }

  // MARK: Commands (Typora's menu and shortcuts)

  const vd = () => editor && editor.vditor;
  const area = () => vd() && vd()[mode] && vd()[mode].element;

  function click(name) {
    const el = vd() && vd().toolbar.elements[name];
    if (el) el.children[0].dispatchEvent(new CustomEvent("click"));
    scheduleChange();
  }

  function heading(level) {
    const target = area();
    if (!target) return;
    const e = new KeyboardEvent("keydown", { metaKey: true, altKey: true, code: "Digit" + level, key: String(level), bubbles: true, cancelable: true });
    e.loupeSynthetic = true;
    target.dispatchEvent(e);
    scheduleChange();
  }

  function paragraph() {
    const btn = vd() && vd().toolbar.elements.headings && vd().toolbar.elements.headings.children[0];
    if (btn && btn.classList.contains("vditor-menu--current")) btn.dispatchEvent(new CustomEvent("click"));
  }

  function wrap(before, after) {
    const sel = editor.getSelection();
    editor.updateValue(before + sel + after);
  }

  const commands = {
    h1: () => heading(1), h2: () => heading(2), h3: () => heading(3), h4: () => heading(4), h5: () => heading(5), h6: () => heading(6),
    paragraph,
    bold: () => click("bold"), italic: () => click("italic"), strike: () => click("strike"),
    underline: () => wrap("<u>", "</u>"), highlight: () => wrap("==", "=="),
    inlineCode: () => click("inline-code"), link: () => click("link"),
    image: () => editor.insertValue("![](" + ")"),
    codeBlock: () => click("code"), mathBlock: () => editor.insertValue("\n$$\n\n$$\n"),
    quote: () => click("quote"), orderedList: () => click("ordered-list"), bulletList: () => click("list"),
    taskList: () => click("check"), table: () => click("table"), rule: () => click("line"),
    indent: () => click("indent"), outdent: () => click("outdent"),
    outline: () => click("outline"), undo: () => click("undo"), redo: () => click("redo")
  };

  // Typora's shortcuts, caught before Vditor sees the keystroke. Vditor's own shortcuts that
  // clash with the app (⌘O open, ⌘J AI, ⌘L rotate…) are passed on to the app's menus.
  window.addEventListener("keydown", (e) => {
    if (e.loupeSynthetic || !editor) return;
    const cmd = e.metaKey, alt = e.altKey, shift = e.shiftKey, ctrl = e.ctrlKey, code = e.code;
    const run = (name) => { e.preventDefault(); e.stopImmediatePropagation(); commands[name](); };
    if (cmd && !alt && !ctrl && !shift) {
      const digit = /^Digit([0-6])$/.exec(code);
      if (digit) return run(digit[1] === "0" ? "paragraph" : "h" + digit[1]);
      if (code === "KeyU") return run("underline");
      if (code === "BracketRight") return run("indent");
      if (code === "BracketLeft") return run("outdent");
      if (code === "Slash") { e.preventDefault(); e.stopImmediatePropagation(); post({ type: "toggleSource" }); return; }
    }
    if (ctrl && !cmd && !alt && code === "Backquote") return run(shift ? "strike" : "inlineCode");
    if (cmd && ctrl && !alt && !shift && code === "KeyI") return run("image");
    if (cmd && ctrl && !alt && !shift && code === "Digit1") return run("outline");
    if (cmd && shift && !alt && !ctrl && code === "KeyH") return run("highlight");
    if (cmd && alt && !ctrl && !shift) {
      const map = { KeyC: "codeBlock", KeyB: "mathBlock", KeyQ: "quote", KeyO: "orderedList", KeyU: "bulletList",
                    KeyX: "taskList", KeyT: "table", Minus: "rule" };
      if (map[code]) return run(map[code]);
    }
    const vditorOnly = cmd && !alt && !ctrl && (
      (!shift && ["KeyO", "KeyL", "KeyJ", "KeyE", "KeyH", "KeyD", "KeyG", "KeyM", "KeyP", "Quote", "Semicolon"].includes(code)) ||
      (shift && ["KeyI", "KeyO", "KeyB", "KeyE", "KeyJ", "KeyF", "KeyG", "KeyL", "KeyC", "KeyR"].includes(code)));
    if (vditorOnly) e.stopImmediatePropagation();
  }, true);

  // Not every change goes through Vditor's input callback (toolbar actions, IME, cut, drops):
  // report after any keystroke, paste, cut or drop too. Reports are debounced and skipped when
  // the text did not change.
  for (const type of ["keyup", "paste", "cut", "drop", "compositionend"]) {
    document.addEventListener(type, () => { if (editor) scheduleChange(); }, true);
  }

  // MARK: The app's side

  window.loupeWriter = {
    load(markdown, m, outline) { create(markdown, m || "ir", outline); return true; },
    value() { return editor ? editor.getValue() : ""; },
    setValue(markdown) { if (editor) { editor.setValue(markdown, false); scheduleChange(); } return true; },
    setMode(m, outline) { const v = this.value(); create(v, m, outline); return true; },
    command(name) { if (commands[name]) { commands[name](); scheduleChange(); return true; } return false; },
    focus() { if (editor) editor.focus(); return true; },
    insert(markdown) { if (editor) { editor.insertValue(markdown); scheduleChange(); } return true; }
  };
  post({ type: "loaded" });
})();
