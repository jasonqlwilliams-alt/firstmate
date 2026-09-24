// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable,collapsed,detail,detailHidden,opens}],
//     revealed:[<charted rows after every reveal control is clicked>],
//     reveal:[{text,after}], empty, more, error }
// A charted badge is {tone,text,expands}; `opens` records whether clicking the
// row's badge showed its explanation, and `detail` is that explanation's text.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.listeners = {};
    this.classList = {
      add: (c) => { if (!this.classList.contains(c)) this.className = (this.className + " " + c).trim(); },
      remove: (c) => { this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" "); },
      toggle: (c, force) => {
        const on = force === undefined ? !this.classList.contains(c) : force;
        if (on) this.classList.add(c); else this.classList.remove(c);
        return on;
      },
      contains: (c) => this.className.split(/\s+/).includes(c),
    };
  }
  click() { (this.listeners.click || []).forEach((fn) => fn({ preventDefault() {} })); }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
globalThis.window = {};
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const hasClass = (n, c) => n.className.split(/\s+/).includes(c);
const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({
      tone: c.className.replace(/.*fm-badge--/, "").split(/\s+/)[0],
      text: c.textContent,
      expands: c.tagName === "button",
    }));
// Readable text of an explanation panel: leaf texts joined with spaces.
const textOf = (n) =>
  n.children.length ? n.children.map(textOf).filter(Boolean).join(" ") : n._text;

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

// Rows in document order, descending into a collapsed overflow container and
// pairing each row with the explanation panel that follows it.
const rowNodes = (container, collapsed = false) => {
  const out = [];
  container.children.forEach((c, i) => {
    if (hasClass(c, "bb-overflow")) out.push(...rowNodes(c, collapsed || c.hidden));
    else if (hasClass(c, "bb-row")) {
      const next = container.children[i + 1];
      out.push({ row: c, detail: next && hasClass(next, "bb-detail") ? next : null, collapsed });
    }
  });
  return out;
};
const rowsOf = (container) =>
  rowNodes(container).map(({ row, detail, collapsed }) => {
    const main = row.children.find((c) => c.className.includes("bb-row__main"));
    return {
      title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
      sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
      badges: badgesOf(row),
      pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
      collapsed,
      detail: detail ? textOf(detail) : "",
      detailHidden: detail ? detail.hidden : true,
    };
  });

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// Click each row's badge once and record whether it showed the explanation.
rowNodes(ch).forEach(({ row, detail }, i) => {
  const badge = row.children.find((c) => c.className.includes("fm-badge") && c.tagName === "button");
  if (badge) badge.click();
  charted[i].opens = Boolean(badge && detail && !detail.hidden
    && badge.attributes["aria-expanded"] === "true" && hasClass(row, "bb-row--open"));
});
const revealButtons = ch.children.filter((c) => hasClass(c, "bb-morechip") && c.tagName === "button");
const reveal = revealButtons.map((b) => {
  const text = b.textContent;
  b.click();
  return { text, after: b.textContent };
});
const revealed = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children
  .filter((c) => hasClass(c, "bb-morechip") && c.tagName !== "button")
  .map((c) => c.textContent);

process.stdout.write(
  JSON.stringify({ stats, underway, charted, revealed, reveal, empty, more, error: errorText }) + "\n");
