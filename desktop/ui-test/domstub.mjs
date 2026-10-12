// desktop/ui-test/domstub.mjs — a deliberately small DOM + browser-globals stub, just rich enough to run
// the REAL app.js (and strings.js, index.html) inside a node:vm context and assert on what it
// renders. It is not a browser: no layout, no CSS, no network. Anything app.js asks of it that the
// stub does not model throws loudly, so a new browser dependency shows up as a test failure rather
// than a silently-unexercised branch.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';

const here = join(dirname(fileURLToPath(import.meta.url)), '..', 'ui');   // the shipped sources under test

const observers = new Set();
/** childList MutationObserver: callbacks run in a microtask after the DOM changed under a watched node. */
export class FakeMutationObserver {
  constructor(cb) { this.cb = cb; this.targets = []; this.queued = false; }
  observe(target, opts = {}) { this.targets.push({ target, subtree: !!opts.subtree }); observers.add(this); }
  disconnect() { this.targets = []; observers.delete(this); }
  takeRecords() { return []; }
  deliver(changed) {
    if (!this.targets.some((t) => t.target === changed || (t.subtree && t.target.contains(changed)))) return;
    if (this.queued) return;
    this.queued = true;
    queueMicrotask(() => { this.queued = false; if (this.targets.length) this.cb([{ type: 'childList', target: changed }], this); });
  }
}
const VOID = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr']);

// ── nodes ────────────────────────────────────────────────────────────────────────────────────────
export class Text {
  constructor(data) { this.nodeType = 3; this.data = String(data); this.parentNode = null; }
  get textContent() { return this.data; }
  set textContent(v) { this.data = String(v); }
  remove() { if (this.parentNode) this.parentNode._detach(this); }
}

function parseCompound(sel) {
  // tag#id.class[attr=val]:pseudo — returns a predicate.
  const preds = [];
  let rest = sel.trim();
  const tag = rest.match(/^[a-zA-Z][a-zA-Z0-9-]*|^\*/);
  if (tag) { rest = rest.slice(tag[0].length); if (tag[0] !== '*') preds.push((e) => e.tagName === tag[0].toUpperCase()); }
  while (rest) {
    let m;
    if ((m = rest.match(/^#([\w-]+)/))) preds.push((e) => e.id === m[1]);
    else if ((m = rest.match(/^\.([\w-]+)/))) preds.push((e) => e.classList.contains(m[1]));
    else if ((m = rest.match(/^\[([\w:-]+)(?:([\^$*~|]?=)(?:"([^"]*)"|'([^']*)'|([^\]]*)))?\]/))) {
      const [, name, op, a, b, c] = m; const val = a ?? b ?? c;
      preds.push((e) => {
        if (!e.hasAttribute(name)) return false;
        if (!op) return true;
        const v = e.getAttribute(name);
        return op === '=' ? v === val : op === '^=' ? v.startsWith(val) : op === '$=' ? v.endsWith(val) : op === '*=' ? v.includes(val) : false;
      });
    } else if ((m = rest.match(/^:not\(([^)]*)\)/))) { const inner = parseCompound(m[1]); preds.push((e) => !inner(e)); }
    else if ((m = rest.match(/^:first-child/))) preds.push((e) => e.parentNode && e.parentNode.children[0] === e);
    else if ((m = rest.match(/^:last-child/))) preds.push((e) => e.parentNode && e.parentNode.children.at(-1) === e);
    else throw new Error(`domstub: unsupported selector fragment "${rest}" in "${sel}"`);
    rest = rest.slice(m[0].length);
  }
  return (e) => preds.every((p) => p(e));
}

function compileSelector(sel) {
  const groups = sel.split(',').map((g) => g.trim()).filter(Boolean);
  const compiled = groups.map((g) => {
    const parts = g.replace(/\s*>\s*/g, ' > ').split(/\s+/);
    const steps = []; let child = false;
    for (const p of parts) { if (p === '>') { child = true; continue; } steps.push({ pred: parseCompound(p), child }); child = false; }
    return steps;
  });
  const matchSteps = (e, steps, i) => {
    if (!steps[i].pred(e)) return false;
    if (i === 0) return true;
    if (steps[i].child) return !!e.parentNode && e.parentNode.nodeType === 1 && matchSteps(e.parentNode, steps, i - 1);
    for (let p = e.parentNode; p && p.nodeType === 1; p = p.parentNode) if (matchSteps(p, steps, i - 1)) return true;
    return false;
  };
  return (e) => compiled.some((steps) => matchSteps(e, steps, steps.length - 1));
}

class ClassList {
  constructor(el) { this.el = el; }
  _set() { return new Set(this.el._class.split(/\s+/).filter(Boolean)); }
  _write(s) { this.el._class = [...s].join(' '); }
  add(...c) { const s = this._set(); c.forEach((x) => s.add(x)); this._write(s); }
  remove(...c) { const s = this._set(); c.forEach((x) => s.delete(x)); this._write(s); }
  contains(c) { return this._set().has(c); }
  toggle(c, force) { const on = force === undefined ? !this.contains(c) : !!force; on ? this.add(c) : this.remove(c); return on; }
  replace(a, b) { if (!this.contains(a)) return false; this.remove(a); this.add(b); return true; }
  get length() { return this._set().size; }
  toString() { return this.el._class; }
  [Symbol.iterator]() { return this._set()[Symbol.iterator](); }
}

export class Element {
  constructor(tag, doc) {
    this.nodeType = 1; this.tagName = String(tag).toUpperCase(); this.ownerDocument = doc;
    this.parentNode = null; this.childNodes = []; this._attrs = new Map(); this._class = '';
    this.classList = new ClassList(this); this.dataset = {}; this._listeners = new Map();
    this.style = { setProperty(k, v) { this[k] = v; }, removeProperty(k) { delete this[k]; }, getPropertyValue(k) { return this[k] ?? ''; } };
    this._value = undefined; this._scrollTop = 0;
    this.scrollTop = 0; this.scrollLeft = 0; this.scrollHeight = 0; this.clientHeight = 0; this.clientWidth = 0;
    this.offsetHeight = 0; this.offsetWidth = 0;
  }
  get children() { return this.childNodes.filter((n) => n.nodeType === 1); }
  get firstChild() { return this.childNodes[0] ?? null; }
  get lastChild() { return this.childNodes.at(-1) ?? null; }
  get firstElementChild() { return this.children[0] ?? null; }
  get lastElementChild() { return this.children.at(-1) ?? null; }
  get nextSibling() { const s = this.parentNode?.childNodes ?? []; return s[s.indexOf(this) + 1] ?? null; }
  get previousSibling() { const s = this.parentNode?.childNodes ?? []; return s[s.indexOf(this) - 1] ?? null; }
  get nextElementSibling() { const s = this.parentNode?.children ?? []; return s[s.indexOf(this) + 1] ?? null; }
  get previousElementSibling() { const s = this.parentNode?.children ?? []; return s[s.indexOf(this) - 1] ?? null; }
  get isConnected() { let n = this; while (n.parentNode) n = n.parentNode; return n === this.ownerDocument._root; }
  get id() { return this._attrs.get('id') ?? ''; }
  set id(v) { this._attrs.set('id', String(v)); }
  get className() { return this._class; }
  set className(v) { this._class = String(v); }
  get parentElement() { return this.parentNode && this.parentNode.nodeType === 1 ? this.parentNode : null; }
  get tabIndex() { return Number(this._attrs.get('tabindex') ?? -1); }
  set tabIndex(v) { this._attrs.set('tabindex', String(v)); }
  get textContent() { return this.childNodes.map((n) => n.textContent).join(''); }
  set textContent(v) { this.replaceChildren(String(v) === '' ? [] : new Text(v)); }
  get innerText() { return this.textContent; }
  set innerText(v) { this.textContent = v; }
  get innerHTML() { return this.childNodes.map((n) => n.nodeType === 3 ? n.data : n.outerHTML).join(''); }
  set innerHTML(v) { this.replaceChildren(); parseHTML(String(v), this); }
  get outerHTML() {
    const attrs = [...this._attrs].map(([k, v]) => ` ${k}="${v}"`).join('') + (this._class ? ` class="${this._class}"` : '');
    return VOID.has(this.tagName.toLowerCase()) ? `<${this.tagName.toLowerCase()}${attrs}>` : `<${this.tagName.toLowerCase()}${attrs}>${this.innerHTML}</${this.tagName.toLowerCase()}>`;
  }
  setAttribute(k, v) {
    if (k === 'class') this._class = String(v);
    else { this._attrs.set(k, String(v)); if (k === 'value' && this.tagName !== 'OPTION') this._value = String(v); if (k.startsWith('data-')) this.dataset[k.slice(5).replace(/-(\w)/g, (_, c) => c.toUpperCase())] = String(v); }
  }
  getAttribute(k) { return k === 'class' ? (this._class || null) : (this._attrs.has(k) ? this._attrs.get(k) : null); }
  hasAttribute(k) { return k === 'class' ? !!this._class : this._attrs.has(k); }
  removeAttribute(k) { if (k === 'class') this._class = ''; this._attrs.delete(k); }
  toggleAttribute(k, force) { const on = force === undefined ? !this.hasAttribute(k) : force; on ? this.setAttribute(k, '') : this.removeAttribute(k); return on; }
  get value() {
    if (this.tagName === 'SELECT') {
      if (this._value !== undefined) return this._value;
      const opts = this.querySelectorAll('option');
      const sel = opts.find((o) => o.hasAttribute('selected')) ?? opts[0];
      return sel ? sel.value : '';
    }
    if (this.tagName === 'OPTION') return this._attrs.has('value') ? this._attrs.get('value') : this.textContent;
    return this._value ?? '';
  }
  set value(v) { this._value = String(v); }
  get disabled() { return this._attrs.has('disabled'); } set disabled(v) { v ? this._attrs.set('disabled', '') : this._attrs.delete('disabled'); }
  get hidden() { return this._attrs.has('hidden'); } set hidden(v) { v ? this._attrs.set('hidden', '') : this._attrs.delete('hidden'); }
  get checked() { return this._checked ?? this._attrs.has('checked'); } set checked(v) { this._checked = !!v; }
  get src() { return this._attrs.get('src') ?? ''; } set src(v) { this._attrs.set('src', String(v)); }
  get href() { return this._attrs.get('href') ?? ''; } set href(v) { this._attrs.set('href', String(v)); }
  get type() { return this._attrs.get('type') ?? (this.tagName === 'INPUT' ? 'text' : ''); } set type(v) { this._attrs.set('type', String(v)); }
  get placeholder() { return this._attrs.get('placeholder') ?? ''; } set placeholder(v) { this._attrs.set('placeholder', String(v)); }
  get title() { return this._attrs.get('title') ?? ''; } set title(v) { this._attrs.set('title', String(v)); }
  get name() { return this._attrs.get('name') ?? ''; } set name(v) { this._attrs.set('name', String(v)); }
  get alt() { return this._attrs.get('alt') ?? ''; } set alt(v) { this._attrs.set('alt', String(v)); }
  get htmlFor() { return this._attrs.get('for') ?? ''; } set htmlFor(v) { this._attrs.set('for', String(v)); }
  get selected() { return this._selected ?? false; } set selected(v) { this._selected = !!v; }
  get options() { return this.querySelectorAll('option'); }
  get selectedIndex() { const o = this.options; const i = o.findIndex((x) => x.value === this.value); return i; }
  get files() { return this._files ?? []; } set files(v) { this._files = v; }

  _detach(n) { const i = this.childNodes.indexOf(n); if (i >= 0) { this.childNodes.splice(i, 1); n.parentNode = null; this._notify(); } }
  _notify() { for (const e of observers) e.deliver(this); }
  _attach(n, at = this.childNodes.length) {
    if (n.nodeType === 11) { [...n.childNodes].forEach((c, i) => this._attach(c, at + i)); n.childNodes = []; return; }
    if (n.parentNode) n.parentNode._detach(n);
    n.parentNode = this; this.childNodes.splice(at, 0, n);
    this._notify();
  }
  _norm(x) { return x && x.nodeType ? x : new Text(x); }
  append(...xs) { xs.flat().forEach((x) => { if (x != null) this._attach(this._norm(x)); }); }
  appendChild(n) { this._attach(n); return n; }
  prepend(...xs) { xs.flat().reverse().forEach((x) => { if (x != null) this._attach(this._norm(x), 0); }); }
  insertBefore(n, ref) { this._attach(n, ref ? this.childNodes.indexOf(ref) : this.childNodes.length); return n; }
  insertAdjacentElement(where, n) {
    if (where === 'beforeend') this.append(n); else if (where === 'afterbegin') this.prepend(n);
    else if (where === 'beforebegin') this.parentNode._attach(n, this.parentNode.childNodes.indexOf(this));
    else this.parentNode._attach(n, this.parentNode.childNodes.indexOf(this) + 1);
    return n;
  }
  insertAdjacentHTML(where, html) { const tmp = new Element('div', this.ownerDocument); parseHTML(html, tmp); [...tmp.childNodes].forEach((c) => this.insertAdjacentElement(where, c)); }
  after(...xs) { const p = this.parentNode; let at = p.childNodes.indexOf(this) + 1; xs.flat().forEach((x) => p._attach(this._norm(x), at++)); }
  before(...xs) { const p = this.parentNode; let at = p.childNodes.indexOf(this); xs.flat().forEach((x) => p._attach(this._norm(x), at++)); }
  replaceChildren(...xs) { [...this.childNodes].forEach((c) => this._detach(c)); this.append(...xs.flat()); }
  replaceWith(...xs) { const p = this.parentNode; if (!p) return; const at = p.childNodes.indexOf(this); p._detach(this); xs.flat().forEach((x, i) => p._attach(this._norm(x), at + i)); }
  removeChild(n) { this._detach(n); return n; }
  remove() { if (this.parentNode) this.parentNode._detach(this); }
  contains(n) { for (let x = n; x; x = x.parentNode) if (x === this) return true; return false; }
  cloneNode(deep) {
    const c = new Element(this.tagName, this.ownerDocument); c._class = this._class; this._attrs.forEach((v, k) => c._attrs.set(k, v)); c.value = this.value;
    if (deep) this.childNodes.forEach((n) => c._attach(n.nodeType === 3 ? new Text(n.data) : n.cloneNode(true)));
    return c;
  }
  _all(out = []) { for (const c of this.children) { out.push(c); c._all(out); } return out; }
  querySelectorAll(sel) { const m = compileSelector(sel); return this._all().filter(m); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] ?? null; }
  matches(sel) { return compileSelector(sel)(this); }
  closest(sel) { const m = compileSelector(sel); for (let e = this; e && e.nodeType === 1; e = e.parentNode) if (m(e)) return e; return null; }
  getElementsByTagName(t) { return this._all().filter((e) => e.tagName === t.toUpperCase()); }
  getBoundingClientRect() { return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 }; }
  getClientRects() { return []; }
  scrollIntoView() {} scrollTo() {} scrollBy() {} focus() { this.ownerDocument._active = this; } blur() { if (this.ownerDocument._active === this) this.ownerDocument._active = null; }
  select() {} setSelectionRange() {} showModal() {} close() {} setPointerCapture() {} releasePointerCapture() {}
  play() { this.paused = false; return Promise.resolve(); } pause() { this.paused = true; } load() {}
  animate() { return { cancel() {}, finished: Promise.resolve(), onfinish: null }; }
  getContext() { return new Proxy({}, { get: (_, k) => (k === 'canvas' ? this : () => ({ width: 0 })), set: () => true }); }
  toDataURL() { return 'data:image/jpeg;base64,AAAA'; } toBlob(cb) { cb(new Blob(['x'])); }
  addEventListener(type, fn) { if (!this._listeners.has(type)) this._listeners.set(type, []); this._listeners.get(type).push(fn); }
  removeEventListener(type, fn) { const l = this._listeners.get(type); if (l) this._listeners.set(type, l.filter((f) => f !== fn)); }
  dispatchEvent(ev) {
    ev.target ??= this;
    for (let n = this; n; n = n.parentNode) {
      ev.currentTarget = n;
      for (const fn of [...(n._listeners?.get(ev.type) ?? [])]) fn.call(n, ev);
      const h = n['on' + ev.type]; if (typeof h === 'function') h.call(n, ev);
      if (ev._stopped || !ev.bubbles) break;
    }
    return !ev.defaultPrevented;
  }
  click() { this.dispatchEvent(new DomEvent('click', { bubbles: true })); }
  get onclick() { return this._onclick ?? null; } set onclick(f) { this._onclick = f; }
}
for (const ev of ['input', 'change', 'keydown', 'keyup', 'submit', 'load', 'error', 'ended', 'loadedmetadata', 'timeupdate', 'pointerdown', 'pointerup', 'pointermove', 'scroll', 'contextmenu', 'dblclick', 'focus', 'blur', 'paste', 'drop', 'dragover', 'canplay', 'play', 'pause', 'toggle']) {
  Object.defineProperty(Element.prototype, 'on' + ev, { get() { return this['_on' + ev] ?? null; }, set(f) { this['_on' + ev] = f; }, configurable: true });
}

export class DomEvent {
  constructor(type, init = {}) { this.type = type; this.bubbles = !!init.bubbles; this.defaultPrevented = false; this._stopped = false; Object.assign(this, init); }
  preventDefault() { this.defaultPrevented = true; }
  stopPropagation() { this._stopped = true; }
  stopImmediatePropagation() { this._stopped = true; }
}

class Fragment extends Element {
  constructor(doc) { super('#fragment', doc); this.nodeType = 11; }
}

// ── tiny HTML parser (enough for template strings and index.html) ─────────────────────────────
function parseHTML(html, into) {
  const doc = into.ownerDocument;
  const stack = [into];
  const re = /<!--[\s\S]*?-->|<\/([a-zA-Z][\w-]*)\s*>|<([a-zA-Z][\w-]*)((?:\s+[^\s=>\/]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?)*)\s*(\/?)>|([^<]+)|</g;
  let m;
  while ((m = re.exec(html))) {
    const top = stack.at(-1);
    if (m[0].startsWith('<!--')) continue;
    if (m[1]) { const tag = m[1].toUpperCase(); for (let i = stack.length - 1; i > 0; i--) if (stack[i].tagName === tag) { stack.length = i; break; } }
    else if (m[2]) {
      const tag = m[2].toLowerCase();
      if (tag === 'script' || tag === 'style') { const close = html.indexOf(`</${tag}>`, re.lastIndex); re.lastIndex = close < 0 ? html.length : close + tag.length + 3; continue; }
      const e = new Element(tag, doc);
      for (const a of m[3].matchAll(/([^\s=>\/]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) e.setAttribute(a[1], a[2] ?? a[3] ?? a[4] ?? '');
      top._attach(e);
      if (!VOID.has(tag) && !m[4]) stack.push(e);
    } else if (m[5] !== undefined) {
      const text = m[5].replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
      top._attach(new Text(text));
    }
  }
}

export class Document {
  constructor() {
    this._root = new Element('html', this); this._active = null; this._listeners = new Map();
    this.documentElement = this._root; this.head = new Element('head', this); this.body = new Element('body', this);
    this._root.append(this.head, this.body);
    this.readyState = 'complete'; this.hidden = false; this.visibilityState = 'visible'; this.fonts = { ready: Promise.resolve() };
    this.cookie = ''; this.title = 'Haven';
  }
  createElement(tag) { return new Element(tag, this); }
  createElementNS(_ns, tag) { return new Element(tag, this); }
  createTextNode(s) { return new Text(s); }
  createDocumentFragment() { return new Fragment(this); }
  createComment() { return new Text(''); }
  getElementById(id) { return this._root._all().find((e) => e.id === id) ?? null; }
  querySelector(s) { return this._root.querySelector(s); }
  querySelectorAll(s) { return this._root.querySelectorAll(s); }
  getElementsByClassName(c) { return this._root._all().filter((e) => e.classList.contains(c)); }
  get activeElement() { return this._active ?? this.body; }
  hasFocus() { return true; }
  execCommand() { return true; }
  addEventListener(t, f) { if (!this._listeners.has(t)) this._listeners.set(t, []); this._listeners.get(t).push(f); }
  removeEventListener(t, f) { const l = this._listeners.get(t); if (l) this._listeners.set(t, l.filter((x) => x !== f)); }
  dispatchEvent(ev) { ev.target ??= this; for (const f of [...(this._listeners.get(ev.type) ?? [])]) f.call(this, ev); return !ev.defaultPrevented; }
}

// ── manual timers: nothing ever fires unless a test asks ───────────────────────────────────────
export function makeTimers() {
  let now = 0, nextId = 1; const q = new Map();
  return {
    setTimeout(fn, ms = 0, ...a) { const id = nextId++; q.set(id, { at: now + Number(ms || 0), fn, a, every: 0 }); return id; },
    setInterval(fn, ms = 0, ...a) { const id = nextId++; q.set(id, { at: now + Number(ms || 1), fn, a, every: Number(ms || 1) }); return id; },
    clearTimeout(id) { q.delete(id); }, clearInterval(id) { q.delete(id); },
    /** Advance the fake clock, firing due timers in order. */
    async advance(ms) {
      const target = now + ms;
      for (;;) {
        const due = [...q.entries()].filter(([, t]) => t.at <= target).sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
        if (!due) break;
        const [id, t] = due; now = t.at;
        if (t.every) t.at = now + t.every; else q.delete(id);
        Promise.resolve().then(() => t.fn(...t.a)).catch((e) => { throw e; });
        for (let i = 0; i < 10; i++) await new Promise((r) => setImmediate(r));
      }
      now = target;
    },
    pending() { return q.size; },
  };
}

// ── the sandbox ─────────────────────────────────────────────────────────────────────────────────
/**
 * Build a browser-ish vm context, load index.html into its document, run strings.js then app.js
 * (as a script whose filename is the real file URL, so node's coverage attributes lines to it),
 * and hand back handles. `backend` maps a Tauri command name to `(args) => result | Promise`;
 * an unmapped command resolves to `undefined` (and is recorded in `calls`).
 */
export async function loadApp({ backend = {}, lang = 'en-US', ua = 'Mozilla/5.0 (Macintosh; Intel Mac OS X) Haven', boot = true, local = {} } = {}) {
  const document = new Document();
  const html = readFileSync(join(here, 'index.html'), 'utf8');
  const bodyHtml = html.slice(html.indexOf('<body>') + 6, html.indexOf('</body>'));
  parseHTML(bodyHtml, document.body);

  const timers = makeTimers();
  const calls = [];
  const dialogs = [];
  const opened = [];
  const dialogOpens = [];
  const listeners = new Map();   // tauri event name -> handlers
  const store = new Map(Object.entries(local));
  const localStorage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k), clear: () => store.clear(), get length() { return store.size; }, key: (i) => [...store.keys()][i] ?? null,
  };
  const invoke = async (cmd, args = {}) => {
    calls.push({ cmd, args });
    const fn = backend[cmd];
    if (fn === undefined) return undefined;
    if (typeof fn === 'function') return fn(args);
    return fn;
  };
  const listen = async (name, fn) => { if (!listeners.has(name)) listeners.set(name, []); listeners.get(name).push(fn); return () => {}; };
  const winListeners = new Map();
  class NoopObserver { constructor(cb) { this.cb = cb; } observe() {} unobserve() {} disconnect() {} takeRecords() { return []; } }
  class FakeImage { constructor() { this.naturalWidth = 100; this.naturalHeight = 100; this.width = 100; this.height = 100; this.complete = true; setTimeout; } set src(v) { this._src = v; queueMicrotask(() => this.onload?.()); } get src() { return this._src; } decode() { return Promise.resolve(); } }
  class FakeAudio { constructor(src) { this.src = src; this.paused = true; this.volume = 1; this.currentTime = 0; this.duration = 0; } play() { this.paused = false; return Promise.resolve(); } pause() { this.paused = true; } addEventListener() {} removeEventListener() {} load() {} }
  class FakeTrack { constructor(kind) { this.kind = kind; this.enabled = true; this.id = kind + '0'; this.stopped = false; } stop() { this.stopped = true; } }
  class FakeStream { constructor(tracks = []) { this._t = [...tracks]; this.id = 'stream'; } getTracks() { return [...this._t]; } getAudioTracks() { return this._t.filter((t) => t.kind === 'audio'); } getVideoTracks() { return this._t.filter((t) => t.kind === 'video'); } addTrack(t) { this._t.push(t); } removeTrack(t) { this._t = this._t.filter((x) => x !== t); } }
  const rtc = [];
  class FakePC {
    constructor(cfg) { this.cfg = cfg; this.senders = []; this.tr = []; this.connectionState = 'new'; this.closed = false; this.remote = null; this.local = null; this.ice = []; rtc.push(this); }
    addTrack(t) { const sn = { track: t, replaceTrack: async (x) => { sn.track = x; } }; this.senders.push(sn); return sn; }
    addTransceiver(kind) { const tr = { sender: { track: null, replaceTrack: async (x) => { tr.sender.track = x; } }, receiver: { track: { kind } } }; this.tr.push(tr); return tr; }
    getSenders() { return this.senders; } getTransceivers() { return this.tr; }
    async createOffer() { return { type: 'offer', sdp: 'offer-sdp' }; } async createAnswer() { return { type: 'answer', sdp: 'answer-sdp' }; }
    async setLocalDescription(d) { this.local = d; } async setRemoteDescription(d) { this.remote = d; } async addIceCandidate(c) { this.ice.push(c); }
    async getStats() { const m = new Map(); (this.statsRows ?? []).forEach((r, i) => m.set(i, r)); return m; }
    close() { this.closed = true; }
  }
  const sandbox = {
    document, localStorage, console, URL, URLSearchParams, Blob, TextEncoder, TextDecoder, Uint8Array, Promise, JSON, Math, Date, Intl, atob, btoa,
    structuredClone, AbortController, Map, Set, WeakMap, WeakSet, Symbol, Proxy, Reflect, Array, Object, String, Number, Boolean, RegExp, Error,
    parseInt, parseFloat, isNaN, isFinite, encodeURIComponent, decodeURIComponent, queueMicrotask,
    setTimeout: timers.setTimeout, setInterval: timers.setInterval, clearTimeout: timers.clearTimeout, clearInterval: timers.clearInterval,
    requestAnimationFrame: (fn) => timers.setTimeout(() => fn(0), 0), cancelAnimationFrame: timers.clearTimeout,
    requestIdleCallback: (fn) => timers.setTimeout(() => fn({ timeRemaining: () => 10 }), 0),
    navigator: { language: lang, languages: [lang], userAgent: ua, platform: 'MacIntel', clipboard: { writeText: async () => {}, readText: async () => '' }, mediaDevices: undefined, onLine: true, vibrate: () => true },
    matchMedia: (q) => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }),
    getComputedStyle: () => ({ display: 'block', getPropertyValue: () => '' }),
    IntersectionObserver: NoopObserver, MutationObserver: FakeMutationObserver, ResizeObserver: NoopObserver,
    Image: FakeImage, Audio: FakeAudio, FileReader: class { readAsDataURL() { this.result = 'data:;base64,AAAA'; queueMicrotask(() => this.onload?.()); } readAsArrayBuffer() { this.result = new ArrayBuffer(4); queueMicrotask(() => this.onload?.()); } },
    File: class extends Blob { constructor(parts, name, opts) { super(parts, opts); this.name = name; this.lastModified = 0; } },
    Event: DomEvent, CustomEvent: DomEvent, KeyboardEvent: DomEvent, MouseEvent: DomEvent, PointerEvent: DomEvent,
    HTMLElement: Element, Element, Node: Element, HTMLInputElement: Element, HTMLImageElement: Element, HTMLVideoElement: Element,
    fetch: async () => { throw new Error('domstub: no network'); },
    RTCPeerConnection: FakePC, MediaStream: FakeStream,
    performance: { now: () => 0 },
    __TAURI__: { core: { invoke }, event: { listen }, opener: { openUrl: (u) => { opened.push(u); } }, dialog: { open: async (o) => { dialogOpens.push(o); return sandbox.__pick ?? null; } } },
  };
  sandbox.innerWidth = 1280; sandbox.innerHeight = 800; sandbox.devicePixelRatio = 1;
  sandbox.addEventListener = (t, f) => { if (!winListeners.has(t)) winListeners.set(t, []); winListeners.get(t).push(f); };
  sandbox.removeEventListener = (t, f) => { const l = winListeners.get(t); if (l) winListeners.set(t, l.filter((x) => x !== f)); };
  sandbox.dispatchEvent = (ev) => { for (const f of [...(winListeners.get(ev.type) ?? [])]) f(ev); };
  sandbox.confirm = (m) => { dialogs.push(['confirm', m]); return sandbox.__confirm ?? true; };
  sandbox.alert = (m) => { dialogs.push(['alert', m]); };
  sandbox.prompt = (m) => { dialogs.push(['prompt', m]); return sandbox.__prompt ?? null; };
  sandbox.open = () => null; sandbox.scrollTo = () => {}; sandbox.getSelection = () => ({ removeAllRanges() {}, toString: () => '' });
  sandbox.crypto = { getRandomValues: (a) => { for (let i = 0; i < a.length; i++) a[i] = (i * 31 + 7) & 255; return a; }, randomUUID: () => '00000000-0000-4000-8000-000000000000', subtle: {} };
  const ctx = vm.createContext(sandbox);
  sandbox.window = ctx; sandbox.self = ctx; sandbox.globalThis = ctx; sandbox.parent = ctx;

  sandbox.__media = { denyVideo: false, deny: false, gum: [] };
  sandbox.navigator.mediaDevices = {
    getUserMedia: async (c) => {
      sandbox.__media.gum.push(c);
      if (sandbox.__media.deny) throw new Error('NotAllowedError');
      if (c.video && sandbox.__media.denyVideo) throw new Error('NotFoundError');
      return new FakeStream([...(c.audio ? [new FakeTrack('audio')] : []), ...(c.video ? [new FakeTrack('video')] : [])]);
    },
    enumerateDevices: async () => [{ kind: 'audioinput', deviceId: 'mic1', label: 'Mic One' }, { kind: 'audiooutput', deviceId: 'spk1', label: 'Speaker One' }],
    getDisplayMedia: async () => new FakeStream([new FakeTrack('video')]),
    addEventListener() {}, removeEventListener() {},
  };
  const run = (file, src) => new vm.Script(src ?? readFileSync(join(here, file), 'utf8'), { filename: pathToFileURL(join(here, file)).href }).runInContext(ctx);
  run('strings.js');
  run('vendor/qrcode.js');
  run('app.js');
  const api = {
    ctx, document, timers, calls, dialogs, opened, dialogOpens, rtc, FakeTrack, FakeStream, localStorage, listeners,
    /** Evaluate an expression inside the app's global scope (reaches app.js `const`/`let` bindings). */
    ev: (code) => vm.runInContext(code, ctx),
    /** Deliver a Tauri event to every listener the app registered for it. */
    async emit(name, payload) { for (const f of listeners.get(name) ?? []) await f({ payload }); },
    async winEvent(type, init) { sandbox.dispatchEvent(new DomEvent(type, init)); await settle(); },
    /** Let promise chains (invoke → render) run to completion. */
    settle,
    q: (s) => document.querySelector(s), qa: (s) => document.querySelectorAll(s),
    text: (s) => (document.querySelector(s)?.textContent ?? null),
    commands: () => calls.map((c) => c.cmd),
  };
  async function settle(n = 40) { for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r)); }
  if (boot) {
    document.dispatchEvent(new DomEvent('DOMContentLoaded'));
    sandbox.dispatchEvent(new DomEvent('DOMContentLoaded'));
    await settle();
  }
  return api;
}
