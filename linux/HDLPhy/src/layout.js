'use strict';
/* global Host, PathUtil, h, icon, showToast, Menus, copyText, Fmt */
// Layout tab: the placed-and-routed layout (GDS geometry exported by KLayout, flow/klayout/def2gds.py)
// drawn on a canvas with the PDK's layer colors, layer visibility, cell outlines, pan/zoom and picking.

const LAYOUT_STAGES = [
  { id: 'route', label: 'Routed (final GDS)', def: 'final.def', json: 'layout.json' },
  { id: 'cts', label: 'After clock tree', def: '4_cts.def', json: 'layout_cts.json' },
  { id: 'place', label: 'After placement', def: '3_place.def', json: 'layout_place.json' },
  { id: 'floorplan', label: 'Floorplan', def: '2_floorplan.def', json: 'layout_floorplan.json' },
];

function hexToRgba(hex, a) {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex || '');
  const n = m ? parseInt(m[1], 16) : 0x808080;
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}

class LayoutView {
  constructor(root, app) {
    this.app = app;
    this.stageId = 'route';
    this.data = null;            // { header, ints, paths: Map(layerIndex -> Path2D) }
    this.view = { ox: 0, oy: 0, k: 1 };
    this.showCells = true;
    this.showLabels = true;
    this.hidden = new Set();     // layer names hidden by the user (others follow the default)
    this.shown = new Set();      // layer names shown by the user although hidden by default
    this.highlight = null;       // instance bbox to mark
    this.hover = null;
    this.loadedKey = null;
    this.build(root);
  }

  build(root) {
    this.stageSel = h('select', { class: 'vs-select small', title: 'Which result to show', onchange: () => this.setStage(this.stageSel.value) });
    this.cellsBtn = h('button', { class: 'icon-btn on', title: 'Cell outlines and names', onclick: () => { this.showCells = !this.showCells; this.cellsBtn.classList.toggle('on', this.showCells); this.draw(); } }, icon('symbol-class'));
    this.labelsBtn = h('button', { class: 'icon-btn on', title: 'Pin labels', onclick: () => { this.showLabels = !this.showLabels; this.labelsBtn.classList.toggle('on', this.showLabels); this.draw(); } }, icon('tag'));
    this.info = h('span', { class: 'dim small ellipsis' });
    this.toolbar = h('div', { class: 'view-toolbar' },
      h('span', { class: 'tb-label' }, 'Show'), this.stageSel, h('div', { class: 'tb-sep' }), this.info, h('div', { class: 'grow' }),
      this.cellsBtn, this.labelsBtn, h('div', { class: 'tb-sep' }),
      h('button', { class: 'icon-btn', title: 'Zoom out', onclick: () => this.zoomBy(1 / 1.4) }, icon('zoom-out')),
      h('button', { class: 'icon-btn', title: 'Zoom in', onclick: () => this.zoomBy(1.4) }, icon('zoom-in')),
      h('button', { class: 'icon-btn', title: 'Fit (F)', onclick: () => this.fit() }, icon('screen-full')),
      h('button', { class: 'icon-btn', title: 'Export PNG…', onclick: () => this.exportPng() }, icon('device-camera')),
      h('button', { class: 'vs-button secondary small', title: 'Open the GDS in KLayout', onclick: () => this.openKLayout() }, icon('link-external'), 'KLayout'));
    this.canvas = h('canvas', { class: 'layout-canvas', tabindex: '0' });
    this.empty = h('div', { class: 'view-empty' });
    this.layersList = h('div', { class: 'scroll' });
    this.layersPanel = h('div', { class: 'layers-panel' },
      h('div', { class: 'section-header' }, h('span', { style: 'padding-left:8px' }, 'LAYERS'), h('div', { class: 'grow' }),
        h('button', { class: 'icon-btn', title: 'Show all', onclick: () => this.setAllLayers(true) }, icon('eye')),
        h('button', { class: 'icon-btn', title: 'Hide all', onclick: () => this.setAllLayers(false) }, icon('eye-closed')),
        h('button', { class: 'icon-btn', title: 'Defaults', onclick: () => { this.hidden.clear(); this.shown.clear(); this.renderLayers(); this.draw(); } }, icon('discard'))),
      this.layersList);
    this.coords = h('div', { class: 'layout-coords mono' });
    const wrap = h('div', { class: 'layout-wrap' }, this.canvas, this.coords);
    root.append(this.toolbar, h('div', { class: 'view-body row' }, wrap, this.empty, this.layersPanel));
    this.bind();
    this.showEmpty();
    new ResizeObserver(() => this.resize()).observe(wrap);
  }

  // ---------------------------------------------------------------- data

  results() { const r = this.app.runDir(); return r ? PathUtil.join(r, 'results') : null; }

  refreshStages() {
    const res = this.results();
    this.stageSel.innerHTML = '';
    let any = false;
    for (const s of LAYOUT_STAGES) {
      const has = res && Host.fs.exists(PathUtil.join(res, s.def));
      if (!has) continue;
      any = true;
      this.stageSel.append(h('option', { value: s.id, selected: s.id === this.stageId }, s.label));
    }
    if (!any) this.stageSel.append(h('option', { value: '' }, 'No layout yet'));
    this.stageSel.disabled = !any;
    return any;
  }

  available() {
    const res = this.results();
    return !!(res && Host.fs.exists(PathUtil.join(res, 'layout.json')));
  }

  setStage(id) {
    this.stageId = id;
    this.load();
  }

  showEmpty(msg, detail) {
    this.data = null;
    this.empty.classList.remove('hidden');
    this.layersPanel.classList.add('hidden');
    this.empty.innerHTML = '';
    const running = this.app.running;
    this.empty.append(icon('layers', 'big-icon'),
      h('div', { class: 'big' }, msg || (running ? 'Place and route is running…' : 'No layout yet')),
      h('div', { class: 'dim' }, detail != null ? detail : 'Run the full flow (synthesis, floorplan, placement, clock tree, routing, GDS) to see the layout.'),
      !running && this.app.project && !msg ? h('button', { class: 'vs-button', onclick: () => this.app.run('synth', LAST_STAGE) }, icon('play'), 'Run Full Flow') : null);
    this.info.textContent = '';
    this.draw();
  }

  async load(force = false) {
    const any = this.refreshStages();
    const res = this.results();
    if (!any || !res) { this.showEmpty(); return; }
    let stage = LAYOUT_STAGES.find((s) => s.id === this.stageId && Host.fs.exists(PathUtil.join(res, s.def)));
    if (!stage) { stage = LAYOUT_STAGES.find((s) => Host.fs.exists(PathUtil.join(res, s.def))); this.stageId = stage.id; this.stageSel.value = stage.id; }
    const json = PathUtil.join(res, stage.json);
    const def = PathUtil.join(res, stage.def);
    const jst = Host.fs.stat(json), dst = Host.fs.stat(def);
    if (!jst || (dst && jst.mtime < dst.mtime)) {
      // intermediate views are exported on request (the final one comes with the GDS stage)
      if (stage.id === 'route' && !jst) { this.showEmpty('The GDS stage has not run yet', 'Run the flow up to GDS to export the routed layout.'); return; }
      if (this.app.running) { this.showEmpty('Busy', 'The layout view can be exported when the current run ends.'); return; }
      this.showEmpty('Exporting the layout…', '');
      const ok = await this.app.exportView(stage.id);
      if (!ok) { this.showEmpty('Could not export the layout', 'See the Output panel.'); return; }
    }
    const st = Host.fs.stat(json);
    const key = json + '|' + (st && st.mtime);
    if (key === this.loadedKey && this.data && !force) { this.draw(); return; }
    const r = await Host.readLayout(json);
    if (!r.ok) { this.showEmpty('Could not read the layout', r.error); return; }
    this.loadedKey = key;
    this.setData(r.header, r.bin);
  }

  setData(header, bin) {
    const ints = new Int32Array(bin.buffer, bin.byteOffset, Math.floor(bin.byteLength / 4));
    const paths = new Map();
    header.layers.forEach((L, i) => {
      const p = new Path2D();
      let j = L.offset;
      const end = L.offset + L.length;
      while (j < end) {
        const nc = ints[j++];
        for (let c = 0; c < nc; c++) {
          const np = ints[j++];
          p.moveTo(ints[j], ints[j + 1]);
          for (let q = 1; q < np; q++) p.lineTo(ints[j + 2 * q], ints[j + 2 * q + 1]);
          p.closePath();
          j += 2 * np;
        }
      }
      paths.set(i, p);
    });
    this.data = { header, ints, paths };
    this.empty.classList.add('hidden');
    this.layersPanel.classList.remove('hidden');
    const dbu = header.dbu;
    const [x0, y0, x1, y1] = header.bbox;
    const logic = header.instances.filter((i) => i.kind === 'logic' || i.kind === 'clock' || i.kind === 'tie').length;
    this.info.textContent = `${header.top} · ${Fmt.num((x1 - x0) * dbu)} × ${Fmt.num((y1 - y0) * dbu)} µm · ${logic} cells (+${header.instances.length - logic} tap/fill) · ${header.polygons.toLocaleString()} polygons`;
    this.renderLayers();
    this.resize();
    this.fit();
  }

  isVisible(L) {
    if (this.hidden.has(L.name)) return false;
    if (this.shown.has(L.name)) return true;
    return L.visible;
  }

  setAllLayers(on) {
    if (!this.data) return;
    for (const L of this.data.header.layers) {
      if (on) { this.hidden.delete(L.name); this.shown.add(L.name); } else { this.shown.delete(L.name); this.hidden.add(L.name); }
    }
    this.renderLayers();
    this.draw();
  }

  renderLayers() {
    this.layersList.innerHTML = '';
    if (!this.data) return;
    const layers = this.data.header.layers.map((L, i) => ({ L, i })).reverse();   // top of the stack first
    for (const { L } of layers) {
      const vis = this.isVisible(L);
      const row = h('div', { class: 'layer-row' + (vis ? '' : ' off'), title: `${L.name}  ${L.layer}/${L.datatype}  ·  ${L.count.toLocaleString()} polygons\nClick: show/hide · Alt+click: only this layer` },
        h('span', { class: 'swatch', style: `background:${hexToRgba(L.fill, 0.55)};border-color:${L.frame}` }),
        h('span', { class: 'ellipsis grow' }, L.name), h('span', { class: 'dim tiny mono' }, `${L.layer}/${L.datatype}`));
      row.addEventListener('click', (e) => {
        if (e.altKey) {
          for (const M of this.data.header.layers) { this.shown.delete(M.name); this.hidden.add(M.name); }
          this.hidden.delete(L.name); this.shown.add(L.name);
        } else if (this.isVisible(L)) { this.shown.delete(L.name); this.hidden.add(L.name); } else { this.hidden.delete(L.name); this.shown.add(L.name); }
        this.renderLayers();
        this.draw();
      });
      this.layersList.append(row);
    }
  }

  // ---------------------------------------------------------------- view transform

  resize() {
    const r = this.canvas.parentElement.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    this.cw = Math.max(1, r.width); this.ch = Math.max(1, r.height);
    this.canvas.width = Math.round(this.cw * dpr);
    this.canvas.height = Math.round(this.ch * dpr);
    this.canvas.style.width = this.cw + 'px';
    this.canvas.style.height = this.ch + 'px';
    if (this.data && !this.userMoved) this.fit(); else this.draw();
  }

  fit() {
    this.userMoved = false;
    if (!this.data) { this.draw(); return; }
    const [x0, y0, x1, y1] = this.data.header.bbox;
    const w = Math.max(1, x1 - x0), hgt = Math.max(1, y1 - y0);
    const pad = this.showLabels ? 150 : 40;   // room for the pin labels outside the die
    const k = Math.min((this.cw - pad) / w, (this.ch - pad) / hgt);
    this.view = { k, ox: (this.cw - w * k) / 2 - x0 * k, oy: (this.ch + hgt * k) / 2 + y0 * k };
    this.draw();
  }

  toWorld(sx, sy) { return { x: (sx - this.view.ox) / this.view.k, y: (this.view.oy - sy) / this.view.k }; }

  zoomBy(f, sx, sy) {
    if (sx == null) { sx = this.cw / 2; sy = this.ch / 2; }
    const w = this.toWorld(sx, sy);
    const k = Math.max(1e-5, Math.min(50, this.view.k * f));
    this.view = { k, ox: sx - w.x * k, oy: sy + w.y * k };
    this.userMoved = true;
    this.draw();
  }

  zoomToBox(b, pad = 6) {
    const [x0, y0, x1, y1] = b;
    const w = Math.max(1, x1 - x0), hgt = Math.max(1, y1 - y0);
    // never zoom out past the whole-layout view when the box is large compared with the die
    const fitK = this.data ? Math.min((this.cw - 40) / Math.max(1, this.data.header.bbox[2] - this.data.header.bbox[0]), (this.ch - 40) / Math.max(1, this.data.header.bbox[3] - this.data.header.bbox[1])) : 0;
    const k = Math.max(fitK, Math.min(this.cw / (w * pad), this.ch / (hgt * pad), 2));
    const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
    this.view = { k, ox: this.cw / 2 - cx * k, oy: this.ch / 2 + cy * k };
    this.userMoved = true;
    this.draw();
  }

  // ---------------------------------------------------------------- drawing

  draw() {
    if (this.raf) return;
    this.raf = requestAnimationFrame(() => { this.raf = null; this.paint(); });
  }

  paint() {
    const ctx = this.canvas.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    const css = getComputedStyle(document.documentElement);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.fillStyle = css.getPropertyValue('--layoutBG').trim() || '#111';
    ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
    if (!this.data) return;
    const { k, ox, oy } = this.view;
    const { header, paths } = this.data;
    // world (DBU, y up) -> device pixels
    ctx.setTransform(k * dpr, 0, 0, -k * dpr, ox * dpr, oy * dpr);
    const px = 1 / k;   // one CSS pixel in DBU
    header.layers.forEach((L, i) => {
      if (!this.isVisible(L)) return;
      const p = paths.get(i);
      const boundary = /boundary|outline/i.test(L.name);
      if (!boundary) {
        ctx.fillStyle = hexToRgba(L.fill, /^(nwell|pwell|diff|tap)/.test(L.name) ? 0.22 : 0.38);
        ctx.fill(p, 'nonzero');
      }
      ctx.strokeStyle = hexToRgba(L.frame, boundary ? 0.7 : 0.95);
      ctx.lineWidth = px;
      ctx.stroke(p);
    });
    // cell outlines (and names once they are big enough to read)
    if (this.showCells) {
      ctx.lineWidth = px;
      ctx.strokeStyle = css.getPropertyValue('--cellOutline').trim() || 'rgba(255,255,255,0.35)';
      ctx.beginPath();
      for (const inst of header.instances) {
        if (inst.kind === 'fill' || inst.kind === 'decap' || inst.kind === 'tap') continue;
        const [x0, y0, x1, y1] = inst.bbox;
        ctx.rect(x0, y0, x1 - x0, y1 - y0);
      }
      ctx.stroke();
    }
    if (this.highlight) {
      const [x0, y0, x1, y1] = this.highlight;
      ctx.lineWidth = 3 * px;
      ctx.strokeStyle = css.getPropertyValue('--accent').trim() || '#0078D4';
      ctx.strokeRect(x0, y0, x1 - x0, y1 - y0);
      ctx.fillStyle = hexToRgba(css.getPropertyValue('--accent').trim() || '#0078D4', 0.18);
      ctx.fillRect(x0, y0, x1 - x0, y1 - y0);
    }
    if (this.hover && this.hover.inst) {
      const [x0, y0, x1, y1] = this.hover.inst.bbox;
      ctx.lineWidth = 2 * px;
      ctx.strokeStyle = 'rgba(255,255,255,0.85)';
      ctx.strokeRect(x0, y0, x1 - x0, y1 - y0);
    }
    // text in screen space
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const fg = css.getPropertyValue('--fg').trim() || '#ccc';
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'center';
    if (this.showCells) {
      ctx.font = '10px "Cascadia Mono", Consolas, monospace';
      ctx.fillStyle = fg;
      for (const inst of header.instances) {
        if (inst.kind === 'fill' || inst.kind === 'decap' || inst.kind === 'tap') continue;
        const [x0, y0, x1, y1] = inst.bbox;
        const w = (x1 - x0) * k, hh = (y1 - y0) * k;
        if (w < 46 || hh < 16) continue;
        const sx = ox + (x0 + x1) / 2 * k, sy = oy - (y0 + y1) / 2 * k;
        if (sx < -w || sx > this.cw + w || sy < -hh || sy > this.ch + hh) continue;
        const short = inst.cell.split('__').pop();
        ctx.fillText(short, sx, sy - (hh > 30 ? 6 : 0), w - 4);
        if (hh > 30) { ctx.globalAlpha = 0.6; ctx.fillText(inst.name, sx, sy + 7, w - 4); ctx.globalAlpha = 1; }
      }
    }
    if (this.showLabels) {
      // pin labels point away from the die edge they sit on (rotated on the top and bottom edges)
      ctx.font = 'bold 11px system-ui, sans-serif';
      ctx.fillStyle = fg;
      const [bx0, by0, bx1, by1] = header.bbox;
      const tol = Math.max(bx1 - bx0, by1 - by0) * 0.03;
      const seen = new Set();
      for (const lab of header.labels) {
        const key = lab.text + '@' + lab.x + ',' + lab.y;
        if (seen.has(key)) continue;
        seen.add(key);
        const sx = ox + lab.x * k, sy = oy - lab.y * k;
        if (sx < -80 || sx > this.cw + 80 || sy < -80 || sy > this.ch + 80) continue;
        const edge = lab.y - by0 < tol ? 'bottom' : by1 - lab.y < tol ? 'top' : lab.x - bx0 < tol ? 'left' : bx1 - lab.x < tol ? 'right' : null;
        ctx.save();
        ctx.translate(sx, sy);
        if (edge === 'bottom') { ctx.rotate(Math.PI / 2); ctx.textAlign = 'left'; ctx.fillText(lab.text, 4, 0); }
        else if (edge === 'top') { ctx.rotate(-Math.PI / 2); ctx.textAlign = 'left'; ctx.fillText(lab.text, 4, 0); }
        else if (edge === 'left') { ctx.textAlign = 'right'; ctx.fillText(lab.text, -4, 0); }
        else { ctx.textAlign = 'left'; ctx.fillText(lab.text, 4, 0); }
        ctx.restore();
      }
    }
    // scale bar
    const um = this.niceLength(120 / k * header.dbu);
    const len = um / header.dbu * k;
    ctx.strokeStyle = fg; ctx.fillStyle = fg; ctx.lineWidth = 1.5;
    const bx = 16, by = this.ch - 18;
    ctx.beginPath(); ctx.moveTo(bx, by - 4); ctx.lineTo(bx, by); ctx.lineTo(bx + len, by); ctx.lineTo(bx + len, by - 4); ctx.stroke();
    ctx.textAlign = 'center'; ctx.font = '11px system-ui, sans-serif';
    ctx.fillText(um >= 1 ? `${um} µm` : `${Math.round(um * 1000)} nm`, bx + len / 2, by - 10);
  }

  niceLength(v) {
    const e = Math.pow(10, Math.floor(Math.log10(v)));
    for (const m of [1, 2, 5, 10]) if (m * e >= v * 0.6) return +(m * e).toPrecision(3);
    return v;
  }

  // ---------------------------------------------------------------- interaction

  instanceAt(wx, wy) {
    if (!this.data) return null;
    let best = null;
    for (const inst of this.data.header.instances) {
      const [x0, y0, x1, y1] = inst.bbox;
      if (wx >= x0 && wx <= x1 && wy >= y0 && wy <= y1) {
        if (!best || (inst.kind !== 'fill' && inst.kind !== 'decap' && inst.kind !== 'tap')) best = inst;
      }
    }
    return best;
  }

  bind() {
    const cv = this.canvas;
    cv.addEventListener('wheel', (e) => {
      e.preventDefault();
      const r = cv.getBoundingClientRect();
      if (e.shiftKey && !e.ctrlKey) { this.view.ox -= e.deltaY; this.userMoved = true; this.draw(); return; }
      this.zoomBy(Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0015)), e.clientX - r.left, e.clientY - r.top);
    }, { passive: false });
    let drag = null;
    cv.addEventListener('mousedown', (e) => {
      cv.focus();
      if (e.button !== 0 && e.button !== 1) return;
      drag = { x: e.clientX, y: e.clientY, ox: this.view.ox, oy: this.view.oy, moved: false };
    });
    window.addEventListener('mousemove', (e) => {
      if (drag) {
        const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
        if (Math.abs(dx) + Math.abs(dy) > 3) { drag.moved = true; cv.classList.add('panning'); }
        this.view.ox = drag.ox + dx; this.view.oy = drag.oy + dy;
        this.userMoved = true;
        this.draw();
        return;
      }
      if (e.target !== cv || !this.data) return;
      const r = cv.getBoundingClientRect();
      const w = this.toWorld(e.clientX - r.left, e.clientY - r.top);
      const dbu = this.data.header.dbu;
      const inst = this.instanceAt(w.x, w.y);
      const changed = (inst && inst.name) !== (this.hover && this.hover.inst && this.hover.inst.name);
      this.hover = { x: w.x, y: w.y, inst };
      this.coords.textContent = `${(w.x * dbu).toFixed(3)}, ${(w.y * dbu).toFixed(3)} µm` + (inst ? `   ${inst.name || '(unnamed)'} · ${inst.cell}` : '');
      if (changed && this.showCells) this.draw();
    });
    window.addEventListener('mouseup', (e) => {
      if (!drag) return;
      const click = !drag.moved;
      drag = null;
      cv.classList.remove('panning');
      if (click && e.target === cv) {
        const inst = this.hover && this.hover.inst;
        this.highlight = inst ? inst.bbox : null;
        this.draw();
      }
    });
    cv.addEventListener('mouseleave', () => { this.hover = null; this.coords.textContent = ''; this.draw(); });
    cv.addEventListener('dblclick', () => { if (this.hover && this.hover.inst) this.zoomToBox(this.hover.inst.bbox); });
    cv.addEventListener('keydown', (e) => {
      if (e.key === 'f' || e.key === 'F') this.fit();
      else if (e.key === '+' || e.key === '=') this.zoomBy(1.4);
      else if (e.key === '-') this.zoomBy(1 / 1.4);
      else if (e.key === 'Escape') { this.highlight = null; this.draw(); }
    });
    cv.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      const inst = this.hover && this.hover.inst;
      Menus.popup([
        inst ? { type: 'header', label: `${inst.name} · ${inst.cell}` } : null,
        inst ? { label: 'Copy Instance Name', action: () => copyText(inst.name) } : null,
        inst ? { label: 'Copy Cell Type', action: () => copyText(inst.cell) } : null,
        inst && inst.kind !== 'fill' && inst.kind !== 'tap' && inst.kind !== 'decap' ? { label: 'Show in Schematic', action: () => this.app.findInSchematic(inst.name) } : null,
        inst ? { type: 'separator' } : null,
        { label: 'Fit', action: () => this.fit() },
        { label: 'Copy Coordinates', action: () => this.hover && copyText(`${(this.hover.x * this.data.header.dbu).toFixed(3)} ${(this.hover.y * this.data.header.dbu).toFixed(3)}`) },
      ], e);
    });
  }

  // Zooms to the instance with this (netlist) name; true if found.
  find(name) {
    if (!this.data) return false;
    const want = name.replace(/^\\/, '');
    const inst = this.data.header.instances.find((i) => i.name === want || i.name === '\\' + want || i.name.replace(/\\/g, '') === want.replace(/\\/g, ''));
    if (!inst) return false;
    this.highlight = inst.bbox;
    this.zoomToBox(inst.bbox, 4);
    return true;
  }

  openKLayout() {
    const res = this.results();
    const gds = res && PathUtil.join(res, 'final.gds');
    if (!gds || !Host.fs.exists(gds)) { showToast('No GDS yet: run the flow up to the GDS stage'); return; }
    // with the DRC markers, when the DRC stage has run
    const rdb = PathUtil.join(PathUtil.dirname(res), 'reports', 'drc_klayout.lyrdb');
    Host.openKLayout(gds, this.app.lypPath(), Host.fs.exists(rdb) ? rdb : null).then((r) => { if (!r.ok) showToast(r.error); });
  }

  async exportPng() {
    if (!this.data) return;
    const p = await Host.saveDialog({ defaultPath: PathUtil.join(this.results(), `${this.data.header.top}_${this.stageId}.png`), filters: [{ name: 'PNG', extensions: ['png'] }] });
    if (!p) return;
    this.paint();
    const url = this.canvas.toDataURL('image/png');
    const bin = Uint8Array.from(atob(url.split(',')[1]), (c) => c.charCodeAt(0));
    const err = Host.fs.writeBinary(p, bin);
    showToast(err ? 'Could not save: ' + err : 'Saved ' + PathUtil.basename(p));
  }
}

if (typeof module !== 'undefined') module.exports = { LayoutView, LAYOUT_STAGES };
