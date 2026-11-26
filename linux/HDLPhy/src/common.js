'use strict';
/* global THEMES */
// Shared page helpers: DOM building, settings, menus, dialogs, toasts, formatting.

const Host = window.host;
const PathUtil = Host.path;
const IS_MAC = Host.platform === 'darwin';
const IS_WIN = Host.platform === 'win32';
const MOD = IS_MAC ? 'Cmd' : 'Ctrl';
const REVEAL_LABEL = IS_WIN ? 'Reveal in File Explorer' : IS_MAC ? 'Reveal in Finder' : 'Show in File Manager';

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
const icon = (name, extra = '', title = null) => h('span', { class: `codicon codicon-${name} ${extra}`, title });
const $ = (sel, el = document) => el.querySelector(sel);

const store = {
  get(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { if (v === undefined) localStorage.removeItem(k); else localStorage.setItem(k, JSON.stringify(v)); } catch { /* ignore */ } },
};

const Prefs = {
  defaults: { themeID: 'darkModern', restoreProject: true, schematicMaxCells: 2500, threads: 8 },
  get(k) { return store.get('pref.' + k, Prefs.defaults[k]); },
  set(k, v) { store.set('pref.' + k, v); },
};
const currentTheme = () => THEMES[Prefs.get('themeID')] || THEMES.darkModern;

const Paths = {
  tilde(p) {
    const home = Host.launch.home;
    if (!p || !home) return p || '';
    if (p === home) return '~';
    if (p.startsWith(home + PathUtil.sep)) return '~' + p.slice(home.length);
    return p;
  },
};

// Native popup menu from item descriptions; actions run in the page.
const Menus = {
  async popup(items, ev) {
    const actions = new Map();
    let n = 1;
    const conv = (list) => list.filter(Boolean).map((it) => {
      if (it.type === 'separator' || it.type === 'header') return it;
      const o = { label: it.label, enabled: it.enabled, accelerator: it.accelerator, type: it.checked != null ? 'checkbox' : undefined, checked: it.checked };
      if (it.submenu) o.submenu = conv(it.submenu);
      else { o.id = n++; actions.set(o.id, it.action); }
      return o;
    });
    let pos = null;
    if (ev && ev.currentTarget && ev.currentTarget.getBoundingClientRect && ev.type === 'click') {
      const r = ev.currentTarget.getBoundingClientRect();
      pos = { x: r.left, y: r.bottom + 2 };
    } else if (ev && ev.clientX != null) pos = { x: ev.clientX, y: ev.clientY };
    const id = await Host.popupMenu(conv(items), pos);
    const fn = id != null && actions.get(id);
    if (fn) fn();
  },
};

let toastTimer = null;
function showToast(msg, ms = 2600) {
  let t = document.getElementById('toast');
  if (!t) { t = h('div', { id: 'toast' }); document.body.append(t); }
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), ms);
}

// A small modal dialog. buttons: [{ label, primary, action }]; returns a close function.
function modal(title, body, buttons, msg = null) {
  const overlay = h('div', { class: 'modal-overlay' });
  const close = () => { overlay.remove(); document.removeEventListener('keydown', onKey, true); };
  const onKey = (e) => { if (e.key === 'Escape') { e.preventDefault(); close(); } };
  const btns = buttons.map((b) => h('button', { class: 'vs-button' + (b.primary ? '' : ' secondary'), onclick: () => { if (b.action && b.action() === false) return; close(); } }, b.label));
  overlay.append(h('div', { class: 'modal' }, h('div', { class: 'modal-title' }, title), msg ? h('div', { class: 'modal-msg' }, msg) : null,
    h('div', { class: 'modal-body' }, body), h('div', { class: 'modal-buttons' }, btns)));
  overlay.addEventListener('mousedown', (e) => { if (e.target === overlay) close(); });
  document.addEventListener('keydown', onKey, true);
  document.body.append(overlay);
  return close;
}

function copyText(s) { Host.clipboard.write(s); showToast('Copied'); }

// Draggable splitter between two panes: get() returns the current size, set(px) applies it.
function splitter(dir, get, set, invert = false) {
  const el = h('div', { class: 'splitter ' + (dir === 'v' ? 'v' : 'h') });
  el.addEventListener('mousedown', (e) => {
    e.preventDefault();
    const start = dir === 'v' ? e.clientX : e.clientY;
    const s0 = get();
    el.classList.add('dragging');
    const move = (ev) => { const d = (dir === 'v' ? ev.clientX : ev.clientY) - start; set(s0 + (invert ? -d : d)); };
    const up = () => { el.classList.remove('dragging'); window.removeEventListener('mousemove', move); window.removeEventListener('mouseup', up); };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  });
  return el;
}

const Fmt = {
  num(v, digits = 2) {
    if (v == null || v === '' || Number.isNaN(Number(v))) return '—';
    const n = Number(v);
    if (Math.abs(n) >= 1e6) return n.toExponential(2);
    return n.toLocaleString(undefined, { maximumFractionDigits: digits });
  },
  // value in watts -> mW / uW
  power(w) {
    if (w == null || Number.isNaN(Number(w))) return '—';
    const n = Number(w);
    if (Math.abs(n) >= 1e-3) return (n * 1e3).toFixed(3) + ' mW';
    if (Math.abs(n) >= 1e-6) return (n * 1e6).toFixed(2) + ' µW';
    return (n * 1e9).toFixed(1) + ' nW';
  },
  secs(s) {
    if (s == null) return '';
    if (s < 60) return s.toFixed(1) + ' s';
    return Math.floor(s / 60) + ' min ' + Math.round(s % 60) + ' s';
  },
};

if (typeof module !== 'undefined') module.exports = {};
