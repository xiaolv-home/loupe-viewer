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
    const was = vd().options.theme;
    editor.setTheme(d ? "dark" : "classic", d ? "dark" : "light", d ? "github-dark" : "github",
                    BASE + "/dist/css/content-theme");
    // Diagrams are drawn in the theme's colours, so a switch has to draw them again.
    vd().options.theme = d ? "dark" : "classic";
    if (was !== vd().options.theme && area() && area().querySelector(".language-mermaid")) editor.setValue(editor.getValue(), false);
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
      theme: dark() ? "dark" : "classic",
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
      input: () => { scheduleChange(); refreshMarks(); },
      after: () => {
        applyTheme();
        caretToStart();
        refreshMarks();
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
    image: () => post({ type: "pickImage" }),
    codeBlock: () => click("code"), mathBlock: () => editor.insertValue("\n$$\n\n$$\n"),
    quote: () => click("quote"), orderedList: () => click("ordered-list"), bulletList: () => click("list"),
    taskList: () => click("check"), table: () => click("table"), rule: () => click("line"),
    indent: () => click("indent"), outdent: () => click("outdent"),
    outline: () => click("outline"), undo: () => click("undo"), redo: () => click("redo"),
    selectLine: () => selectBy("lineboundary"), selectWord: () => selectBy("word"),
    clearFormat, moveUp: () => moveBlock(-1), moveDown: () => moveBlock(1), addTableRow
  };

  function selectBy(unit) {
    const sel = window.getSelection();
    sel.modify("move", "backward", unit);
    sel.modify("extend", "forward", unit);
  }

  /// Takes off whatever the caret or selection is inside of (⌘\\).
  function clearFormat() {
    for (const name of ["bold", "italic", "strike", "inline-code"]) {
      const el = vd() && vd().toolbar.elements[name];
      if (el && el.children[0].classList.contains("vditor-menu--current")) click(name);
    }
  }

  /// The caret's element, if the caret is in the document.
  function caretElement() {
    const sel = window.getSelection(), root = area();
    if (!sel.rangeCount || !root || !root.contains(sel.anchorNode)) return null;
    return sel.anchorNode.nodeType === 1 ? sel.anchorNode : sel.anchorNode.parentElement;
  }

  /// The paragraph, list item or table row the caret is in moves past its neighbour. The
  /// neighbour is what actually moves in the page, so the caret stays where it is.
  function moveBlock(direction) {
    const el = caretElement(), root = area();
    if (!el) return;
    let block = el.closest("tbody tr") || el.closest("li");
    if (!block) {
      block = el;
      while (block.parentElement && block.parentElement !== root) block = block.parentElement;
      if (block === root || block.parentElement !== root) return;
    }
    const other = direction < 0 ? block.previousElementSibling : block.nextElementSibling;
    if (!other) return;
    block.parentElement.insertBefore(other, direction < 0 ? block.nextSibling : block);
    vd().undo.addToUndoStack(vd());
    scheduleChange();
    refreshMarks();
  }

  /// ⌘↩ in a table: a new row (Vditor's own key for it is ⌘=, which zooms here).
  function addTableRow() {
    const el = caretElement();
    if (!el || !el.closest("td, th")) return false;
    const e = new KeyboardEvent("keydown", { metaKey: true, key: "=", code: "Equal", bubbles: true, cancelable: true });
    e.loupeSynthetic = true;
    area().dispatchEvent(e);
    scheduleChange();
    return true;
  }

  // MARK: Reading the page as it changes: focus, typewriter, outline, underlines, selection count

  const modes = { focus: false, typewriter: false };
  const modeStyle = document.head.appendChild(document.createElement("style"));
  const highlights = window.CSS && CSS.highlights;

  /// Styled from a rule rather than a class on the paragraph, so nothing can end up in the file.
  function refreshModes() {
    const root = area();
    let rule = modes.typewriter ? ".vditor-ir pre.vditor-reset { padding-bottom: 60vh !important; }" : "";
    if (modes.focus && root) {
      let block = caretElement();
      while (block && block.parentElement !== root) block = block.parentElement;
      if (block) {
        const n = Array.prototype.indexOf.call(root.children, block) + 1;
        rule += `.vditor-ir pre.vditor-reset > * { transition: opacity .15s; }
                 .vditor-ir pre.vditor-reset > :not(:nth-child(${n})) { opacity: .26; }`;
      }
    }
    if (modeStyle.textContent !== rule) modeStyle.textContent = rule;
  }

  function centreCaret() {
    const sel = window.getSelection(), root = area();
    if (!modes.typewriter || !root || !sel.rangeCount || !root.contains(sel.anchorNode)) return;
    const r = sel.getRangeAt(0).cloneRange();
    r.collapse(false);
    const rect = r.getClientRects()[0] || (caretElement() && caretElement().getBoundingClientRect());
    if (!rect) return;
    const box = root.getBoundingClientRect();
    root.scrollTop += rect.top - (box.top + box.height * 0.42);
  }

  /// The section being read shows in the outline.
  function refreshOutline() {
    const root = area(), outline = vd() && vd().outline && vd().outline.element;
    if (!root || !outline || !outline.offsetWidth) return;
    const line = root.getBoundingClientRect().top + 80;
    let current = null;
    for (const h of root.querySelectorAll(":scope > h1, :scope > h2, :scope > h3, :scope > h4, :scope > h5, :scope > h6")) {
      if (h.getBoundingClientRect().top > line) break;
      current = h;
    }
    for (const span of outline.querySelectorAll("li > span")) {
      span.classList.toggle("loupe-outline-current", !!current && span.getAttribute("data-target-id") === current.id);
    }
  }

  /// Inline <u> stays as text between two tags in the writer; this draws the line it asks for.
  function refreshUnderlines() {
    const root = area();
    if (!highlights || !root) return;
    const ranges = [];
    for (const open of root.querySelectorAll('[data-type="html-inline"]')) {
      if (open.textContent !== "<u>") continue;
      for (let n = open.nextSibling; n; n = n.nextSibling) {
        if (n.nodeType === 1 && n.getAttribute("data-type") === "html-inline" && n.textContent === "</u>") {
          const r = document.createRange();
          r.setStartAfter(open);
          r.setEndBefore(n);
          ranges.push(r);
          break;
        }
      }
    }
    highlights.set("loupe-underline", new Highlight(...ranges));
  }

  let marksFrame = 0;
  function refreshMarks() {
    cancelAnimationFrame(marksFrame);
    marksFrame = requestAnimationFrame(() => {
      refreshModes();
      refreshOutline();
      refreshUnderlines();
    });
  }

  let selectedChars = 0, selectionTimer = null;
  document.addEventListener("selectionchange", () => {
    if (!editor) return;
    refreshMarks();
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(() => {
      const root = area(), sel = window.getSelection();
      const inside = root && sel.rangeCount && root.contains(sel.anchorNode);
      const n = inside ? Array.from(sel.toString().replace(/\s/g, "")).length : 0;
      if (n !== selectedChars) { selectedChars = n; post({ type: "selection", chars: n }); }
    }, 120);
  });
  document.addEventListener("scroll", () => { if (editor) refreshOutline(); }, true);
  document.addEventListener("keyup", (e) => {
    if (e.key.startsWith("Arrow") || e.key === "Enter" || e.key === "Backspace") centreCaret();
  }, true);
  document.addEventListener("input", centreCaret, true);

  // MARK: Find and replace

  const search = { query: "", ranges: [], index: -1 };

  /// Every match in the text as it reads: not rendered previews (their source is searched
  /// instead), and not the marks hidden around formatted text.
  function matches(query) {
    const root = area(), found = [];
    if (!root || !query) return found;
    const needle = query.toLowerCase();
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode(node) {
      const p = node.parentElement;
      if (p.closest(".vditor-ir__preview")) return NodeFilter.FILTER_REJECT;
      const marker = p.closest(".vditor-ir__marker");
      return marker && !marker.closest(".vditor-ir__marker--pre") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
    } });
    while (walker.nextNode()) {
      const hay = walker.currentNode.data.toLowerCase();
      for (let at = hay.indexOf(needle); at >= 0; at = hay.indexOf(needle, at + needle.length)) {
        const r = document.createRange();
        r.setStart(walker.currentNode, at);
        r.setEnd(walker.currentNode, at + needle.length);
        found.push(r);
      }
    }
    return found;
  }

  function paintSearch() {
    if (!highlights) return;
    const current = search.ranges[search.index];
    highlights.set("loupe-find", new Highlight(...search.ranges.filter((r) => r !== current)));
    highlights.set("loupe-find-current", current ? new Highlight(current) : new Highlight());
  }

  function showCurrentMatch(select) {
    const r = search.ranges[search.index], root = area();
    paintSearch();
    if (!r) return;
    if (select) {
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(r);
    }
    requestAnimationFrame(() => {
      const rect = r.getClientRects()[0] || r.startContainer.parentElement.getBoundingClientRect();
      const box = root.getBoundingClientRect();
      if (rect.top < box.top + 40 || rect.bottom > box.bottom - 40) root.scrollTop += rect.top - box.top - box.height / 3;
    });
  }

  /// step: 1 or -1 moves through the matches; 0 is a new or changed query. Returns [number, total].
  function find(query, step) {
    const changed = query !== search.query;
    search.query = query;
    search.ranges = matches(query);
    const count = search.ranges.length;
    if (!count) {
      search.index = -1;
    } else if (changed || search.index < 0) {
      // Start from what is on screen, not back at the top of the document.
      const top = area().getBoundingClientRect().top;
      search.index = Math.max(0, search.ranges.findIndex((r) => {
        const rect = r.getClientRects()[0];
        return rect && rect.top >= top;
      }));
      if (step < 0) search.index = (search.index - 1 + count) % count;
    } else {
      search.index = (search.index + step + count) % count;
    }
    showCurrentMatch(true);
    return [search.index + 1, count];
  }

  function replaceCurrent(query, replacement) {
    search.query = query;
    search.ranges = matches(query);
    if (!search.ranges.length) { search.index = -1; paintSearch(); return [0, 0]; }
    const at = Math.max(0, Math.min(search.index, search.ranges.length - 1));
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(search.ranges[at]);
    area().focus({ preventScroll: true });
    document.execCommand("insertText", false, replacement);
    scheduleChange();
    search.ranges = matches(query);
    const count = search.ranges.length;
    // A replacement that contains the query must not be found again.
    const skip = replacement.toLowerCase().includes(query.toLowerCase()) ? 1 : 0;
    search.index = count ? (at + skip) % count : -1;
    showCurrentMatch(true);
    return [search.index + 1, count];
  }

  /// One undoable step over the Markdown. Link and picture addresses are left alone.
  function replaceAll(query, replacement) {
    const needle = new RegExp(query.replace(/[.*+?^\${}()|[\]\\]/g, "\\$&"), "gi");
    let n = 0;
    const out = editor.getValue().split(/(\]\([^)\n]*\))/).map((part, i) =>
      i % 2 ? part : part.replace(needle, () => { n += 1; return replacement; })).join("");
    if (n) { editor.setValue(out, false); scheduleChange(); }
    search.ranges = matches(query);
    search.index = search.ranges.length ? 0 : -1;
    paintSearch();
    return n;
  }

  function endSearch() {
    search.query = "";
    search.ranges = [];
    search.index = -1;
    if (highlights) { highlights.delete("loupe-find"); highlights.delete("loupe-find-current"); }
  }

  const PAIRS = { "*": ["*", "*"], "_": ["_", "_"], "`": ["`", "`"], "~": ["~~", "~~"], '"': ['"', '"'], "'": ["'", "'"],
                  "(": ["(", ")"], "[": ["[", "]"], "{": ["{", "}"] };

  /// Some text on one line is selected, outside code.
  function wrapsSelection() {
    const sel = window.getSelection(), el = caretElement();
    return !!el && !sel.isCollapsed && !sel.toString().includes("\n") && !el.closest('[data-type="code-block"], code');
  }

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
      if (code === "KeyL") return run("selectLine");
      if (code === "KeyD") return run("selectWord");
      if (code === "Backslash") return run("clearFormat");
      if (code === "Enter" && addTableRow()) { e.preventDefault(); e.stopImmediatePropagation(); return; }
      if (code === "BracketRight") return run("indent");
      if (code === "BracketLeft") return run("outdent");
      if (code === "Slash") { e.preventDefault(); e.stopImmediatePropagation(); post({ type: "toggleSource" }); return; }
    }
    if (ctrl && !cmd && !alt && code === "Backquote") return run(shift ? "strike" : "inlineCode");
    if (cmd && ctrl && !alt && !shift && code === "ArrowUp") return run("moveUp");
    if (cmd && ctrl && !alt && !shift && code === "ArrowDown") return run("moveDown");
    if (!cmd && !ctrl && !alt && (code === "F8" || code === "F9")) {
      e.preventDefault();
      post({ type: "toggleMode", name: code === "F8" ? "focus" : "typewriter" });
      return;
    }
    // Typing a mark over selected text puts it around the text (Typora's auto-pairing).
    const pair = PAIRS[e.key];
    if (pair && !cmd && !ctrl && !alt && !e.isComposing && wrapsSelection()) {
      e.preventDefault();
      e.stopImmediatePropagation();
      wrap(pair[0], pair[1]);
      scheduleChange();
      return;
    }
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

  // A web address pasted over selected text makes that text a link.
  window.addEventListener("paste", (e) => {
    if (!editor) return;
    const url = (e.clipboardData && e.clipboardData.getData("text/plain") || "").trim();
    if (!/^(https?:\/\/|mailto:)\S+$/.test(url) || !wrapsSelection()) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    wrap("[", `](${url})`);
    scheduleChange();
  }, true);

  // Vditor's copy button copies from a hidden box, which is empty by the time it is clicked, so
  // nothing reached the clipboard. Hand the code block's text to the app instead.
  document.addEventListener("click", (e) => {
    const button = e.target.closest(".vditor-copy span");
    if (!button) return;
    e.stopPropagation();
    const code = button.closest("pre").querySelector("code");
    post({ type: "copy", text: code.textContent.replace(/\u00a0/g, " ").replace(/\n$/, "") });
    button.setAttribute("aria-label", "已复制");
  }, true);

  // MARK: The app's side

  window.loupeWriter = {
    load(markdown, m, outline) { create(markdown, m || "ir", outline); return true; },
    value() { return editor ? editor.getValue() : ""; },
    setValue(markdown) { if (editor) { editor.setValue(markdown, false); scheduleChange(); } return true; },
    setMode(m, outline) { const v = this.value(); create(v, m, outline); return true; },
    command(name) { if (commands[name]) { commands[name](); scheduleChange(); return true; } return false; },
    focus() { if (editor) editor.focus(); return true; },
    insert(markdown) { if (editor) { editor.insertValue(markdown); scheduleChange(); } return true; },
    setModes(focus, typewriter) {
      modes.focus = focus;
      modes.typewriter = typewriter;
      refreshModes();
      centreCaret();
      return true;
    },
    find, replaceCurrent, replaceAll, endSearch
  };
  post({ type: "loaded" });
})();
