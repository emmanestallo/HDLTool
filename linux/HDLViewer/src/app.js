'use strict';
/* global THEMES, TimeScale, computeTicks, frequency, formatValue, isUnknown, isHighZ, RADIXES, DISPLAY_MODES, DISPLAY_SHORT, INTERPOLATIONS,
   ROW_HEIGHTS, analogModes, analogLevel, analogRange, levelRange, formatAnalog, fmtG,
   lastIndexAtOrBefore, firstIndexAtOrAfter, valueAt, rawValue, scopeColor, varColor, varLetter */

const ROW_H = 26;
const api = window.host;
const $ = (sel, el = document) => el.querySelector(sel);

function h(tag, props, ...children) {
  const el = document.createElement(tag);
  if (props) {
    for (const [k, v] of Object.entries(props)) {
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'style') el.style.cssText = v;
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else el.setAttribute(k, v === true ? '' : v);
    }
  }
  for (const c of children.flat()) if (c != null && c !== false) el.append(c.nodeType ? c : String(c));
  return el;
}
const icon = (name, extra = '') => h('span', { class: `codicon codicon-${name} ${extra}` });

const store = {
  get(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* ignore */ } },
};

const basename = (p) => p.split(/[\\/]/).pop();
const dirname = (p) => { const i = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\')); return i > 0 ? p.slice(0, i) : p; };
let uidCounter = 1;
const uid = () => 'u' + (uidCounter++);
const MOD = () => (S.platform === 'darwin' ? 'Cmd' : 'Ctrl');

// ---------------------------------------------------------------- State

const S = {
  docs: [],
  activeId: null,
  sidebarMode: 'explorer',
  search: '',
  themeId: store.get('themeID', 'darkModern'),
  autoReload: store.get('autoReload', true),
  recent: store.get('recent', []),
  sidebarW: store.get('sidebarW', 280),
  nameW: store.get('nameW', 220),
  valueW: store.get('valueW', 110),
  platform: 'win32',
  example: null,
};
let theme = THEMES[S.themeId] || THEMES.darkModern;
const active = () => S.docs.find((d) => d.id === S.activeId) || null;

class Doc {
  constructor(path) {
    this.id = uid();
    this.path = path;
    this.name = basename(path);
    this.file = null;
    this.loading = false;
    this.progress = 0;
    this.error = null;
    this.displayed = [];      // { id, v, radix, color }
    this.selection = new Set();
    this.anchor = null;
    this.start = 0;
    this.tpp = 1;
    this.width = 0;
    this.cursor = null;
    this.marker = null;
    this.hover = null;
    this.hoverX = null;
    this.zoomBox = null;
    this.selectedScope = null;
    this.expanded = new Set();
    this.needsFit = true;
    this.scrollTop = 0;
    this.mtime = 0;
  }

  get begin() { return this.file ? this.file.startTime : 0; }
  get end() { return this.file ? this.file.endTime : 0; }
  get span() { return Math.max(this.end - this.begin, 1); }
  timeAt(x) { return this.start + x * this.tpp; }
  xAt(t) { return (t - this.start) / this.tpp; }

  fit() {
    if (!this.file || this.width < 20) { this.needsFit = true; return; }
    this.needsFit = false;
    this.tpp = this.span / (this.width - 12);
    this.start = this.begin;
    this.clamp();
  }
  clampTpp(v) {
    const max = this.span * 4 / Math.max(this.width, 1);
    return Math.min(Math.max(v, 1e-4), Math.max(max, 1e-4));
  }
  clamp() {
    this.tpp = this.clampTpp(this.tpp);
    const vis = this.width * this.tpp;
    const lo = this.begin - vis * 0.05;
    const hi = Math.max(lo, this.end - vis * 0.9);
    this.start = Math.min(Math.max(this.start, lo), hi);
  }
  zoom(factor, anchorX) {
    if (!this.file || !this.width) return;
    let ax = anchorX ?? this.width / 2;
    if (anchorX == null && this.cursor != null) {
      const cx = this.xAt(this.cursor);
      if (cx >= 0 && cx <= this.width) ax = cx;
    }
    const t = this.timeAt(ax);
    this.tpp = this.clampTpp(this.tpp * factor);
    this.start = t - ax * this.tpp;
    this.clamp();
  }
  zoomRange(a, b) {
    const lo = Math.min(a, b), hi = Math.max(a, b);
    if (hi - lo <= 2) return;
    const t0 = this.timeAt(lo), t1 = this.timeAt(hi);
    this.tpp = this.clampTpp((t1 - t0) / Math.max(this.width, 1));
    this.start = t0;
    this.clamp();
  }
  pan(dx) { this.start += dx * this.tpp; this.clamp(); }
  ensureVisible(t) {
    const x = this.xAt(t);
    if (x < 0 || x > this.width) { this.start = t - this.width * this.tpp / 2; this.clamp(); }
  }

  trace(sig) { return this.file.traces[sig.v.trace]; }
  isDisplayed(v) { return this.displayed.some((d) => d.v === v); }

  saveLayout() {
    store.set('layout:' + this.path, this.displayed.map((d) => ({ path: d.v.fullPath, radix: d.radix, color: d.color ?? -1, display: d.display, interp: d.interp, height: d.height })));
  }
}

function defaultRadix(v) {
  if (['integer', 'int', 'longint', 'shortint'].includes(v.kind)) return 'signed';
  if (v.kind === 'parameter') return 'unsigned';
  return 'hex';
}
const makeSig = (v, radix, color) => ({ id: uid(), v, radix: radix || defaultRadix(v), color: color ?? null, display: 'digital', interp: 'step', height: 1 });
const isAnalog = (sig) => sig.display && sig.display !== 'digital';
const rowH = (sig) => ROW_H * (sig.height || 1);
// Top of each row (rows can have different heights); tops[n] is the total height.
function rowTops(doc) {
  const tops = [0];
  for (const d of doc.displayed) tops.push(tops[tops.length - 1] + rowH(d));
  return tops;
}
function rowAt(doc, y) {
  let top = 0;
  for (let i = 0; i < doc.displayed.length; i++) { top += rowH(doc.displayed[i]); if (y < top) return i; }
  return -1;
}

// ---------------------------------------------------------------- Parsing worker

const worker = new Worker('parse-worker.js');
const pending = new Map();
let jobId = 1;
worker.onmessage = (e) => {
  const { id, progress, result, error } = e.data;
  const job = pending.get(id);
  if (!job) return;
  if (!result && !error) { job.onProgress(progress); return; }
  pending.delete(id);
  if (error) job.reject(new Error(error)); else job.resolve(result);
};
function parseInWorker(bytes, onProgress) {
  return new Promise((resolve, reject) => {
    const id = jobId++;
    pending.set(id, { resolve, reject, onProgress });
    const data = (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength) ? bytes : bytes.slice();
    worker.postMessage({ id, buffer: data.buffer }, [data.buffer]);
  });
}

// ---------------------------------------------------------------- Opening files

async function openFiles(paths) {
  for (const p of paths) {
    if (!(await api.fileExists(p))) continue;
    let doc = S.docs.find((d) => d.path === p);
    if (doc) {
      S.activeId = doc.id;
      reload(doc);
    } else {
      doc = new Doc(p);
      S.docs.push(doc);
      S.activeId = doc.id;
      load(doc);
    }
    S.recent = [p, ...S.recent.filter((r) => r !== p)].slice(0, 12);
    store.set('recent', S.recent);
  }
  renderAll();
}

async function showOpenDialog() {
  const paths = await api.openDialog();
  if (paths.length) openFiles(paths);
}

function reload(doc) { if (doc && !doc.loading) load(doc); }

async function load(doc) {
  doc.loading = true;
  doc.progress = 0;
  renderAll();
  try {
    const { data, mtime } = await api.readFile(doc.path);
    const result = await parseInWorker(data, (p) => {
      doc.progress = p;
      if (doc.id === S.activeId) renderProgress();
    });
    finishLoad(doc, result, mtime);
  } catch (err) {
    doc.loading = false;
    if (!doc.file) doc.error = err.message || String(err);
    renderAll();
  }
}

function finishLoad(doc, r, mtime) {
  const isReload = !!doc.file;
  const scopes = new Map();
  (function index(s) { scopes.set(s.id, s); s.children.forEach(index); })(r.root);
  doc.file = {
    root: r.root, vars: r.vars, traces: r.traces, scopes,
    ts: new TimeScale(r.timescale), startTime: r.startTime, endTime: r.endTime,
  };
  doc.loading = false;
  doc.error = null;
  doc.mtime = mtime;

  const byPath = new Map();
  for (const v of r.vars) if (!byPath.has(v.fullPath)) byPath.set(v.fullPath, v);

  if (isReload) {
    doc.displayed = doc.displayed.filter((d) => byPath.has(d.v.fullPath)).map((d) => ({ ...d, v: byPath.get(d.v.fullPath) }));
    const ids = new Set(doc.displayed.map((d) => d.id));
    doc.selection = new Set([...doc.selection].filter((id) => ids.has(id)));
  } else {
    const saved = store.get('layout:' + doc.path, null);
    const restored = (saved || []).filter((e) => byPath.has(e.path))
      .map((e) => {
        const sig = makeSig(byPath.get(e.path), e.radix, e.color >= 0 ? e.color : null);
        const tr = r.traces[sig.v.trace];
        if (e.display && (e.display === 'digital' || analogModes(tr).includes(e.display))) sig.display = e.display;
        if (e.interp === 'step' || e.interp === 'linear') sig.interp = e.interp;
        if (e.height) sig.height = Math.max(1, Math.min(+e.height || 1, 12));
        return sig;
      });
    if (restored.length) doc.displayed = restored;
    else {
      const scope = firstScopeWithVars(r.root);
      if (scope) doc.displayed = scope.vars.slice(0, 48).map((id) => makeSig(r.vars[id]));
      doc.saveLayout();
    }
  }

  if (doc.selectedScope == null || !scopes.has(doc.selectedScope)) {
    const s = firstScopeWithVars(r.root);
    doc.selectedScope = s ? s.id : (r.root.children[0] || {}).id ?? null;
  }
  if (!doc.expanded.size) r.root.children.forEach((s) => doc.expanded.add(s.id));

  if (doc.needsFit || !isReload) doc.fit(); else doc.clamp();
  api.watch(doc.path, mtime);
  api.setMtime(doc.path, mtime);
  if (launch && launch.cursor != null && doc.id === S.activeId) { doc.cursor = launch.cursor; launch.cursor = null; }
  if (launch && launch.marker != null && doc.id === S.activeId) { doc.marker = launch.marker; launch.marker = null; }
  renderAll();
}

function firstScopeWithVars(root) {
  const queue = [root];
  while (queue.length) {
    const s = queue.shift();
    if (s.vars.length && s !== root) return s;
    queue.push(...s.children);
  }
  return root.vars.length ? root : null;
}

function closeDoc(doc) {
  const i = S.docs.indexOf(doc);
  if (i < 0) return;
  S.docs.splice(i, 1);
  api.unwatch(doc.path);
  if (S.activeId === doc.id) S.activeId = S.docs.length ? S.docs[Math.min(i, S.docs.length - 1)].id : null;
  renderAll();
}

// ---------------------------------------------------------------- Signal operations

function addSignals(doc, vars, beforeId) {
  const sigs = vars.map((v) => makeSig(v));
  if (!sigs.length) return;
  const i = beforeId ? doc.displayed.findIndex((d) => d.id === beforeId) : -1;
  if (i >= 0) doc.displayed.splice(i, 0, ...sigs); else doc.displayed.push(...sigs);
  doc.selection = new Set(sigs.map((s) => s.id));
  doc.saveLayout();
  renderSidebarLists();
  renderRows();
}

function removeSignals(doc, ids) {
  if (!ids.size) return;
  doc.displayed = doc.displayed.filter((d) => !ids.has(d.id));
  ids.forEach((id) => doc.selection.delete(id));
  doc.saveLayout();
  renderSidebarLists();
  renderRows();
}

function moveSelection(doc, delta) {
  if (!doc.selection.size) return;
  const arr = doc.displayed;
  const idx = arr.map((d, i) => (doc.selection.has(d.id) ? i : -1)).filter((i) => i >= 0);
  if (delta < 0) {
    if (idx[0] === 0) return;
    for (const i of idx) [arr[i - 1], arr[i]] = [arr[i], arr[i - 1]];
  } else {
    if (idx[idx.length - 1] === arr.length - 1) return;
    for (const i of idx.reverse()) [arr[i + 1], arr[i]] = [arr[i], arr[i + 1]];
  }
  doc.saveLayout();
  renderRows();
}

function moveIds(doc, ids, beforeId) {
  if (!ids.size || (beforeId && ids.has(beforeId))) return;
  const moving = doc.displayed.filter((d) => ids.has(d.id));
  const rest = doc.displayed.filter((d) => !ids.has(d.id));
  let at = beforeId ? rest.findIndex((d) => d.id === beforeId) : -1;
  if (at < 0) at = rest.length;
  rest.splice(at, 0, ...moving);
  doc.displayed = rest;
  doc.saveLayout();
  renderRows();
}

function selectSig(doc, id, e) {
  const mod = e && (e.ctrlKey || e.metaKey);
  if (mod) {
    if (doc.selection.has(id)) doc.selection.delete(id); else doc.selection.add(id);
    doc.anchor = id;
  } else if (e && e.shiftKey && doc.anchor) {
    const a = doc.displayed.findIndex((d) => d.id === doc.anchor);
    const b = doc.displayed.findIndex((d) => d.id === id);
    if (a >= 0 && b >= 0) doc.selection = new Set(doc.displayed.slice(Math.min(a, b), Math.max(a, b) + 1).map((d) => d.id));
  } else {
    doc.selection = new Set([id]);
    doc.anchor = id;
  }
  renderSelection();
}

function moveSelectionCursor(doc, delta, extend) {
  if (!doc.displayed.length) return;
  let cur = -1;
  doc.displayed.forEach((d, i) => { if (doc.selection.has(d.id)) cur = i; });
  const next = cur < 0 ? 0 : Math.min(Math.max(cur + delta, 0), doc.displayed.length - 1);
  const id = doc.displayed[next].id;
  if (extend) doc.selection.add(id); else { doc.selection = new Set([id]); doc.anchor = id; }
  const rows = $('.rows');
  if (rows) {
    const tops = rowTops(doc);
    const y = tops[next], hh = tops[next + 1] - y;
    if (y < rows.scrollTop) rows.scrollTop = y;
    else if (y + hh > rows.scrollTop + rows.clientHeight) rows.scrollTop = y + hh - rows.clientHeight;
  }
  renderSelection();
}

function jumpTransition(doc, forward) {
  if (!doc.file) return;
  const sigs = doc.displayed.filter((d) => doc.selection.has(d.id));
  const traces = (sigs.length ? sigs : doc.displayed).map((d) => doc.trace(d));
  if (!traces.length) return;
  const c = doc.cursor ?? (forward ? doc.begin - 1 : doc.end + 1);
  let target = null;
  for (const tr of traces) {
    if (forward) {
      const i = firstIndexAtOrAfter(tr, Math.floor(c) + 1);
      if (i < tr.n) target = target == null ? tr.times[i] : Math.min(target, tr.times[i]);
    } else {
      const i = firstIndexAtOrAfter(tr, Math.ceil(c)) - 1;
      if (i >= 0) target = target == null ? tr.times[i] : Math.max(target, tr.times[i]);
    }
  }
  if (target != null) { doc.cursor = target; doc.ensureVisible(target); viewChanged(); }
}

function copyText(s) {
  if (navigator.clipboard) navigator.clipboard.writeText(s).catch(() => fallbackCopy(s)); else fallbackCopy(s);
}
function fallbackCopy(s) {
  const ta = h('textarea', { style: 'position:fixed;opacity:0' });
  ta.value = s; document.body.append(ta); ta.select(); document.execCommand('copy'); ta.remove();
}

// ---------------------------------------------------------------- Menus

const radioTheme = () => Object.entries(THEMES).map(([id, t]) => ({ id: 'theme:' + id, label: t.name, type: 'radio', checked: S.themeId === id }));

function appMenuItems() {
  const doc = active();
  const m = MOD();
  return [
    { id: 'open', label: 'Open Waveform…', accelerator: `${m}+O` },
    { label: 'Open Recent', enabled: S.recent.length > 0, submenu: [
      ...S.recent.map((p, i) => ({ id: 'recent:' + i, label: basename(p) + '   —   ' + dirname(p) })),
      { type: 'separator' }, { id: 'clear-recent', label: 'Clear Recent' }] },
    { id: 'example', label: 'Open Example', enabled: !!S.example },
    { id: 'reload', label: 'Reload', accelerator: `${m}+R`, enabled: !!doc },
    { id: 'close-tab', label: 'Close Tab', accelerator: `${m}+W`, enabled: !!doc },
    { type: 'separator' },
    { id: 'zoom-in', label: 'Zoom In', accelerator: `${m}+=`, enabled: !!doc },
    { id: 'zoom-out', label: 'Zoom Out', accelerator: `${m}+-`, enabled: !!doc },
    { id: 'zoom-fit', label: 'Zoom to Fit', accelerator: `${m}+0`, enabled: !!doc },
    { id: 'next', label: 'Next Transition', accelerator: 'Right', enabled: !!doc },
    { id: 'prev', label: 'Previous Transition', accelerator: 'Left', enabled: !!doc },
    { id: 'marker', label: 'Place Marker at Cursor', accelerator: 'M', enabled: !!(doc && doc.cursor != null) },
    { id: 'clear-marker', label: 'Clear Marker', enabled: !!(doc && doc.marker != null) },
    { type: 'separator' },
    { id: 'remove-selected', label: 'Remove Selected Signals', accelerator: 'Delete', enabled: !!(doc && doc.selection.size) },
    { id: 'remove-all', label: 'Remove All Signals', enabled: !!(doc && doc.displayed.length) },
    { type: 'separator' },
    { id: 'toggle-sidebar', label: 'Toggle Sidebar', accelerator: `${m}+B` },
    { id: 'search', label: 'Search Signals', accelerator: `${m}+Shift+F` },
    { label: 'Color Theme', submenu: radioTheme() },
    { id: 'auto-reload', label: 'Auto-Reload When File Changes', type: 'checkbox', checked: S.autoReload },
  ];
}

async function popup(items, anchorEl) {
  let pos = null;
  if (anchorEl) { const r = anchorEl.getBoundingClientRect(); pos = { x: r.left, y: r.bottom }; }
  const id = await api.popupMenu(items, pos);
  if (id) runCommand(id);
}

function runCommand(id, arg) {
  const doc = active();
  if (id.startsWith('theme:')) return setTheme(id.slice(6));
  if (id.startsWith('recent:')) return openFiles([S.recent[+id.slice(7)]]);
  switch (id) {
    case 'open': return showOpenDialog();
    case 'example': return S.example && openFiles([S.example]);
    case 'clear-recent': S.recent = []; store.set('recent', []); return renderContent();
    case 'reload': return reload(doc);
    case 'close-tab': return doc && closeDoc(doc);
    case 'toggle-sidebar': S.sidebarMode = S.sidebarMode ? null : 'explorer'; return renderAll();
    case 'search':
      S.sidebarMode = 'search'; renderAll();
      setTimeout(() => { const i = $('#sidebar input'); if (i) { i.focus(); i.select(); } }, 0);
      return;
    case 'auto-reload': S.autoReload = !S.autoReload; store.set('autoReload', S.autoReload); return renderStatus();
  }
  if (!doc || !doc.file) return;
  switch (id) {
    case 'zoom-in': doc.zoom(0.5); break;
    case 'zoom-out': doc.zoom(2); break;
    case 'zoom-fit': doc.fit(); break;
    case 'next': return jumpTransition(doc, true);
    case 'prev': return jumpTransition(doc, false);
    case 'marker': doc.marker = doc.cursor; break;
    case 'clear-marker': doc.marker = null; break;
    case 'remove-selected': return removeSignals(doc, new Set(doc.selection));
    case 'remove-all': return removeSignals(doc, new Set(doc.displayed.map((d) => d.id)));
    case 'select-all': doc.selection = new Set(doc.displayed.map((d) => d.id)); return renderSelection();
    default: return;
  }
  viewChanged();
}

function setTheme(id) {
  if (!THEMES[id]) return;
  S.themeId = id;
  store.set('themeID', id);
  applyTheme();
  renderAll();
}

function applyTheme() {
  theme = THEMES[S.themeId] || THEMES.darkModern;
  const root = document.documentElement.style;
  for (const [k, v] of Object.entries(theme)) if (typeof v === 'string') root.setProperty('--' + k, v);
  root.colorScheme = theme.dark ? 'dark' : 'light';
  api.setTheme({ dark: theme.dark, editor: theme.editor, titleBar: theme.titleBar, titleFG: theme.titleFG });
}

function signalMenu(doc, sig) {
  const ids = doc.selection.has(sig.id) ? new Set(doc.selection) : new Set([sig.id]);
  const tr = doc.trace(sig);
  const items = [];
  const modes = analogModes(tr);
  if (modes.length) {
    items.push({ label: 'Display', submenu: DISPLAY_MODES.filter(([m]) => m === 'digital' || modes.includes(m)).map(([m, label]) => ({ id: 'display:' + m, label, type: 'radio', checked: sig.display === m })) });
    if (isAnalog(sig)) items.push({ label: 'Interpolation', submenu: INTERPOLATIONS.map(([m, label]) => ({ id: 'interp:' + m, label, type: 'radio', checked: sig.interp === m })) });
  }
  items.push({ label: 'Row Height', submenu: ROW_HEIGHTS.map((n) => ({ id: 'height:' + n, label: n + '×', type: 'radio', checked: (sig.height || 1) === n })) });
  if (tr.type === 'vec') {
    items.push({ label: 'Radix', submenu: RADIXES.map(([r, label]) => ({ id: 'radix:' + r, label, type: 'radio', checked: sig.radix === r })) });
  }
  items.push({ label: 'Color', submenu: [
    { id: 'color:-1', label: 'Default', type: 'radio', checked: sig.color == null },
    ...theme.palette.map(([name], i) => ({ id: 'color:' + i, label: name, type: 'radio', checked: sig.color === i })),
  ] });
  items.push({ type: 'separator' },
    { id: 'up', label: 'Move Up', accelerator: 'Alt+Up' },
    { id: 'down', label: 'Move Down', accelerator: 'Alt+Down' },
    { type: 'separator' },
    { id: 'copy-name', label: 'Copy Name' },
    { id: 'copy-value', label: 'Copy Value at Cursor', enabled: doc.cursor != null },
    { type: 'separator' },
    { id: 'remove', label: ids.size > 1 ? `Remove ${ids.size} Signals` : 'Remove', accelerator: 'Delete' });

  api.popupMenu(items).then((id) => {
    if (!id) return;
    if (id.startsWith('display:')) {
      const m = id.slice(8);
      doc.displayed.forEach((d) => {
        if (!ids.has(d.id)) return;
        if (m !== 'digital' && !analogModes(doc.trace(d)).includes(m)) return;
        d.display = m;
        if (m !== 'digital' && (d.height || 1) === 1) d.height = 4;
        if (m === 'digital' && d.height === 4) d.height = 1;
      });
    } else if (id.startsWith('interp:')) {
      const m = id.slice(7);
      doc.displayed.forEach((d) => { if (ids.has(d.id)) d.interp = m; });
    } else if (id.startsWith('height:')) {
      const n = +id.slice(7);
      doc.displayed.forEach((d) => { if (ids.has(d.id)) d.height = Math.max(1, Math.min(n, 12)); });
    } else if (id.startsWith('radix:')) {
      const r = id.slice(6);
      doc.displayed.forEach((d) => { if (ids.has(d.id)) d.radix = r; });
    } else if (id.startsWith('color:')) {
      const c = +id.slice(6);
      doc.displayed.forEach((d) => { if (ids.has(d.id)) d.color = c < 0 ? null : c; });
    } else if (id === 'up' || id === 'down') {
      doc.selection = ids; moveSelection(doc, id === 'up' ? -1 : 1); return;
    } else if (id === 'copy-name') {
      return copyText(sig.v.fullPath);
    } else if (id === 'copy-value') {
      const v = valueAt(tr, doc.cursor);
      const level = isAnalog(sig) && v != null ? analogLevel(v, tr, sig.display) : null;
      if (level != null) copyText(formatAnalog(level, tr, sig.display));
      else if (v != null) copyText(formatValue(v, tr, sig.radix));
      return;
    } else if (id === 'remove') {
      return removeSignals(doc, ids);
    }
    doc.saveLayout();
    renderRows();
  });
}

// ---------------------------------------------------------------- Rendering: chrome

function renderAll() {
  document.body.classList.toggle('no-sidebar', !S.sidebarMode);
  document.querySelectorAll('.ab-item[data-mode]').forEach((b) => b.classList.toggle('active', b.dataset.mode === S.sidebarMode));
  const doc = active();
  const title = doc ? `${doc.name} — HDL Viewer` : 'HDL Viewer';
  $('#title').textContent = title;
  document.title = title;
  api.setTitle(title);
  renderTabs();
  renderSidebar();
  renderContent();
  renderStatus();
}

function renderTabs() {
  const el = $('#tabs');
  el.replaceChildren(...S.docs.map((doc) => {
    const tab = h('div', {
      class: 'tab' + (doc.id === S.activeId ? ' active' : ''), title: doc.path,
      onmousedown: (e) => { if (e.button === 1) { e.preventDefault(); closeDoc(doc); } },
      onclick: () => { if (S.activeId !== doc.id) { S.activeId = doc.id; renderAll(); } },
    },
    icon('pulse', 'icon'),
    h('span', null, doc.name),
    doc.loading ? icon('loading', 'spin')
      : h('button', { class: 'close codicon codicon-close', title: `Close (${MOD()}+W)`,
        onclick: (e) => { e.stopPropagation(); closeDoc(doc); } }));
    return tab;
  }));
}

function renderStatus() {
  const doc = active();
  const items = [h('div', { class: 'sb-item sb-accent' }, icon('pulse'), 'VCD')];
  if (doc && doc.file) {
    const ts = doc.file.ts;
    items.push(
      h('div', { class: 'sb-item' }, icon('watch'), `Timescale ${ts}`),
      h('div', { class: 'sb-item' }, icon('list-flat'), `${doc.displayed.length} / ${doc.file.vars.length} signals`),
      h('div', { class: 'sb-item' }, icon('debug-stop'), `End ${ts.format(doc.end)}`),
      h('div', { class: 'sb-spacer' }));
    if (doc.hover != null) items.push(h('div', { class: 'sb-item sb-dim' }, icon('target'), ts.format(doc.hover)));
    if (doc.cursor != null) items.push(h('div', { class: 'sb-item' }, icon('debug-breakpoint-function'), `Cursor ${ts.format(doc.cursor)}`));
    if (doc.marker != null) {
      items.push(h('div', { class: 'sb-item' }, icon('pinned'), `Marker ${ts.format(doc.marker)}`));
      if (doc.cursor != null) {
        const d = Math.abs(doc.cursor - doc.marker);
        const f = frequency(ts.seconds(d));
        items.push(h('div', { class: 'sb-item' }, icon('arrow-both'), `Δ ${ts.format(d)}${f ? `  (${f})` : ''}`));
      }
    }
  } else {
    items.push(h('div', { class: 'sb-spacer' }));
  }
  if (S.autoReload) items.push(h('div', { class: 'sb-item', title: 'The waveform reloads when the file changes on disk' }, icon('sync'), 'Auto-Reload'));
  $('#statusbar').replaceChildren(...items);
}

let statusQueued = false;
function scheduleStatus() {
  if (statusQueued) return;
  statusQueued = true;
  requestAnimationFrame(() => { statusQueued = false; renderStatus(); });
}

// ---------------------------------------------------------------- Rendering: sidebar

let sidebarKey = '';
let explorerFilter = '';
let hierOpen = true, signalsOpen = true;

function renderSidebar() {
  const doc = active();
  const key = `${S.sidebarMode}|${doc ? doc.id : ''}|${doc && doc.file ? 'f' : ''}|${hierOpen}|${signalsOpen}`;
  if (key === sidebarKey) { renderSidebarLists(); return; }
  sidebarKey = key;
  const sb = $('#sidebar');
  sb.replaceChildren();
  if (!S.sidebarMode) return;
  sb.append(h('div', { class: 'sb-title' }, S.sidebarMode === 'search' ? 'SEARCH' : 'EXPLORER'));

  if (!doc || !doc.file) {
    sb.append(h('div', { class: 'sidebar-empty' },
      h('div', null, 'You have not opened a waveform yet.'),
      h('button', { class: 'vs-button', onclick: showOpenDialog }, 'Open Waveform'),
      h('div', { class: 'dim' }, 'You can also drag a .vcd file into the window.')));
    return;
  }

  if (S.sidebarMode === 'search') {
    const input = h('input', { placeholder: 'Search all signals', spellcheck: 'false',
      oninput: (e) => { S.search = e.target.value; renderSidebarLists(); } });
    input.value = S.search;
    sb.append(h('div', { class: 'filter' }, icon('search'), input),
      h('div', { class: 'result-count', id: 'resultCount' }),
      h('div', { class: 'scroll vlist', id: 'searchList' }));
  } else {
    const hdr = (title, open, toggle, sub, trailing) => h('div', { class: 'section-header', onclick: toggle },
      icon(open ? 'chevron-down' : 'chevron-right'), h('span', null, title),
      sub ? h('span', { class: 'sub', id: 'scopeSub' }, sub) : null,
      h('span', { class: 'grow' }), trailing || null);
    sb.append(hdr('HIERARCHY', hierOpen, () => { hierOpen = !hierOpen; renderSidebar(); }));
    if (hierOpen) sb.append(h('div', { class: 'scroll hier', id: 'hierList', style: signalsOpen ? 'height:36%' : 'flex:1' }));
    const addAll = h('button', { class: 'icon-btn codicon codicon-add', title: 'Add all signals in scope',
      onclick: (e) => {
        e.stopPropagation();
        const vars = currentScopeVars(doc).filter((v) => !doc.isDisplayed(v));
        addSignals(doc, vars);
      } });
    sb.append(hdr('SIGNALS', signalsOpen, () => { signalsOpen = !signalsOpen; renderSidebar(); }, ' ', addAll));
    if (signalsOpen) {
      const input = h('input', { placeholder: 'Filter signals', spellcheck: 'false',
        oninput: (e) => { explorerFilter = e.target.value; renderSidebarLists(); } });
      input.value = explorerFilter;
      sb.append(h('div', { class: 'filter' }, icon('filter'), input), h('div', { class: 'scroll vlist', id: 'varList' }));
    }
  }
  renderSidebarLists();
}

function currentScopeVars(doc) {
  const s = doc.file.scopes.get(doc.selectedScope);
  if (!s) return [];
  const f = explorerFilter.trim().toLowerCase();
  const vars = s.vars.map((id) => doc.file.vars[id]);
  return f ? vars.filter((v) => v.name.toLowerCase().includes(f)) : vars;
}

function renderSidebarLists() {
  const doc = active();
  if (!doc || !doc.file || !S.sidebarMode) return;
  if (S.sidebarMode === 'search') {
    const q = S.search.trim().toLowerCase();
    const res = [];
    if (q) for (const v of doc.file.vars) { if (v.fullPath.toLowerCase().includes(q)) { res.push(v); if (res.length >= 500) break; } }
    const rc = $('#resultCount');
    if (rc) {
      rc.replaceChildren();
      if (q) {
        rc.append(h('span', null, `${res.length}${res.length >= 500 ? '+' : ''} result${res.length === 1 ? '' : 's'}`), h('span', { class: 'grow' }));
        if (res.length) rc.append(h('button', { class: 'icon-btn codicon codicon-add', title: 'Add all results',
          onclick: () => addSignals(doc, res.filter((v) => !doc.isDisplayed(v))) }));
      }
    }
    virtualList($('#searchList'), res, 36, (v) => varRow(doc, v, true));
    return;
  }
  const scope = doc.file.scopes.get(doc.selectedScope);
  const sub = $('#scopeSub');
  if (sub) sub.textContent = scope ? `— ${scope.name || '(top)'}` : '';
  const hier = $('#hierList');
  if (hier) {
    const rows = [];
    if (doc.file.root.vars.length) rows.push([doc.file.root, 0]);
    (function walk(s, d) {
      for (const c of s.children) { rows.push([c, d]); if (doc.expanded.has(c.id)) walk(c, d + 1); }
    })(doc.file.root, 0);
    const st = hier.scrollTop;
    hier.replaceChildren(...rows.map(([s, d]) => scopeRow(doc, s, d)));
    hier.scrollTop = st;
  }
  const list = $('#varList');
  if (list) virtualList(list, currentScopeVars(doc), 22, (v) => varRow(doc, v, false));
}

function scopeRow(doc, s, depth) {
  const expanded = doc.expanded.has(s.id);
  const toggle = () => { if (expanded) doc.expanded.delete(s.id); else doc.expanded.add(s.id); renderSidebarLists(); };
  const kindIcon = s.kind === 'module' ? 'symbol-class' : (s.kind === 'task' || s.kind === 'function') ? 'symbol-method'
    : s.kind === 'root' ? 'symbol-namespace' : 'symbol-namespace';
  return h('div', {
    class: 'trow' + (doc.selectedScope === s.id ? ' sel' : ''), style: `padding-left:${8 + depth * 12}px`, title: s.path,
    onclick: () => {
      doc.selectedScope = s.id;
      if (!expanded && s.children.length) doc.expanded.add(s.id);
      const l = $('#varList'); if (l) l.scrollTop = 0;
      renderSidebarLists();
    },
    oncontextmenu: async (e) => {
      e.preventDefault();
      const id = await api.popupMenu([
        { id: 'add', label: 'Add All Signals', enabled: s.vars.length > 0 },
        { id: 'toggle', label: expanded ? 'Collapse' : 'Expand', enabled: s.children.length > 0 },
        { id: 'copy', label: 'Copy Path' }]);
      if (id === 'add') addSignals(doc, s.vars.map((i) => doc.file.vars[i]).filter((v) => !doc.isDisplayed(v)));
      else if (id === 'toggle') toggle();
      else if (id === 'copy') copyText(s.path);
    },
  },
  s.children.length
    ? h('span', { class: `chev codicon codicon-${expanded ? 'chevron-down' : 'chevron-right'}`,
      onclick: (e) => { e.stopPropagation(); toggle(); } })
    : h('span', { class: 'chev' }),
  h('span', { class: `kind codicon codicon-${kindIcon}`, style: `color:${scopeColor(theme, s.kind)}` }),
  h('span', { class: 'nm' }, s.name || '(top)'),
  h('span', { class: 'grow' }),
  s.vars.length ? h('span', { class: 'count' }, s.vars.length) : null);
}

function varRow(doc, v, showPath) {
  const c = varColor(theme, v.kind);
  const row = h('div', {
    class: 'vrow-item' + (showPath ? ' tall' : ''), draggable: 'true',
    title: `${v.fullPath}  ·  ${v.kind}, ${v.width} bit${v.width === 1 ? '' : 's'}`,
    ondblclick: () => addSignals(doc, [v]),
    ondragstart: (e) => {
      e.dataTransfer.setData('application/x-hdl-sig', String(v.id));
      e.dataTransfer.setData('text/plain', v.fullPath);
      e.dataTransfer.effectAllowed = 'copy';
    },
    oncontextmenu: async (e) => {
      e.preventDefault();
      const id = await api.popupMenu([{ id: 'add', label: 'Add to Waveform' }, { id: 'copy', label: 'Copy Path' }]);
      if (id === 'add') addSignals(doc, [v]); else if (id === 'copy') copyText(v.fullPath);
    },
  },
  h('span', { class: 'badge', style: `color:${c};border-color:${c}` }, varLetter(v.kind)),
  h('div', { class: 'txt' },
    h('div', { class: 'line' }, h('span', { class: 'nm' }, v.name), v.range ? h('span', { class: 'rg' }, v.range) : null),
    showPath ? h('div', { class: 'path' }, v.scopePath) : null),
  h('button', { class: 'icon-btn add codicon codicon-add', title: 'Add to waveform', onclick: () => addSignals(doc, [v]) }),
  doc.isDisplayed(v) ? h('span', { class: 'dot', title: 'Shown in waveform' }) : null);
  return row;
}

// Minimal virtualized list: only rows in view are in the DOM.
function virtualList(container, items, rowH, render) {
  if (!container) return;
  let spacer = container.firstChild;
  if (!spacer) {
    spacer = h('div', { class: 'vl-spacer' }, h('div', { class: 'vl-rows' }));
    container.append(spacer);
    container.addEventListener('scroll', () => drawSlice());
  }
  const rowsEl = spacer.firstChild;
  container._vl = { items, rowH, render };
  spacer.style.height = items.length * rowH + 8 + 'px';
  function drawSlice() {
    const { items: its, rowH: rh, render: r } = container._vl;
    const first = Math.max(0, Math.floor(container.scrollTop / rh) - 5);
    const last = Math.min(its.length, first + Math.ceil(container.clientHeight / rh) + 10);
    rowsEl.style.top = first * rh + 'px';
    rowsEl.replaceChildren(...its.slice(first, last).map(r));
  }
  drawSlice();
}

// ---------------------------------------------------------------- Rendering: editor content

let panel = null; // DOM refs for the waveform panel of the active doc

function renderContent() {
  const doc = active();
  const content = $('#content');
  if (!doc) { panel = null; content.replaceChildren(welcomeView()); return; }
  if (!doc.file) {
    panel = null;
    if (doc.error) {
      content.replaceChildren(h('div', { class: 'center-msg' },
        h('span', { class: 'codicon codicon-warning big', style: `color:${theme.waveZ}` }),
        h('div', { style: 'font-size:15px' }, `Could not open ${doc.name}`),
        h('div', { class: 'dim' }, doc.error),
        h('button', { class: 'vs-button', onclick: () => reload(doc) }, 'Try Again')));
    } else {
      content.replaceChildren(h('div', { class: 'center-msg' },
        h('div', { class: 'dim' }, `Parsing ${doc.name}…`),
        h('div', { class: 'progress' }, h('div', { id: 'progressFill' }))));
      renderProgress();
    }
    return;
  }
  if (!panel || panel.doc !== doc || panel.file !== doc.file) buildPanel(doc);
  renderProgress();
  renderRows();
}

function renderProgress() {
  const doc = active();
  if (!doc) return;
  const fill = $('#progressFill');
  if (fill) fill.style.width = Math.max(doc.progress, 0.03) * 100 + '%';
  if (panel) {
    let bar = $('.topbar-progress', panel.root);
    if (doc.loading) {
      if (!bar) { bar = h('div', { class: 'topbar-progress' }, h('div')); panel.root.append(bar); }
      bar.firstChild.style.width = Math.max(doc.progress, 0.05) * 100 + '%';
    } else if (bar) bar.remove();
  }
  const tabs = $('#tabs');
  if (tabs && tabs.querySelector('.spin') && !S.docs.some((d) => d.loading)) renderTabs();
}

function welcomeView() {
  const recent = S.recent.slice(0, 8);
  return h('div', { class: 'welcome' }, h('div', { class: 'welcome-inner' },
    h('div', null, h('h1', null, 'HDL Viewer'), h('div', { class: 'subtitle' }, 'Waveforms for your Verilog simulations')),
    h('div', { class: 'cols' },
      h('div', { class: 'col' }, h('h2', null, 'Start'),
        h('div', { class: 'link-row' }, icon('file'), h('span', { class: 'link', onclick: showOpenDialog }, 'Open Waveform…'),
          h('span', { class: 'dim', style: 'font-size:12px' }, `${MOD()}+O`)),
        S.example ? h('div', { class: 'link-row' }, icon('pulse'),
          h('span', { class: 'link', onclick: () => openFiles([S.example]) }, 'Open Example'),
          h('span', { class: 'dim', style: 'font-size:12px' }, 'counter.vcd')) : null),
      h('div', { class: 'col', style: 'min-width:0;flex:1' }, h('h2', null, 'Recent'),
        recent.length ? null : h('div', { class: 'dim' }, 'No recent waveforms'),
        recent.map((p) => h('div', { class: 'recent-row' },
          h('span', { class: 'link', onclick: () => openFiles([p]) }, basename(p)),
          h('span', { class: 'dim', title: p }, dirname(p)))))),
    h('div', { class: 'dropzone' }, icon('new-file'), 'Drop a .vcd file anywhere in this window'),
    h('div', null,
      h('div', { style: 'font-size:14px;font-weight:500' }, 'Generating a VCD with Icarus Verilog'),
      h('div', { class: 'code' }, 'initial begin\n    $dumpfile("wave.vcd");\n    $dumpvars(0, tb);\nend'),
      h('div', { class: 'dim', style: 'font-size:12px' },
        'iverilog -o sim tb.v && vvp sim   ·   the viewer reloads automatically when the file changes'))));
}

// ---------------------------------------------------------------- Waveform panel

function buildPanel(doc) {
  const rulerCanvas = h('canvas', { id: 'ruler', title: 'Click to place cursor · Shift-click for marker · Drag to pan' });
  const waveCanvas = h('canvas', { class: 'wave-canvas', id: 'waveCanvas' });
  const overlayCanvas = h('canvas', { class: 'wave-canvas', id: 'overlayCanvas' });
  const names = h('div', { class: 'names' });
  const values = h('div', { class: 'values' });
  const content = h('div', { class: 'rows-content' }, names, values);
  const rows = h('div', { class: 'rows' }, content);
  const emptyHint = h('div', { class: 'empty-hint' }, icon('pulse'), h('div', { style: 'font-size:14px' }, 'No signals shown'),
    h('div', { class: 'dim' }, 'Double-click or drag signals from the Explorer'));
  const body = h('div', { class: 'wave-body' }, rows, waveCanvas, overlayCanvas, emptyHint);

  const nameSplit = h('div', { class: 'splitter' });
  const valueSplit = h('div', { class: 'splitter' });
  const header = h('div', { class: 'wave-header' },
    h('div', { class: 'wh-name' }, 'SIGNALS', h('span', { class: 'grow' }),
      h('button', { class: 'icon-btn codicon codicon-ellipsis', title: 'More actions',
        onclick: (e) => popup([
          { id: 'select-all', label: 'Select All', accelerator: `${MOD()}+A` },
          { id: 'remove-selected', label: 'Remove Selected', enabled: doc.selection.size > 0 },
          { id: 'remove-all', label: 'Remove All' }], e.currentTarget) })),
    nameSplit,
    h('div', { class: 'wh-value' }, 'VALUE'),
    valueSplit,
    rulerCanvas);

  const root = h('div', { class: 'wave-panel', tabindex: '0' }, header, body);
  $('#content').replaceChildren(root);
  panel = { doc, file: doc.file, root, rows, content, names, values, waveCanvas, overlayCanvas, rulerCanvas, emptyHint, body };

  splitter(nameSplit, (dx) => { S.nameW = Math.min(Math.max(S.nameW + dx, 100), 600); applyWidths(); }, () => store.set('nameW', S.nameW));
  splitter(valueSplit, (dx) => { S.valueW = Math.min(Math.max(S.valueW + dx, 60), 400); applyWidths(); }, () => store.set('valueW', S.valueW));

  rows.addEventListener('scroll', () => { doc.scrollTop = rows.scrollTop; scheduleDraw(); });
  new ResizeObserver(() => layoutCanvases()).observe(body);
  wireWaveMouse(doc);
  wireRuler(doc);
  wireDrops(doc);
  layoutCanvases();
  rows.scrollTop = doc.scrollTop;
  root.focus({ preventScroll: true });
}

function applyWidths() {
  const r = document.documentElement.style;
  r.setProperty('--nameW', S.nameW + 'px');
  r.setProperty('--valueW', S.valueW + 'px');
  r.setProperty('--sidebarW', S.sidebarW + 'px');
  layoutCanvases();
}

function splitter(el, onDelta, onEnd) {
  el.addEventListener('mousedown', (e) => {
    e.preventDefault();
    let last = e.clientX;
    el.classList.add('dragging');
    document.body.style.cursor = 'col-resize';
    const move = (ev) => { onDelta(ev.clientX - last); last = ev.clientX; };
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

function layoutCanvases() {
  if (!panel) return;
  const { rows, waveCanvas, overlayCanvas, rulerCanvas, doc } = panel;
  const sbw = rows.offsetWidth - rows.clientWidth;
  document.documentElement.style.setProperty('--sbw', sbw + 'px');
  const dpr = window.devicePixelRatio || 1;
  // Canvases don't stretch to their CSS box, so size them explicitly.
  const left = S.nameW + S.valueW + 2;
  const waveW = Math.max(0, panel.body.clientWidth - left - sbw);
  const waveH = panel.body.clientHeight;
  for (const c of [waveCanvas, overlayCanvas]) { c.style.width = waveW + 'px'; c.style.height = waveH + 'px'; }
  rulerCanvas.style.width = Math.max(0, panel.body.clientWidth - left) + 'px';
  rulerCanvas.style.height = '30px';
  for (const c of [waveCanvas, overlayCanvas, rulerCanvas]) {
    const w = parseFloat(c.style.width), hgt = parseFloat(c.style.height);
    if (c.width !== Math.round(w * dpr) || c.height !== Math.round(hgt * dpr)) {
      c.width = Math.round(w * dpr);
      c.height = Math.round(hgt * dpr);
    }
  }
  const w = waveW;
  if (Math.abs(w - doc.width) > 0.5) {
    doc.width = w;
    if (doc.needsFit && doc.file) doc.fit(); else doc.clamp();
  }
  drawAll();
}

function renderRows() {
  if (!panel) return;
  const { doc, names, values, content, rows, emptyHint } = panel;
  content.style.height = Math.max(rows.clientHeight, rowTops(doc)[doc.displayed.length] + 3 * ROW_H) + 'px';
  names.replaceChildren(...doc.displayed.map((sig) => nameRow(doc, sig)), tailRow(doc));
  values.replaceChildren(...doc.displayed.map((sig) => h('div', { class: 'vcell', 'data-id': sig.id, style: `height:${rowH(sig)}px` })));
  emptyHint.style.display = doc.displayed.length ? 'none' : 'flex';
  renderSelection();
  updateValues();
  renderStatus();
  layoutCanvases();
}

function renderSelection() {
  if (!panel) return;
  const { doc, names, values } = panel;
  for (const el of names.children) if (el.dataset.id) el.classList.toggle('sel', doc.selection.has(el.dataset.id));
  for (const el of values.children) el.classList.toggle('sel', doc.selection.has(el.dataset.id));
  scheduleDraw();
}

function updateValues() {
  if (!panel) return;
  const { doc, values } = panel;
  const cells = values.children;
  doc.displayed.forEach((sig, i) => {
    const cell = cells[i];
    if (!cell) return;
    const tr = doc.trace(sig);
    const raw = doc.cursor != null ? valueAt(tr, doc.cursor) : null;
    const digital = raw == null ? '—' : formatValue(raw, tr, sig.radix);
    const level = isAnalog(sig) && raw != null ? analogLevel(raw, tr, sig.display) : null;
    const text = level != null ? formatAnalog(level, tr, sig.display) : digital;
    const sub = level != null && (sig.height || 1) > 1 && tr.type !== 'real' ? digital : '';
    const key = text + '\u0000' + sub;
    if (cell.dataset.key !== key) {
      cell.dataset.key = key;
      cell.replaceChildren(...[h("div", { class: "vmain" }, text), sub ? h('div', { class: 'vsub', title: `Raw code (${(RADIXES.find((r) => r[0] === sig.radix) || [])[1] || ''})` }, sub) : null].filter(Boolean));
    }
    const cls = 'vcell' + (doc.selection.has(sig.id) ? ' sel' : '') +
      (raw == null ? ' none' : (tr.type === 'bit' || tr.type === 'vec') ? (isHighZ(raw) ? ' z' : isUnknown(raw) ? ' x' : '') : '');
    if (cell.className !== cls) cell.className = cls;
    cell.title = text;
  });
}

function nameRow(doc, sig) {
  const color = sigColor(doc, sig);
  return h('div', {
    class: 'nrow', 'data-id': sig.id, draggable: 'true', title: sig.v.fullPath, style: `height:${rowH(sig)}px`,
    onmousedown: (e) => { if (e.button === 0) { selectSig(doc, sig.id, e); panel.root.focus({ preventScroll: true }); } },
    oncontextmenu: (e) => {
      e.preventDefault();
      if (!doc.selection.has(sig.id)) selectSig(doc, sig.id, null);
      signalMenu(doc, sig);
    },
    ondragstart: (e) => {
      const ids = doc.selection.has(sig.id) ? doc.displayed.filter((d) => doc.selection.has(d.id)).map((d) => d.id) : [sig.id];
      e.dataTransfer.setData('application/x-hdl-row', ids.join(','));
      e.dataTransfer.effectAllowed = 'move';
    },
  },
  h('span', { class: 'tag', style: `background:${color};height:${isAnalog(sig) ? 30 : 14}px` }),
  h('div', { class: 'ncol' },
    h('div', { class: 'nline' }, h('span', { class: 'nm' }, sig.v.name), sig.v.range ? h('span', { class: 'rg' }, sig.v.range) : null),
    isAnalog(sig) && (sig.height || 1) > 1 ? h('div', { class: 'nsub' }, h('span', { class: 'codicon codicon-pulse' }),
      DISPLAY_SHORT[sig.display] + (sig.interp === 'linear' ? ' · linear' : '')) : null));
}

function tailRow() { return h('div', { class: 'tail' }); }

function sigColor(doc, sig) {
  if (sig.color != null && theme.palette[sig.color]) return theme.palette[sig.color][1];
  return doc.trace(sig).type === 'bit' ? theme.wave1 : theme.waveBus;
}

// ---------------------------------------------------------------- Drawing

let drawQueued = false;
function scheduleDraw() {
  if (drawQueued) return;
  drawQueued = true;
  requestAnimationFrame(() => { drawQueued = false; drawAll(); });
}
function drawAll() { drawWaves(); drawRuler(); drawOverlay(); }

let overlayQueued = false;
function scheduleOverlay() {
  if (overlayQueued) return;
  overlayQueued = true;
  requestAnimationFrame(() => { overlayQueued = false; drawOverlay(); });
}

function viewChanged() {
  scheduleDraw();
  updateValues();
  scheduleStatus();
}

function prepCanvas(c) {
  const ctx = c.getContext('2d');
  const dpr = window.devicePixelRatio || 1;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, c.width, c.height);
  return ctx;
}

const MONO = '11px "Cascadia Mono", Consolas, "SF Mono", Menlo, monospace';
let charW = 0;

function drawWaves() {
  if (!panel) return;
  const { doc, waveCanvas: c, rows } = panel;
  const ctx = prepCanvas(c);
  const w = c.clientWidth, hgt = c.clientHeight;
  if (!w || !doc.file) return;
  ctx.font = MONO;
  if (!charW) charW = ctx.measureText('0').width;

  // Grid and the area after the end of the simulation.
  const info = computeTicks(doc.start, doc.tpp, w, doc.file.ts);
  ctx.strokeStyle = theme.grid;
  ctx.lineWidth = 1;
  ctx.beginPath();
  const endT = doc.start + w * doc.tpp;
  for (let t = Math.floor(doc.start / info.step) * info.step; t <= endT; t += info.step) {
    const x = Math.round(doc.xAt(t)) + 0.5;
    ctx.moveTo(x, 0); ctx.lineTo(x, hgt);
  }
  ctx.stroke();
  const endX = doc.xAt(doc.end);
  if (endX < w) { ctx.fillStyle = theme.endShade; ctx.fillRect(Math.max(endX, 0), 0, w - Math.max(endX, 0), hgt); }

  const scrollTop = rows.scrollTop;
  const tops = rowTops(doc);
  for (let i = 0; i < doc.displayed.length; i++) {
    const sig = doc.displayed[i];
    const y = tops[i] - scrollTop, rh = tops[i + 1] - tops[i];
    if (y + rh < 0) continue;
    if (y > hgt) break;
    if (doc.selection.has(sig.id)) { ctx.fillStyle = theme.waveRowSelected; ctx.fillRect(0, y, w, rh); }
    ctx.fillStyle = theme.rowSeparator;
    ctx.fillRect(0, y + rh - 1, w, 1);
    ctx.save();
    ctx.beginPath(); ctx.rect(0, y, w, rh); ctx.clip();
    if (isAnalog(sig)) drawAnalog(ctx, doc.trace(sig), y, rh, w, doc.start, doc.tpp, doc.end, sig.display, sig.interp, sigColor(doc, sig));
    else drawSignal(ctx, doc.trace(sig), y, w, doc.start, doc.tpp, doc.end, sig.radix, sigColor(doc, sig), rh);
    ctx.restore();
  }
}

function withAlpha(hex, a) {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}

// Draws one signal row. Changes that fall into the same pixel column are
// collapsed into a single "busy" bar, so cost scales with width, not file size.
function drawSignal(ctx, tr, y, w, start, tpp, endTime, radix, color, rh = ROW_H) {
  const n = tr.n;
  if (!n) return;
  const top = y + 5, bot = y + rh - 6, mid = (top + bot) / 2;
  const times = tr.times;
  const X = (i) => (times[i] - start) / tpp;
  const endX = (endTime - start) / tpp;
  const busy = new Path2D();
  let k = Math.max(0, lastIndexAtOrBefore(tr, start));

  function walk(body) {
    while (k < n) {
      const xs = X(k);
      if (xs > w + 2) break;
      let kEnd = k, isBusy = false;
      const col = Math.floor(xs);
      if (k + 1 < n && X(k + 1) < col + 1) {
        kEnd = Math.max(k, firstIndexAtOrAfter(tr, start + (col + 1) * tpp) - 1);
        busy.rect(col, top, 1, bot - top);
        isBusy = true;
      }
      const xe = kEnd + 1 < n ? X(kEnd + 1) : Math.max(endX, X(kEnd));
      body(isBusy ? col + 1 : xs, xe, kEnd, isBusy);
      k = kEnd + 1;
    }
  }

  if (tr.type === 'bit') {
    const line = new Path2D(), fill = new Path2D(), xr = new Path2D(), zl = new Path2D();
    let prevY = null;
    walk((xs, xe, i, wasBusy) => {
      const v = tr.bits[i];
      const x0 = Math.max(xs, -2), x1 = Math.min(xe, w + 2);
      let yy;
      if (v === 1) { yy = top; if (x1 > x0) fill.rect(x0, top, x1 - x0, bot - top); }
      else if (v === 0) yy = bot;
      else { yy = mid; if (v === 2 && x1 > x0) xr.rect(x0, top, x1 - x0, bot - top); }
      if (prevY != null && !wasBusy && xs >= -2 && prevY !== yy) { line.moveTo(xs, prevY); line.lineTo(xs, yy); }
      if (x1 > x0) {
        if (v === 3) { zl.moveTo(x0, yy); zl.lineTo(x1, yy); }
        else if (v <= 1) { line.moveTo(x0, yy); line.lineTo(x1, yy); }
      }
      prevY = yy;
    });
    ctx.fillStyle = withAlpha(color, 0.13); ctx.fill(fill);
    ctx.fillStyle = withAlpha(theme.waveX, 0.28); ctx.fill(xr);
    ctx.strokeStyle = withAlpha(theme.waveX, 0.9); ctx.lineWidth = 1; ctx.stroke(xr);
    ctx.strokeStyle = theme.waveZ; ctx.lineWidth = 1.5; ctx.stroke(zl);
    ctx.strokeStyle = color; ctx.lineWidth = 1.5; ctx.lineCap = 'square'; ctx.lineJoin = 'miter'; ctx.stroke(line);
    ctx.fillStyle = color; ctx.fill(busy);
    return;
  }

  const outline = new Path2D(), xPath = new Path2D(), zLine = new Path2D();
  const labels = [];
  const numeric = tr.type === 'vec';
  walk((xs, xe, i) => {
    if (xe - xs < 1) return;
    const x0 = Math.max(xs, -20), x1 = Math.min(xe, w + 20);
    if (x1 <= x0) return;
    const v = tr.values[i];
    const s = Math.min(3, (xe - xs) / 2);
    const unknown = numeric && isUnknown(v);
    const highZ = numeric && isHighZ(v);
    if (highZ) {
      zLine.moveTo(x0, mid); zLine.lineTo(x1, mid);
      if (xs >= -2) { zLine.moveTo(xs, top); zLine.lineTo(xs, bot); }
    } else {
      const p = unknown ? xPath : outline;
      const a = Math.max(xs, -20), b = Math.min(xe, w + 20);
      p.moveTo(a, mid); p.lineTo(a + s, top); p.lineTo(b - s, top); p.lineTo(b, mid);
      p.lineTo(b - s, bot); p.lineTo(a + s, bot); p.closePath();
    }
    const vis0 = Math.max(xs + s + 3, 2), vis1 = Math.min(xe - s - 3, w - 2);
    const avail = vis1 - vis0;
    if (avail < charW) return;
    let label = formatValue(v, tr, radix);
    const maxChars = Math.floor(avail / charW);
    if (label.length > maxChars) {
      if (maxChars < 2) return;
      label = label.slice(0, maxChars - 1) + '…';
    }
    labels.push([label, (vis0 + vis1) / 2, highZ ? theme.waveZ : unknown ? theme.waveX : theme.waveText]);
  });
  ctx.fillStyle = withAlpha(color, 0.10); ctx.fill(outline);
  ctx.strokeStyle = color; ctx.lineWidth = 1.2; ctx.lineJoin = 'miter'; ctx.stroke(outline);
  ctx.fillStyle = withAlpha(theme.waveX, 0.22); ctx.fill(xPath);
  ctx.strokeStyle = theme.waveX; ctx.stroke(xPath);
  ctx.strokeStyle = theme.waveZ; ctx.lineWidth = 1.5; ctx.stroke(zLine);
  ctx.fillStyle = color; ctx.fill(busy);
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  for (const [label, cx, col] of labels) { ctx.fillStyle = col; ctx.fillText(label, cx, mid + 0.5); }
}

// Plots a vector or real signal as an analog trace scaled to full scale (see analogLevel).
// Several changes in one pixel column become a min–max bar.
function drawAnalog(ctx, tr, y0, h, w, start, tpp, endTime, mode, interp, color) {
  const plotTop = y0 + 7, plotBot = y0 + h - 8;
  const { lo, hi } = analogRange(tr, mode);
  const Y = (v) => plotBot - (v - lo) / (hi - lo) * (plotBot - plotTop);
  let guides;
  if (mode === 'analogSigned') guides = [[1, false], [0.5, false], [0, true], [-0.5, false], [-1, false]];
  else if (mode === 'analogUnsigned') guides = [[1, false], [0.5, false], [0, true]];
  else { const r = levelRange(tr, mode); guides = r.hi - r.lo < 1e-12 ? [[r.lo, false]] : [[r.hi, false], [(r.hi + r.lo) / 2, false], [r.lo, false]]; }
  const showLabels = h >= 60, showHalf = h >= 80;
  const guideColor = theme.dark ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.10)';
  const guideSolid = theme.dark ? 'rgba(255,255,255,0.16)' : 'rgba(0,0,0,0.16)';
  const labels = [];
  for (const [level, solid] of guides) {
    if (!solid && Math.abs(Math.abs(level) - 0.5) < 1e-12 && mode !== 'analogAuto' && !showHalf) continue;
    const gy = Math.round(Y(level)) + 0.5;
    ctx.strokeStyle = solid ? guideSolid : guideColor;
    ctx.lineWidth = 1;
    ctx.setLineDash(solid ? [] : [2, 3]);
    ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(w, gy); ctx.stroke();
    if (showLabels) {
      const text = mode === 'analogSigned' ? (level === 0 ? '0' : fmtG(level, 6, true)) : mode === 'analogUnsigned' ? fmtG(level) : fmtG(level, 4);
      labels.push([text, gy]);
    }
  }
  ctx.setLineDash([]);
  const drawLabels = () => {
    ctx.font = '9px "Cascadia Mono", Consolas, "SF Mono", Menlo, monospace';
    ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
    for (const [text, gy] of labels) {
      const tw = ctx.measureText(text).width;
      ctx.fillStyle = withAlpha(theme.editor, 0.8);
      ctx.beginPath(); ctx.roundRect(2, gy - 6.5, tw + 6, 13, 3); ctx.fill();
      ctx.fillStyle = theme.dimFG;
      ctx.fillText(text, 5, gy + 0.5);
    }
  };
  const n = tr.n;
  if (!n || !(tpp > 0)) { drawLabels(); return; }
  const times = tr.times;
  const X = (i) => (times[i] - start) / tpp;
  const endX = (endTime - start) / tpp;
  const level = (i) => analogLevel(rawValue(tr, i), tr, mode);
  const baseY = Y(Math.min(Math.max(0, lo), hi));
  const stroke = new Path2D(), fill = new Path2D(), bars = new Path2D(), unknown = new Path2D();
  let run = [];
  const flush = () => {
    if (run.length >= 2) {
      const first = run[0], lastP = run[run.length - 1];
      stroke.moveTo(first[0], first[1]);
      fill.moveTo(first[0], first[1]);
      for (let k = 1; k < run.length; k++) { stroke.lineTo(run[k][0], run[k][1]); fill.lineTo(run[k][0], run[k][1]); }
      fill.lineTo(lastP[0], baseY); fill.lineTo(first[0], baseY); fill.closePath();
    }
    run = [];
  };
  let k = Math.max(0, lastIndexAtOrBefore(tr, start));
  while (k < n) {
    const xs = X(k);
    if (xs > w + 2) break;
    let kEnd = k, segStart = xs;
    const col = Math.floor(xs);
    if (k + 1 < n && X(k + 1) < col + 1) {
      const j = Math.max(k + 1, firstIndexAtOrAfter(tr, start + (col + 1) * tpp));
      let mn = Infinity, mx = -Infinity, sawUnknown = false;
      const stride = Math.max(1, Math.floor((j - k) / 256));
      for (let i = k; i < j; i += stride) { const v = level(i); if (v != null) { if (v < mn) mn = v; if (v > mx) mx = v; } else sawUnknown = true; }
      const vl = level(j - 1);
      if (vl != null) { mn = Math.min(mn, vl); mx = Math.max(mx, vl); }
      if (isFinite(mn)) { bars.moveTo(col + 0.5, Y(mx)); bars.lineTo(col + 0.5, Y(mn)); }
      if (sawUnknown) unknown.rect(col, plotTop, 1, plotBot - plotTop);
      kEnd = j - 1;
      segStart = col + 1;
    }
    const xe = kEnd + 1 < n ? X(kEnd + 1) : Math.max(endX, X(kEnd));
    const v = level(kEnd);
    if (v != null) {
      const yy = Y(v);
      if (interp === 'step') {
        if (run.length) run.push([segStart, run[run.length - 1][1]]);
        run.push([segStart, yy]);
        if (kEnd + 1 >= n) run.push([xe, yy]);
      } else {
        run.push([segStart, yy]);
        if (kEnd + 1 >= n || level(kEnd + 1) == null) run.push([xe, yy]);
      }
    } else {
      flush();
      const a = Math.max(segStart, -2), b = Math.min(xe, w + 2);
      if (b > a) unknown.rect(a, plotTop, b - a, plotBot - plotTop);
    }
    k = kEnd + 1;
  }
  if (interp === 'step' && run.length && k < n) run.push([X(k), run[run.length - 1][1]]);
  else if (interp === 'linear' && run.length && k < n) { const v = level(k); if (v != null) run.push([X(k), Y(v)]); }
  flush();
  ctx.fillStyle = withAlpha(theme.waveX, 0.22); ctx.fill(unknown);
  ctx.fillStyle = withAlpha(color, 0.10); ctx.fill(fill);
  ctx.strokeStyle = color; ctx.lineWidth = 1.5; ctx.lineJoin = 'round'; ctx.stroke(stroke);
  ctx.lineWidth = 1; ctx.stroke(bars);
  ctx.lineJoin = 'miter';
  drawLabels();
}

function drawRuler() {
  if (!panel) return;
  const { doc, rulerCanvas: c } = panel;
  const ctx = prepCanvas(c);
  const w = c.clientWidth, hgt = c.clientHeight;
  if (!w || !doc.file) return;
  const ts = doc.file.ts;
  const info = computeTicks(doc.start, doc.tpp, w, ts);
  const endT = doc.start + w * doc.tpp;
  ctx.lineWidth = 1;
  if (info.minor) {
    ctx.strokeStyle = withAlpha(theme.rulerFG, 0.45);
    ctx.beginPath();
    for (let t = Math.floor(doc.start / info.minor) * info.minor; t <= endT; t += info.minor) {
      const x = Math.round(doc.xAt(t)) + 0.5;
      ctx.moveTo(x, hgt - 4); ctx.lineTo(x, hgt);
    }
    ctx.stroke();
  }
  ctx.strokeStyle = withAlpha(theme.rulerFG, 0.8);
  ctx.fillStyle = theme.rulerFG;
  ctx.font = '10px "Cascadia Mono", Consolas, "SF Mono", Menlo, monospace';
  ctx.textAlign = 'left';
  ctx.textBaseline = 'top';
  ctx.beginPath();
  for (let t = Math.floor(doc.start / info.step) * info.step; t <= endT; t += info.step) {
    const x = Math.round(doc.xAt(t)) + 0.5;
    ctx.moveTo(x, hgt - 10); ctx.lineTo(x, hgt);
    ctx.fillText(ts.format(t, info.unit, info.decimals), x + 4, 4);
  }
  ctx.stroke();

  const flag = (t, color) => {
    const x = doc.xAt(t);
    if (x < -60 || x > w + 60) return;
    ctx.font = '600 10px "Cascadia Mono", Consolas, "SF Mono", Menlo, monospace';
    const text = ts.format(t);
    const tw = ctx.measureText(text).width;
    const rw = tw + 10, rh = 15;
    const rx = Math.min(Math.max(x - rw / 2, 0), w - rw), ry = hgt - rh - 8;
    ctx.fillStyle = color;
    ctx.beginPath(); ctx.roundRect(rx, ry, rw, rh, 3); ctx.fill();
    ctx.beginPath(); ctx.moveTo(x - 4, ry + rh); ctx.lineTo(x + 4, ry + rh); ctx.lineTo(x, hgt); ctx.closePath(); ctx.fill();
    ctx.fillStyle = '#FFFFFF';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(text, rx + rw / 2, ry + rh / 2 + 0.5);
  };
  if (doc.marker != null) flag(doc.marker, theme.marker);
  if (doc.cursor != null) flag(doc.cursor, theme.cursor);
}

function drawOverlay() {
  if (!panel) return;
  const { doc, overlayCanvas: c } = panel;
  const ctx = prepCanvas(c);
  const w = c.clientWidth, hgt = c.clientHeight;
  if (!w || !doc.file) return;
  const vline = (t, color, dash) => {
    const x = Math.round(doc.xAt(t)) + 0.5;
    if (x < 0 || x > w) return;
    ctx.strokeStyle = color; ctx.lineWidth = 1; ctx.setLineDash(dash || []);
    ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, hgt); ctx.stroke();
  };
  if (doc.zoomBox) {
    const x = Math.min(doc.zoomBox.x0, doc.zoomBox.x1), bw = Math.abs(doc.zoomBox.x1 - doc.zoomBox.x0);
    ctx.fillStyle = withAlpha(theme.accent, 0.15); ctx.fillRect(x, 0, bw, hgt);
    ctx.strokeStyle = withAlpha(theme.accent, 0.7); ctx.strokeRect(x + 0.5, -1, bw, hgt + 2);
  }
  if (doc.hover != null) vline(doc.hover, theme.hoverLine, [3, 3]);
  if (doc.marker != null) vline(doc.marker, theme.marker, [5, 3]);
  if (doc.cursor != null) vline(doc.cursor, theme.cursor);
  ctx.setLineDash([]);
}

// ---------------------------------------------------------------- Mouse & wheel

function wheelHandler(doc, getX) {
  return (e) => {
    e.preventDefault();
    let dx = e.deltaX, dy = e.deltaY;
    if (e.deltaMode === 1) { dx *= 16; dy *= 16; }
    if (e.ctrlKey || e.metaKey || e.altKey) {
      // Pinch-to-zoom on touchpads arrives as Ctrl+wheel.
      const d = Math.abs(dy) >= Math.abs(dx) ? dy : dx;
      doc.zoom(Math.exp(d * (e.ctrlKey && Math.abs(d) < 50 ? 0.01 : 0.0025)), getX(e));
      viewChanged();
    } else if (e.shiftKey) {
      doc.pan(dy || dx); viewChanged();
    } else if (Math.abs(dx) > Math.abs(dy)) {
      doc.pan(dx); viewChanged();
    } else {
      panel.rows.scrollTop += dy;
    }
  };
}

function wireWaveMouse(doc) {
  const c = panel.overlayCanvas;
  const localX = (e) => e.clientX - c.getBoundingClientRect().left;
  const localY = (e) => e.clientY - c.getBoundingClientRect().top;

  c.addEventListener('wheel', wheelHandler(doc, localX), { passive: false });

  c.addEventListener('mousemove', (e) => {
    doc.hoverX = localX(e);
    doc.hover = doc.timeAt(doc.hoverX);
    scheduleOverlay();
    scheduleStatus();
  });
  c.addEventListener('mouseleave', () => {
    doc.hover = null; doc.hoverX = null;
    scheduleOverlay(); scheduleStatus();
  });

  c.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    e.preventDefault();
    panel.root.focus({ preventScroll: true });
    const x0 = localX(e);
    let moved = false;
    const move = (ev) => {
      const x = localX(ev);
      if (Math.abs(x - x0) > 3) moved = true;
      if (moved) { doc.zoomBox = { x0, x1: x }; scheduleOverlay(); }
    };
    const up = (ev) => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      if (moved && doc.zoomBox && Math.abs(doc.zoomBox.x1 - doc.zoomBox.x0) > 3) {
        doc.zoomRange(doc.zoomBox.x0, doc.zoomBox.x1);
      } else {
        clickAt(doc, localX(ev), localY(ev) + panel.rows.scrollTop, ev);
      }
      doc.zoomBox = null;
      viewChanged();
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  });

  c.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    const row = rowAt(doc, localY(e) + panel.rows.scrollTop);
    const sig = doc.displayed[row];
    if (!sig) return;
    if (!doc.selection.has(sig.id)) selectSig(doc, sig.id, null);
    signalMenu(doc, sig);
  });
}

function clickAt(doc, x, y, e) {
  const row = rowAt(doc, y);
  let t = doc.timeAt(x);
  const sig = doc.displayed[row];
  if (sig) {
    // Snap to a nearby edge of the clicked signal.
    const tr = doc.trace(sig);
    const i = firstIndexAtOrAfter(tr, t);
    let best = null, bestDist = 6 * doc.tpp;
    for (const j of [i - 1, i]) {
      if (j < 0 || j >= tr.n) continue;
      const d = Math.abs(tr.times[j] - t);
      if (d <= bestDist) { bestDist = d; best = tr.times[j]; }
    }
    if (best != null) t = best;
    if (!e.shiftKey) selectSig(doc, sig.id, e);
  }
  t = Math.max(doc.begin, Math.min(t, doc.end));
  if (e.shiftKey) doc.marker = t; else doc.cursor = t;
}

function wireRuler(doc) {
  const c = panel.rulerCanvas;
  const localX = (e) => e.clientX - c.getBoundingClientRect().left;
  c.addEventListener('wheel', wheelHandler(doc, localX), { passive: false });
  c.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    e.preventDefault();
    let last = e.clientX, moved = false;
    const move = (ev) => {
      if (Math.abs(ev.clientX - e.clientX) > 2) moved = true;
      if (moved) { doc.pan(-(ev.clientX - last)); last = ev.clientX; viewChanged(); }
    };
    const up = (ev) => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      if (!moved) {
        const t = Math.max(doc.begin, Math.min(doc.timeAt(localX(ev)), doc.end));
        if (ev.shiftKey) doc.marker = t; else doc.cursor = t;
        viewChanged();
      }
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  });
}

// ---------------------------------------------------------------- Drag & drop of signals

function wireDrops(doc) {
  const { body } = panel;
  const isOurs = (e) => e.dataTransfer.types.includes('application/x-hdl-sig') || e.dataTransfer.types.includes('application/x-hdl-row');
  let marked = null;
  const mark = (el) => { if (marked !== el) { if (marked) marked.classList.remove('drop-before'); marked = el; if (el) el.classList.add('drop-before'); } };

  body.addEventListener('dragover', (e) => {
    if (!isOurs(e)) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = e.dataTransfer.types.includes('application/x-hdl-row') ? 'move' : 'copy';
    const row = e.target.closest && e.target.closest('.nrow');
    mark(row || panel.names.querySelector('.tail'));
  });
  body.addEventListener('dragleave', (e) => { if (!body.contains(e.relatedTarget)) mark(null); });
  body.addEventListener('drop', (e) => {
    if (!isOurs(e)) return;
    e.preventDefault();
    e.stopPropagation();
    const before = marked && marked.dataset.id ? marked.dataset.id : null;
    mark(null);
    const rowIds = e.dataTransfer.getData('application/x-hdl-row');
    const sigId = e.dataTransfer.getData('application/x-hdl-sig');
    if (rowIds) moveIds(doc, new Set(rowIds.split(',')), before);
    else if (sigId) addSignals(doc, [doc.file.vars[+sigId]].filter(Boolean), before);
  });
}

// ---------------------------------------------------------------- Keyboard

document.addEventListener('keydown', (e) => {
  const mod = e.ctrlKey || e.metaKey;
  const k = e.key;
  const inInput = e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA';

  if (mod) {
    const map = { o: 'open', r: 'reload', w: 'close-tab', b: 'toggle-sidebar', '=': 'zoom-in', '+': 'zoom-in', '-': 'zoom-out', 0: 'zoom-fit' };
    let cmd = map[k.toLowerCase()];
    if (e.shiftKey && k.toLowerCase() === 'f') cmd = 'search';
    if (e.shiftKey && k.toLowerCase() === 'w') cmd = 'close-tab';
    if (!inInput && k.toLowerCase() === 'a') cmd = 'select-all';
    if (k === 'Tab' && S.docs.length > 1) {
      const i = S.docs.findIndex((d) => d.id === S.activeId);
      S.activeId = S.docs[(i + (e.shiftKey ? -1 : 1) + S.docs.length) % S.docs.length].id;
      e.preventDefault(); renderAll(); return;
    }
    if (cmd) { e.preventDefault(); runCommand(cmd); }
    return;
  }
  if (inInput) {
    if (k === 'Escape') e.target.blur();
    return;
  }
  const doc = active();
  if (!doc || !doc.file) return;
  let handled = true;
  switch (k) {
    case 'ArrowLeft': jumpTransition(doc, false); break;
    case 'ArrowRight': jumpTransition(doc, true); break;
    case 'ArrowUp': if (e.altKey) moveSelection(doc, -1); else moveSelectionCursor(doc, -1, e.shiftKey); break;
    case 'ArrowDown': if (e.altKey) moveSelection(doc, 1); else moveSelectionCursor(doc, 1, e.shiftKey); break;
    case 'Delete': case 'Backspace': removeSignals(doc, new Set(doc.selection)); break;
    case 'Escape': if (doc.marker != null) { doc.marker = null; viewChanged(); } else { doc.selection.clear(); renderSelection(); } break;
    case 'f': case 'F': doc.fit(); viewChanged(); break;
    case 'm': case 'M': doc.marker = doc.cursor; viewChanged(); break;
    case '+': case '=': doc.zoom(0.5); viewChanged(); break;
    case '-': doc.zoom(2); viewChanged(); break;
    default: handled = false;
  }
  if (handled) e.preventDefault();
});

// ---------------------------------------------------------------- File drops on the window

let dragDepth = 0;
const hasFiles = (e) => e.dataTransfer && e.dataTransfer.types.includes('Files');
window.addEventListener('dragenter', (e) => { if (hasFiles(e)) { dragDepth++; $('#dropOverlay').classList.add('show'); } });
window.addEventListener('dragleave', (e) => { if (hasFiles(e) && --dragDepth <= 0) { dragDepth = 0; $('#dropOverlay').classList.remove('show'); } });
window.addEventListener('dragover', (e) => { if (hasFiles(e)) { e.preventDefault(); e.dataTransfer.dropEffect = 'copy'; } });
window.addEventListener('drop', (e) => {
  if (!hasFiles(e)) return;
  e.preventDefault();
  dragDepth = 0;
  $('#dropOverlay').classList.remove('show');
  const paths = [...e.dataTransfer.files].map((f) => api.pathForFile(f)).filter(Boolean);
  if (paths.length) openFiles(paths);
});

// ---------------------------------------------------------------- Startup

let launch = null;

function wireChrome() {
  document.querySelectorAll('.ab-item[data-mode]').forEach((b) => b.addEventListener('click', () => {
    S.sidebarMode = S.sidebarMode === b.dataset.mode ? null : b.dataset.mode;
    renderAll();
    if (S.sidebarMode === 'search') setTimeout(() => { const i = $('#sidebar input'); if (i) i.focus(); }, 0);
  }));
  document.querySelectorAll('.tb-btn[data-cmd]').forEach((b) => b.addEventListener('click', () => runCommand(b.dataset.cmd)));
  $('#menuBtn').addEventListener('click', (e) => popup(appMenuItems(), e.currentTarget));
  $('#gearBtn').addEventListener('click', (e) => popup([
    { label: 'Color Theme', submenu: radioTheme() },
    { type: 'separator' },
    { id: 'auto-reload', label: 'Auto-Reload When File Changes', type: 'checkbox', checked: S.autoReload },
  ], e.currentTarget));
  splitter($('#sidebarSplitter'), (dx) => {
    S.sidebarW = Math.min(Math.max(S.sidebarW + dx, 180), 640);
    applyWidths();
  }, () => store.set('sidebarW', S.sidebarW));
  window.addEventListener('resize', () => layoutCanvases());

  api.onOpenFiles((files) => openFiles(files));
  api.onFileChanged((p) => {
    if (!S.autoReload) return;
    const doc = S.docs.find((d) => d.path === p);
    if (doc) reload(doc);
  });
}

(async function start() {
  launch = await api.getLaunch();
  S.platform = launch.platform;
  document.body.classList.add(launch.platform === 'darwin' ? 'mac' : 'win');
  if (launch.theme && THEMES[launch.theme]) S.themeId = launch.theme;
  if (await api.fileExists(launch.example)) S.example = launch.example;
  applyTheme();
  applyWidths();
  wireChrome();
  renderAll();
  if (launch.files.length) openFiles(launch.files);
})();
