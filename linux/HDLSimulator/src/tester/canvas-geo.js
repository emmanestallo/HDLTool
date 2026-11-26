'use strict';
/* global Inst, TS, Stim, pinKey, pinEq */
// HDL Tester canvas geometry: block sizes, pin positions and wire routing. Port of CanvasView.swift.
// Text widths use fixed monospace metrics so layouts match the Mac app.

const Metrics = { monoCharW: 7.10888671875, chipCharW: 6.181640625 };

const StimChip = { width(s) { return Math.min(Stim.summary(s).length, 12) * Metrics.chipCharW + 30; } };

const BlockLayout = {
  rowH: 22, headerH: 30, stub: 30, labelH: 18, pad: 10,
  rowY(i) { return BlockLayout.labelH + BlockLayout.headerH + i * BlockLayout.rowH + BlockLayout.rowH / 2 + 4; },
  make(inst, env) {
    const left = Inst.inputs(inst);
    const right = Inst.outputs(inst).concat(Inst.inouts(inst));
    const labels = {};
    for (const p of inst.ports) labels[p.name] = Inst.rangeLabel(inst, p, env);
    const cw = Metrics.monoCharW;
    const textW = (p) => {
      const r = labels[p.name] || '';
      const dependsOnParams = p.ranges.some((x) => !/^-?\d+$/.test(x.msb.trim()) || !/^-?\d+$/.test(x.lsb.trim()));
      const chars = !dependsOnParams ? r.length : (Inst.resolve(inst, p, env) == null ? 7 : Math.max(r.length, 7));
      return p.name.length * cw + (chars === 0 ? 0 : (chars + 1) * cw * 0.85);
    };
    const lw = left.reduce((m, p) => Math.max(m, textW(p)), 0);
    const rw = right.reduce((m, p) => Math.max(m, textW(p)), 0);
    const titleW = inst.moduleName.length * 7.6 + 50;
    const boxW = Math.ceil(Math.max(150, Math.max(titleW, BlockLayout.pad * 2 + lw + rw + 30)));
    const rows = Math.max(left.length, right.length, 1);
    const boxH = BlockLayout.headerH + rows * BlockLayout.rowH + 8;
    const leftW = BlockLayout.stub + 12;
    const rightW = BlockLayout.stub + (inst.logged.length ? 38 : 12);
    return { left, right, rangeLabels: labels, leftW, rightW, boxW, boxH, totalW: leftW + boxW + rightW, totalH: BlockLayout.labelH + boxH };
  },
};

const SourceLayout = {
  headerH: 26, rowH: 26, stub: 30,
  get pinY() { return SourceLayout.headerH + SourceLayout.rowH / 2 + 1; },
  make(inst) {
    const chip = StimChip.width(Inst.stimulus(inst, 'out'));
    const boxW = Math.ceil(Math.max(120, Math.max(inst.name.length * Metrics.monoCharW + 52, chip + 50)));
    return { boxW, boxH: SourceLayout.headerH + SourceLayout.rowH + 2 };
  },
};

const rect = (x, y, w, hh) => ({ x, y, w, h: hh, minX: x, minY: y, maxX: x + w, maxY: y + hh });
const contains = (r, p) => p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY;
const snap10 = (v) => Math.round(v / 10) * 10;

const PinGeo = {
  lead: 14, laneGap: 8,

  pins(inst, offset = { dx: 0, dy: 0 }) {
    const ox = inst.x + offset.dx, oy = inst.y + offset.dy;
    if (Inst.isSource(inst)) {
      const L = SourceLayout.make(inst);
      const pt = { x: ox + L.boxW + SourceLayout.stub, y: oy + SourceLayout.pinY };
      return [{ ref: { instance: inst.id, pin: 'out' }, dir: 'output', isSource: true, point: pt, rowRect: rect(ox, oy, L.boxW + SourceLayout.stub + 12, L.boxH), width: Inst.sourceWidth(inst) }];
    }
    const env = Inst.paramValues(inst);
    const L = BlockLayout.make(inst, env);
    const out = [];
    const y = (i) => oy + BlockLayout.rowY(i) - BlockLayout.labelH;
    L.left.forEach((p, i) => {
      if (p.unsupported != null) return;
      const pt = { x: ox - BlockLayout.stub, y: y(i) };
      const r = Inst.resolve(inst, p, env);
      out.push({ ref: { instance: inst.id, pin: p.name }, dir: 'input', isSource: false, point: pt,
        rowRect: rect(ox - 140, pt.y - BlockLayout.rowH / 2, 140 + L.boxW / 2, BlockLayout.rowH), width: r ? r.width : null });
    });
    L.right.forEach((p, i) => {
      if (p.unsupported != null || p.dir !== 'output') return;
      const pt = { x: ox + L.boxW + BlockLayout.stub, y: y(i) };
      const r = Inst.resolve(inst, p, env);
      out.push({ ref: { instance: inst.id, pin: p.name }, dir: 'output', isSource: false, point: pt,
        rowRect: rect(ox + L.boxW / 2, pt.y - BlockLayout.rowH / 2, L.boxW / 2 + BlockLayout.stub + 40, BlockLayout.rowH), width: r ? r.width : null });
    });
    return out;
  },
  allPins(state, dragging) {
    const d = new Map();
    for (const inst of state.instances) {
      const off = dragging && dragging.id === inst.id ? { dx: dragging.dx, dy: dragging.dy } : { dx: 0, dy: 0 };
      for (const p of PinGeo.pins(inst, off)) d.set(pinKey(p.ref), p);
    }
    return d;
  },
  target(state, point, wantOutput, excluding) {
    const cands = [...PinGeo.allPins(state, null).values()].filter((p) => !pinEq(p.ref, excluding) && (wantOutput ? p.dir === 'output' : p.dir === 'input'));
    const hit = cands.find((p) => contains(p.rowRect, point));
    if (hit) return hit.ref;
    let near = null, best = Infinity;
    for (const p of cands) { const dd = Math.hypot(p.point.x - point.x, p.point.y - point.y); if (dd < best) { best = dd; near = p; } }
    return near && best < 26 ? near.ref : null;
  },
  trunkX(a, b) {
    if (b.x - a.x < 2 * PinGeo.lead) return null;
    const mid = Math.round((a.x + b.x) / 2 / 10) * 10;
    return Math.min(Math.max(mid, a.x + PinGeo.lead), b.x - PinGeo.lead);
  },
  route(a, b, trunk) {
    const x = trunk != null ? trunk : PinGeo.trunkX(a, b);
    if (x != null) {
      if (Math.abs(a.y - b.y) < 0.5) return [a, b];
      return [a, { x, y: a.y }, { x, y: b.y }, b];
    }
    const x1 = a.x + PinGeo.lead, x2 = b.x - PinGeo.lead;
    const my = Math.abs(a.y - b.y) >= 50 ? Math.round((a.y + b.y) / 2 / 10) * 10 : Math.max(a.y, b.y) + 40;
    return [a, { x: x1, y: a.y }, { x: x1, y: my }, { x: x2, y: my }, { x: x2, y: b.y }, b];
  },
  obstacles(state, dragging) {
    return state.instances.map((inst) => {
      const off = dragging && dragging.id === inst.id ? { dx: dragging.dx, dy: dragging.dy } : { dx: 0, dy: 0 };
      const ox = inst.x + off.dx, oy = inst.y + off.dy;
      if (Inst.isSource(inst)) { const L = SourceLayout.make(inst); return rect(ox - 8, oy - 8, L.boxW + 24, L.boxH + 16); }
      const L = BlockLayout.make(inst, Inst.paramValues(inst));
      return rect(ox - 16, oy - BlockLayout.labelH - 4, L.boxW + 32, L.boxH + BlockLayout.labelH + 12);
    });
  },
  crossings(pts, rects) {
    let n = 0;
    for (let i = 1; i < pts.length; i++) {
      const a = pts[i - 1], b = pts[i];
      const sMinX = Math.min(a.x, b.x), sMaxX = Math.max(a.x, b.x), sMinY = Math.min(a.y, b.y), sMaxY = Math.max(a.y, b.y);
      for (const r of rects) {
        if (a.y === b.y) { if (a.y > r.minY && a.y < r.maxY && sMaxX > r.minX && sMinX < r.maxX) n++; }
        else if (a.x > r.minX && a.x < r.maxX && sMaxY > r.minY && sMinY < r.maxY) n++;
      }
    }
    return n;
  },
  simplify(pts) {
    const out = [];
    for (const p of pts) {
      const l = out[out.length - 1];
      if (l && Math.abs(l.x - p.x) < 0.01 && Math.abs(l.y - p.y) < 0.01) continue;
      if (out.length >= 2) {
        const a = out[out.length - 2], b = out[out.length - 1];
        if ((Math.abs(a.x - b.x) < 0.01 && Math.abs(b.x - p.x) < 0.01) || (Math.abs(a.y - b.y) < 0.01 && Math.abs(b.y - p.y) < 0.01)) { out[out.length - 1] = p; continue; }
      }
      out.push(p);
    }
    return out;
  },
  smartRoute(a, b, rects) {
    let best = PinGeo.route(a, b), bestCost = Infinity;
    const consider = (raw) => {
      const pts = PinGeo.simplify(raw);
      if (pts.length < 2) return;
      let len = 0;
      for (let i = 1; i < pts.length; i++) len += Math.abs(pts[i].x - pts[i - 1].x) + Math.abs(pts[i].y - pts[i - 1].y);
      const cost = PinGeo.crossings(pts, rects) * 10000 + len + (pts.length - 2) * 30;
      if (cost < bestCost) { bestCost = cost; best = pts; }
    };
    const x0 = a.x + PinGeo.lead, x3 = b.x - PinGeo.lead;
    if (x3 >= x0) {
      const xs = new Set([Math.min(Math.max(snap10((a.x + b.x) / 2), x0), x3)]);
      for (const r of rects) { xs.add(snap10(r.minX - 12)); xs.add(snap10(r.maxX + 12)); }
      for (const x of [...xs].sort((p, q) => p - q)) if (x >= x0 && x <= x3) consider([a, { x, y: a.y }, { x, y: b.y }, b]);
    }
    if (bestCost >= 10000 || x3 < x0) {
      const x1s = [x0, ...rects.map((r) => snap10(r.maxX + 12)).filter((v) => v > x0).sort((p, q) => p - q)].slice(0, 4);
      const x2s = [x3, ...rects.map((r) => snap10(r.minX - 12)).filter((v) => v < x3).sort((p, q) => q - p)].slice(0, 4);
      const ys = new Set([a.y, b.y, snap10((a.y + b.y) / 2)]);
      for (const r of rects) { ys.add(snap10(r.minY - 10)); ys.add(snap10(r.maxY + 10)); }
      const ysSorted = [...ys].sort((p, q) => p - q);
      for (const x1 of x1s) for (const x2 of x2s) for (const y of ysSorted) consider([a, { x: x1, y: a.y }, { x: x1, y }, { x: x2, y }, { x: x2, y: b.y }, b]);
    }
    return best;
  },
  routeAll(state, pins, dragging) {
    const rects = PinGeo.obstacles(state, dragging);
    const items = [];
    for (const w of state.wires) {
      const a = pins.get(pinKey(w.from)), b = pins.get(pinKey(w.to));
      if (!a || !b) continue;
      items.push({ w, pts: PinGeo.smartRoute(a.point, b.point, rects).map((p) => ({ x: p.x, y: p.y })), width: a.width });
    }
    for (const vertical of [true, false]) {
      const groups = new Map();
      items.forEach((it, i) => {
        if (it.pts.length < 4) return;
        for (let k = 1; k <= it.pts.length - 3; k++) {
          const p = it.pts[k], q = it.pts[k + 1];
          if (vertical ? Math.abs(p.x - q.x) < 0.01 : Math.abs(p.y - q.y) < 0.01) {
            const key = vertical ? p.x : p.y;
            if (!groups.has(key)) groups.set(key, []);
            groups.get(key).push([i, k]);
          }
        }
      });
      for (const segs of groups.values()) {
        const drivers = [];
        for (const [i] of segs) if (!drivers.some((d) => pinEq(d[0], items[i].w.from))) drivers.push([items[i].w.from, vertical ? items[i].pts[0].y : items[i].pts[0].x]);
        if (drivers.length <= 1) continue;
        drivers.sort((p, q) => p[1] - q[1]);
        for (const [i, k] of segs) {
          const n = Math.max(0, drivers.findIndex((d) => pinEq(d[0], items[i].w.from)));
          const d = (n - (drivers.length - 1) / 2) * PinGeo.laneGap;
          if (vertical) { items[i].pts[k].x += d; items[i].pts[k + 1].x += d; } else { items[i].pts[k].y += d; items[i].pts[k + 1].y += d; }
        }
      }
    }
    const junctions = new Map();
    const trunks = new Map();
    for (const it of items) {
      if (it.pts.length !== 4) continue;
      const key = `${it.w.from.instance}.${it.w.from.pin}@${it.pts[1].x}`;
      if (!trunks.has(key)) trunks.set(key, []);
      trunks.get(key).push(it);
    }
    for (const group of trunks.values()) {
      if (group.length <= 1) continue;
      const ay = group[0].pts[0].y;
      const ys = group.map((g) => g.pts[2].y).concat([ay]);
      const lo = Math.min(...ys), hi = Math.max(...ys);
      for (const it of group) if (it.pts[2].y > lo + 0.5 && it.pts[2].y < hi - 0.5) { if (!junctions.has(it.w.id)) junctions.set(it.w.id, []); junctions.get(it.w.id).push(it.pts[2]); }
      if (ay > lo + 0.5 && ay < hi - 0.5) { const id = group[0].w.id; if (!junctions.has(id)) junctions.set(id, []); junctions.get(id).push(group[0].pts[1]); }
    }
    return items.map((it) => ({ wire: it.w, points: it.pts, width: it.width, junctions: junctions.get(it.w.id) || [] }));
  },
  wireAt(p, state, tolerance) {
    let best = null, bestD = Infinity;
    for (const r of PinGeo.routeAll(state, PinGeo.allPins(state, null))) {
      for (let i = 1; i < r.points.length; i++) {
        const d = PinGeo.segmentDistance(p, r.points[i - 1], r.points[i]);
        if (d < tolerance && d < bestD) { best = r.wire.id; bestD = d; }
      }
    }
    return best;
  },
  segmentDistance(p, a, b) {
    const dx = b.x - a.x, dy = b.y - a.y;
    const len2 = dx * dx + dy * dy;
    if (len2 <= 0) return Math.hypot(p.x - a.x, p.y - a.y);
    const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2));
    return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
  },
};

if (typeof module !== 'undefined') module.exports = { Metrics, StimChip, BlockLayout, SourceLayout, PinGeo };
