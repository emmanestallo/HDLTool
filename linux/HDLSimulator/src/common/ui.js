'use strict';
/* global THEMES */
// Shared helpers for the page: DOM building, settings, menus, dialogs, fuzzy matching.

const Host = window.host;
const PathUtil = Host.path;
const IS_WIN = Host.platform === 'win32';
const IS_MAC = Host.platform === 'darwin';
const IS_LINUX = Host.platform === 'linux';
// Windows and Linux both use Ctrl shortcuts; only paths differ (Windows paths are case-insensitive).
const MOD = IS_MAC ? 'Cmd' : 'Ctrl';
const REVEAL_LABEL = IS_WIN ? 'Reveal in File Explorer' : IS_MAC ? 'Reveal in Finder' : 'Show in File Manager';
const REVEAL_SOURCE_LABEL = IS_WIN ? 'Reveal Source in File Explorer' : IS_MAC ? 'Reveal Source in Finder' : 'Show Source in File Manager';
// How to install a tool on this platform (Linux: the distribution's package manager).
const INSTALL_HINT = {
  iverilog: IS_WIN ? 'install from bleyer.org/icarus' : IS_MAC ? 'brew install icarus-verilog' : 'sudo apt install iverilog',
};

function h(tag, props, ...children) {
  const el = document.createElement(tag);
  if (props) {
    for (const [k, v] of Object.entries(props)) {
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'style') el.style.cssText = v;
      else if (k === 'html') el.innerHTML = v;
      else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
      else if (k === 'value') el.value = v;
      else if (k === 'checked') el.checked = !!v;
      else el.setAttribute(k, v === true ? '' : v);
    }
  }
  for (const c of children.flat(Infinity)) if (c != null && c !== false) el.append(c.nodeType ? c : String(c));
  return el;
}
const icon = (name, extra = '', style = '') => h('span', { class: `codicon codicon-${name} ${extra}`, style: style || null });
const $ = (sel, el = document) => el.querySelector(sel);

// ---------------------------------------------------------------- Settings (stored like the Mac app's UserDefaults keys)

const store = {
  get(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { if (v === undefined) localStorage.removeItem(k); else localStorage.setItem(k, JSON.stringify(v)); } catch { /* ignore */ } },
};

const Prefs = {
  defaults: {
    themeID: 'darkModern',
    'editor.fontSize': 13, 'editor.fontName': '', 'editor.tabSize': 4, 'editor.insertSpaces': true, 'editor.wordWrap': false,
    'editor.autoClose': true, 'editor.autoEnd': true, 'editor.suggest': true, 'editor.highlightLine': true, 'editor.indentGuides': true,
    'editor.inlineDiagnostics': true, 'editor.showInvisibles': false, 'editor.minimap': false,
    trimTrailingWhitespace: true, insertFinalNewline: true, linter: 'auto', lintWhileTyping: true, languageStandard: '-g2012',
    saveBeforeRun: true, iverilogPath: '', verilatorPath: '', ghdlPath: '',
    openWaveformsInViewer: true, openResultsInViewer: true, restoreSession: false,
  },
  listeners: [],
  get(k) { return store.get(k, Prefs.defaults[k]); },
  set(k, v) { store.set(k, v); for (const l of Prefs.listeners) l(k, v); },
  onChange(fn) { Prefs.listeners.push(fn); },
};
const currentTheme = () => THEMES[Prefs.get('themeID')] || THEMES.darkModern;

// ---------------------------------------------------------------- Paths

const Paths = {
  // Shortens paths under the home folder to ~ (like the Mac app's abbreviatingWithTildeInPath).
  tilde(p) {
    const home = Host.launch.home;
    if (!p || !home) return p || '';
    if (p === home) return '~';
    if (p.startsWith(home + PathUtil.sep)) return '~' + p.slice(home.length);
    return p;
  },
  same(a, b) {
    if (!a || !b) return false;
    if (a === b) return true;
    return IS_WIN ? PathUtil.normalize(a).toLowerCase() === PathUtil.normalize(b).toLowerCase() : PathUtil.normalize(a) === PathUtil.normalize(b);
  },
  isUnder(p, dir) {
    if (!p || !dir) return false;
    const a = IS_WIN ? p.toLowerCase() : p, b = IS_WIN ? dir.toLowerCase() : dir;
    return a.startsWith(b.endsWith(PathUtil.sep) ? b : b + PathUtil.sep);
  },
  ext(p) { return PathUtil.extname(p || '').slice(1).toLowerCase(); },
};

// ---------------------------------------------------------------- Menus & dialogs

const Menus = {
  async popup(items, anchor) {
    let pos = null;
    if (anchor && anchor.getBoundingClientRect) { const r = anchor.getBoundingClientRect(); pos = { x: r.left, y: r.bottom }; }
    else if (anchor && anchor.clientX != null) pos = { x: anchor.clientX, y: anchor.clientY };
    const actions = new Map();
    let n = 0;
    const strip = (list) => list.filter(Boolean).map((it) => {
      if (it.type === 'separator' || it.type === 'header') return it;
      const o = { label: it.label, enabled: it.enabled !== false, accelerator: it.accelerator, type: it.type, checked: it.checked };
      if (it.submenu) o.submenu = strip(it.submenu);
      else { o.id = 'm' + (n++); actions.set(o.id, it.action); }
      return o;
    });
    const id = await Host.popupMenu(strip(items), pos);
    const fn = id && actions.get(id);
    if (fn) fn();
  },
};

const Dialogs = {
  alert(message, detail = '', type = 'warning') {
    Host.messageBox({ type, message, detail: detail || undefined, buttons: ['OK'] });
  },
  // Returns the index of the chosen button.
  ask(message, detail, buttons, opts = {}) {
    return Host.messageBox({ type: opts.type || 'question', message, detail: detail || undefined, buttons, defaultId: opts.defaultId || 0, cancelId: opts.cancelId ?? 1 });
  },
  confirm(message, detail, ok = 'OK') { return Dialogs.ask(message, detail, [ok, 'Cancel']) === 0; },
  // Save / Cancel / Don't Save → 'save' | 'cancel' | 'discard'
  saveChanges(name) {
    const r = Dialogs.ask(`Do you want to save the changes you made to “${name}”?`, 'Your changes will be lost if you don’t save them.',
      ['Save', 'Cancel', 'Don’t Save'], { type: 'warning', cancelId: 1 });
    return ['save', 'cancel', 'discard'][r];
  },
  // A small text prompt (Electron has no window.prompt). Resolves with the text or null.
  prompt(title, message = '', value = '', ok = 'OK', opts = {}) {
    return new Promise((resolve) => {
      const input = h('input', { class: 'vs-input', spellcheck: 'false', value });
      const close = (v) => { overlay.remove(); resolve(v); };
      const okBtn = h('button', { class: 'vs-button', onclick: () => { const v = input.value.trim(); close(v || null); } }, ok);
      const box = h('div', { class: 'modal' },
        h('div', { class: 'modal-title' }, title),
        message ? h('div', { class: 'modal-msg' }, message) : null,
        opts.multiline ? null : input,
        h('div', { class: 'modal-buttons' }, h('button', { class: 'vs-button secondary', onclick: () => close(null) }, 'Cancel'), okBtn));
      const overlay = h('div', { class: 'modal-overlay', onmousedown: (e) => { if (e.target === overlay) close(null); } }, box);
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') { e.preventDefault(); okBtn.click(); }
        if (e.key === 'Escape') { e.preventDefault(); close(null); }
        e.stopPropagation();
      });
      document.body.append(overlay);
      input.focus();
      const dot = value.lastIndexOf('.');
      if (dot > 0) input.setSelectionRange(0, dot); else input.select();
    });
  },
  // A modal with custom content. build(close) returns the body element.
  modal(title, build, width = 460) {
    return new Promise((resolve) => {
      const close = (v) => { overlay.remove(); document.removeEventListener('keydown', onKey, true); resolve(v); };
      const onKey = (e) => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(null); } };
      const box = h('div', { class: 'modal', style: `width:${width}px` }, h('div', { class: 'modal-title' }, title), build(close));
      const overlay = h('div', { class: 'modal-overlay', onmousedown: (e) => { if (e.target === overlay) close(null); } }, box);
      document.addEventListener('keydown', onKey, true);
      document.body.append(overlay);
      const f = box.querySelector('input, textarea, select');
      if (f) f.focus();
    });
  },
  openFiles(opts) { return Host.openDialog(opts); },
  saveFile(opts) { return Host.saveDialog(opts); },
};

// ---------------------------------------------------------------- Toast

let toastTimer = null;
function showToast(text) {
  let el = $('#toast');
  if (!el) { el = h('div', { id: 'toast' }); document.body.append(el); }
  el.textContent = text;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 2600);
}

// ---------------------------------------------------------------- Layout helpers

function splitter(el, axis, onDelta, onEnd) {
  el.addEventListener('mousedown', (e) => {
    e.preventDefault();
    let last = axis === 'x' ? e.clientX : e.clientY;
    el.classList.add('dragging');
    document.body.style.cursor = axis === 'x' ? 'col-resize' : 'row-resize';
    const move = (ev) => { const v = axis === 'x' ? ev.clientX : ev.clientY; onDelta(v - last); last = v; };
    const up = () => {
      el.classList.remove('dragging');
      document.body.style.cursor = '';
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      if (onEnd) onEnd();
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  });
}

// Replaces a container's children while keeping keyboard focus (and the caret) in a field with the same data-key.
function replaceKeepingFocus(container, children) {
  const a = document.activeElement;
  let key = null, s = null, e = null, scroll = [];
  if (a && container.contains(a) && a.dataset && a.dataset.key) {
    key = a.dataset.key;
    try { s = a.selectionStart; e = a.selectionEnd; } catch { /* not a text field */ }
  }
  container.querySelectorAll('[data-scroll-key]').forEach((el) => scroll.push([el.dataset.scrollKey, el.scrollTop, el.scrollLeft]));
  const top = container.scrollTop;
  container.replaceChildren(...children.flat().filter(Boolean));
  container.scrollTop = top;
  for (const [k, t, l] of scroll) { const el = container.querySelector(`[data-scroll-key="${k}"]`); if (el) { el.scrollTop = t; el.scrollLeft = l; } }
  if (key) {
    const n = container.querySelector(`[data-key="${CSS.escape(key)}"]`);
    if (n) { n.focus({ preventScroll: true }); try { if (s != null) n.setSelectionRange(s, e); } catch { /* ignore */ } }
  }
}

function copyText(s) { Host.clipboard.write(s); }

function debounce(fn, ms) {
  let t = null;
  return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
}

// rAF-coalesced callback
function frameScheduler(fn) {
  let queued = false;
  return () => { if (queued) return; queued = true; requestAnimationFrame(() => { queued = false; fn(); }); };
}

// ---------------------------------------------------------------- Fuzzy matching (completion and the command palette)

const Fuzzy = {
  // Higher is better; null when query is not a subsequence of text.
  score(query, text) {
    if (!query) return 0;
    const q = query.toLowerCase(), t = text.toLowerCase();
    let qi = 0, score = 0, last = -2, firstMatch = -1;
    for (let i = 0; i < t.length && qi < q.length; i++) {
      if (t[i] === q[qi]) {
        if (firstMatch < 0) firstMatch = i;
        let s = 1;
        if (i === last + 1) s += 8;
        if (i === 0) s += 8;
        else {
          const p = text[i - 1];
          if (p === '_' || p === '/' || p === '\\' || p === '.' || p === ' ' || p === '-' || (text[i] !== text[i].toLowerCase() && p === p.toLowerCase() && p !== p.toUpperCase())) s += 6;
        }
        score += s;
        last = i;
        qi++;
      }
    }
    if (qi !== q.length) return null;
    if (t.startsWith(q)) score += 20;
    if (text.startsWith(query)) score += 5;
    score -= Math.floor(Math.max(0, t.length - q.length) / 8);
    score -= Math.floor(Math.max(0, firstMatch) / 4);
    return score;
  },
};

// ---------------------------------------------------------------- Keyboard shortcuts

// Matches a KeyboardEvent against "Ctrl+Shift+F", "Alt+Up", "F12", "Ctrl+=" …  (Ctrl means Cmd on macOS).
function matchKey(e, spec) {
  const parts = spec.split('+');
  let key = parts.pop();
  if (key === '' && spec.endsWith('++')) key = '+';
  const want = { ctrl: false, shift: false, alt: false };
  for (const p of parts) want[p.toLowerCase()] = true;
  const ctrl = IS_MAC ? (e.metaKey || e.ctrlKey) : e.ctrlKey;
  if (ctrl !== want.ctrl || e.shiftKey !== want.shift || e.altKey !== want.alt) return false;
  const k = e.key;
  const map = { Up: 'ArrowUp', Down: 'ArrowDown', Left: 'ArrowLeft', Right: 'ArrowRight', Enter: 'Enter', Space: ' ', Esc: 'Escape', Delete: 'Delete', Backspace: 'Backspace', Tab: 'Tab' };
  if (map[key]) return k === map[key];
  if (/^F\d+$/.test(key)) return k === key;
  if (key.length === 1) {
    if (k.toLowerCase() === key.toLowerCase()) return true;
    // Use the physical key for digits and punctuation (Shift changes e.key).
    const codes = { '=': 'Equal', '-': 'Minus', '0': 'Digit0', '1': 'Digit1', '2': 'Digit2', '/': 'Slash', '\\': 'Backslash', '[': 'BracketLeft', ']': 'BracketRight', ',': 'Comma', '.': 'Period', '`': 'Backquote' };
    if (codes[key] && e.code === codes[key]) return true;
    if (/[a-z]/i.test(key) && e.code === 'Key' + key.toUpperCase()) return true;
  }
  return false;
}
// Display form of a shortcut for menus and tooltips.
const keyLabel = (spec) => (IS_MAC ? spec.replace(/Ctrl/g, 'Cmd') : spec);

if (typeof module !== 'undefined') module.exports = {};
