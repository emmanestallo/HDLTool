'use strict';
/* global Host, PathUtil, h, icon, Prefs, showToast, Menus, copyText */
// Schematic tab: the synthesized netlist drawn by netlistsvg (in a worker process), with pan/zoom,
// cell selection, net highlighting and descending into submodules of the RTL view.

class SchematicView {
  constructor(root, app) {
    this.app = app;
    this.view = 'gate';          // 'rtl' (elaborated, before mapping) | 'gate' (SKY130 cells)
    this.module = null;
    this.modules = [];
    this.result = null;
    this.tf = { x: 0, y: 0, k: 1 };
    this.selected = null;
    this.selectedNet = null;
    this.loading = false;
    this.loadedKey = null;
    this.build(root);
  }

  build(root) {
    this.seg = h('div', { class: 'segmented' },
      h('button', { 'data-v': 'rtl', title: 'The elaborated design (yosys prep), before technology mapping', onclick: () => this.setView('rtl') }, 'RTL'),
      h('button', { 'data-v': 'gate', title: 'After synthesis to SKY130 standard cells', onclick: () => this.setView('gate') }, 'Gate level (SKY130)'));
    this.moduleSel = h('select', { class: 'vs-select small', title: 'Module', onchange: () => this.load(this.moduleSel.value) });
    this.info = h('span', { class: 'dim small ellipsis' });
    this.toolbar = h('div', { class: 'view-toolbar' },
      this.seg, h('span', { class: 'tb-label' }, 'Module'), this.moduleSel,
      h('button', { class: 'icon-btn', title: 'Up to the parent module', onclick: () => this.ascend() }, icon('arrow-up')),
      h('div', { class: 'tb-sep' }), this.info, h('div', { class: 'grow' }),
      h('button', { class: 'icon-btn', title: 'Zoom out', onclick: () => this.zoomBy(1 / 1.25) }, icon('zoom-out')),
      h('button', { class: 'icon-btn', title: 'Zoom in', onclick: () => this.zoomBy(1.25) }, icon('zoom-in')),
      h('button', { class: 'icon-btn', title: 'Fit (F)', onclick: () => this.fit() }, icon('screen-full')),
      h('button', { class: 'icon-btn', title: 'Export SVG…', onclick: () => this.exportSvg() }, icon('save')));
    this.stage = h('div', { class: 'schem-stage' });
    this.viewport = h('div', { class: 'schem-viewport', tabindex: '0' }, this.stage);
    this.empty = h('div', { class: 'view-empty' });
    this.panel = h('div', { class: 'schem-info hidden' });
    root.append(this.toolbar, h('div', { class: 'view-body' }, this.viewport, this.empty, this.panel));
    this.bindPanZoom();
    this.updateSeg();
    this.showEmpty();
  }

  updateSeg() {
    for (const b of this.seg.children) b.classList.toggle('on', b.dataset.v === this.view);
  }

  jsonPath() {
    const run = this.app.runDir();
    return run ? PathUtil.join(run, 'results', this.view === 'rtl' ? 'rtl.json' : 'gate.json') : null;
  }

  available() { const p = this.jsonPath(); return !!(p && Host.fs.exists(p)); }

  setView(v) {
    if (this.view === v) return;
    this.view = v;
    this.module = null;
    this.updateSeg();
    this.load(null);
  }

  showEmpty(msg) {
    this.stage.innerHTML = '';
    this.result = null;
    this.panel.classList.add('hidden');
    this.empty.classList.remove('hidden');
    this.empty.innerHTML = '';
    const running = this.app.running;
    this.empty.append(icon('circuit-board', 'big-icon'),
      h('div', { class: 'big' }, msg || (running ? 'Synthesis is running…' : 'No schematic yet')),
      h('div', { class: 'dim' }, msg ? '' : 'Run synthesis to draw the netlist: the RTL view shows the elaborated design, the gate-level view the SKY130 cells.'),
      !running && this.app.project ? h('button', { class: 'vs-button', onclick: () => this.app.run('synth', 'synth') }, icon('play'), 'Run Synthesis') : null);
    this.info.textContent = '';
  }

  // Draws the current view; module null = the top module.
  async load(module, force = false) {
    const json = this.jsonPath();
    if (!json || !Host.fs.exists(json)) { this.moduleSel.innerHTML = ''; this.showEmpty(); return; }
    const st = Host.fs.stat(json);
    const key = [json, module || '', st && st.mtime, force].join('|');
    if (key === this.loadedKey && this.result) return;
    this.loading = true;
    this.empty.classList.remove('hidden');
    this.empty.innerHTML = '';
    this.empty.append(h('div', { class: 'spin codicon codicon-loading big-icon' }), h('div', null, 'Drawing the schematic…'),
      h('button', { class: 'vs-button secondary small', onclick: () => Host.cancelSchematic() }, 'Stop'));
    const res = await Host.schematic({ json, view: this.view, module, maxCells: Prefs.get('schematicMaxCells'), force });
    this.loading = false;
    this.modules = res.modules || [];
    this.fillModules(res.module);
    if (!res.ok) {
      this.showEmpty(res.tooBig ? 'Large netlist' : (res.cancelled ? 'Stopped' : 'Could not draw the schematic'));
      this.empty.append(h('div', { class: 'dim selectable wrap', style: 'max-width:640px' }, res.error || ''));
      if (res.tooBig) this.empty.append(h('button', { class: 'vs-button', onclick: () => this.load(res.module, true) }, 'Draw Anyway'));
      return;
    }
    this.loadedKey = key;
    this.result = res;
    this.module = res.module;
    this.empty.classList.add('hidden');
    this.stage.innerHTML = res.svg;
    this.svg = this.stage.querySelector('svg');
    this.svgW = parseFloat(this.svg.getAttribute('width')) || 100;
    this.svgH = parseFloat(this.svg.getAttribute('height')) || 100;
    this.selected = null;
    this.selectedNet = null;
    this.panel.classList.add('hidden');
    const mod = this.modules.find((m) => m.name === res.module);
    this.info.textContent = `${res.cells} cell${res.cells === 1 ? '' : 's'}` + (this.view === 'gate' ? ' · SKY130 sky130_fd_sc_hd' : ' · elaborated RTL') + (mod && mod.top ? ' · top' : '');
    this.fit();
  }

  fillModules(current) {
    this.moduleSel.innerHTML = '';
    for (const m of this.modules) this.moduleSel.append(h('option', { value: m.name, selected: m.name === current }, `${m.label || m.name}${m.top ? ' · top' : ''} — ${m.cells} cells`));
    this.moduleSel.disabled = this.modules.length <= 1;
  }

  ascend() {
    if (!this.result) return;
    // the parent: a module that instantiates the current one
    const json = this.jsonPath();
    try {
      const mods = JSON.parse(Host.fs.readText(json)).modules;
      const parent = Object.keys(mods).find((n) => Object.values(mods[n].cells || {}).some((c) => c.type === this.module));
      if (parent) this.load(parent); else showToast('This is the top module');
    } catch { /* ignore */ }
  }

  // ---------------------------------------------------------------- pan / zoom

  apply() {
    const { x, y, k } = this.tf;
    this.stage.style.transform = `translate(${x}px, ${y}px) scale(${k})`;
  }

  fit() {
    if (!this.svg) return;
    const r = this.viewport.getBoundingClientRect();
    this.userMoved = false;
    const k = Math.min((r.width - 40) / this.svgW, (r.height - 40) / this.svgH, 2.5);
    this.tf = { k, x: (r.width - this.svgW * k) / 2, y: (r.height - this.svgH * k) / 2 };
    this.apply();
  }

  zoomBy(f, cx, cy) {
    const r = this.viewport.getBoundingClientRect();
    if (cx == null) { cx = r.width / 2; cy = r.height / 2; }
    const k = Math.max(0.02, Math.min(40, this.tf.k * f));
    const s = k / this.tf.k;
    this.tf = { k, x: cx - (cx - this.tf.x) * s, y: cy - (cy - this.tf.y) * s };
    this.userMoved = true;
    this.apply();
  }

  bindPanZoom() {
    const vp = this.viewport;
    vp.addEventListener('wheel', (e) => {
      e.preventDefault();
      const r = vp.getBoundingClientRect();
      if (e.ctrlKey || !e.shiftKey) this.zoomBy(Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0015)), e.clientX - r.left, e.clientY - r.top);
      else { this.tf.x -= e.deltaY; this.apply(); }
    }, { passive: false });
    let drag = null;
    vp.addEventListener('mousedown', (e) => {
      if (e.button !== 0 && e.button !== 1) return;
      vp.focus();
      drag = { x: e.clientX, y: e.clientY, tx: this.tf.x, ty: this.tf.y, moved: false };
    });
    window.addEventListener('mousemove', (e) => {
      if (!drag) return;
      const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
      if (Math.abs(dx) + Math.abs(dy) > 3) { drag.moved = true; vp.classList.add('panning'); }
      this.tf.x = drag.tx + dx; this.tf.y = drag.ty + dy;
      if (drag.moved) this.userMoved = true;
      this.apply();
    });
    window.addEventListener('mouseup', (e) => {
      if (!drag) return;
      const wasClick = !drag.moved;
      drag = null;
      vp.classList.remove('panning');
      if (wasClick && e.target && vp.contains(e.target)) this.clickAt(e.target);
    });
    vp.addEventListener('dblclick', (e) => {
      const g = e.target.closest && e.target.closest('g[id^="cell_"]');
      if (!g || !this.result) return;
      const info = this.result.cellInfo[g.id.slice(5)];
      if (info && info.submodule) this.load(info.type);
    });
    vp.addEventListener('keydown', (e) => {
      if (e.key === 'f' || e.key === 'F') this.fit();
      else if (e.key === '+' || e.key === '=') this.zoomBy(1.25);
      else if (e.key === '-') this.zoomBy(0.8);
      else if (e.key === 'Escape') this.select(null);
    });
    vp.addEventListener('contextmenu', (e) => {
      const g = e.target.closest && e.target.closest('g[id^="cell_"]');
      if (!g || !this.result) return;
      e.preventDefault();
      const name = g.id.slice(5);
      const info = this.result.cellInfo[name];
      Menus.popup([
        { label: 'Copy Instance Name', action: () => copyText(name) },
        info ? { label: 'Copy Cell Type', action: () => copyText(info.type) } : null,
        info && info.submodule ? { label: `Open ${info.type}`, action: () => this.load(info.type) } : null,
        info && this.view === 'gate' ? { label: 'Find in Layout', action: () => this.app.findInLayout(name) } : null,
      ], e);
    });
    new ResizeObserver(() => { if (this.svg && !this.userMoved) this.fit(); }).observe(vp);
  }

  // ---------------------------------------------------------------- selection

  clickAt(target) {
    const g = target.closest && target.closest('g[id^="cell_"]');
    if (g) { this.select(g.id.slice(5)); return; }
    const cls = target.getAttribute && (target.getAttribute('class') || '');
    const m = /\bnet_(\S+)/.exec(cls);
    if (m) { this.selectNet(m[1]); return; }
    this.select(null);
  }

  clearMarks() {
    for (const el of this.stage.querySelectorAll('.sel, .net-sel')) el.classList.remove('sel', 'net-sel');
  }

  select(name) {
    this.clearMarks();
    this.selected = name;
    this.selectedNet = null;
    if (!name || !this.result) { this.panel.classList.add('hidden'); return; }
    const g = this.stage.querySelector(`g[id="cell_${CSS.escape(name)}"]`);
    if (g) g.classList.add('sel');
    const info = this.result.cellInfo[name];
    this.panel.innerHTML = '';
    this.panel.classList.remove('hidden');
    const title = info ? info.short : name;
    this.panel.append(h('div', { class: 'insp-title' }, title, h('button', { class: 'icon-btn', style: 'margin-left:auto', title: 'Close', onclick: () => this.select(null) }, icon('close'))),
      h('div', { class: 'kv' }, h('span', { class: 'dim' }, 'Instance'), h('span', { class: 'mono selectable' }, name)));
    if (info) {
      this.panel.append(h('div', { class: 'kv' }, h('span', { class: 'dim' }, 'Cell'), h('span', { class: 'mono selectable' }, info.type)));
      const rows = Object.entries(info.ports).map(([p, d]) => h('div', { class: 'pin-line' },
        h('span', { class: 'pin-dir ' + d.dir }, d.dir === 'output' ? '→' : d.dir === 'input' ? '←' : '↔'),
        h('span', { class: 'mono' }, p), h('span', { class: 'dim mono small ellipsis' }, d.bits.map((b) => (typeof b === 'number' ? 'n' + b : b)).join(' '))));
      this.panel.append(h('div', { class: 'insp-heading' }, 'Pins'), ...rows);
      if (info.submodule) this.panel.append(h('button', { class: 'vs-button small', onclick: () => this.load(info.type) }, icon('arrow-down'), `Open ${info.type}`));
      if (this.view === 'gate' && this.app.layoutAvailable()) this.panel.append(h('button', { class: 'vs-button secondary small', onclick: () => this.app.findInLayout(name) }, icon('search'), 'Find in Layout'));
    }
  }

  selectNet(id) {
    this.clearMarks();
    this.selected = null;
    this.selectedNet = id;
    for (const el of this.stage.querySelectorAll('.net_' + CSS.escape(id))) el.classList.add('net-sel');
    this.panel.classList.add('hidden');
  }

  async exportSvg() {
    if (!this.result) return;
    const def = PathUtil.join(this.app.runDir(), 'results', `${this.module}_${this.view}.svg`);
    const p = await Host.saveDialog({ defaultPath: def, filters: [{ name: 'SVG', extensions: ['svg'] }] });
    if (!p) return;
    // a standalone file needs its own colors
    const css = '<style>svg{stroke:#000;fill:none}text{fill:#000;stroke:none;font:bold 10px monospace}.nodelabel{text-anchor:middle}.inputPortLabel{text-anchor:end}.splitjoinBody{fill:#000}</style>';
    const svg = this.result.svg.replace(/<style>\s*<\/style>/, css);
    const err = Host.fs.writeText(p, svg);
    showToast(err ? 'Could not save: ' + err : 'Saved ' + PathUtil.basename(p));
  }
}

if (typeof module !== 'undefined') module.exports = { SchematicView };
