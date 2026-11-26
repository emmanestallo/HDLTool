'use strict';
/* global LogicLiteral, ExprEval, Fmt, PortInfoUtil, PathUtil, Host */
// HDL Tester data model. Port of TestModel.swift. Objects keep the exact JSON shape of .hdltest files.

const newUUID = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
  const r = (Math.random() * 16) | 0; return (c === 'x' ? r : (r & 3) | 8).toString(16);
})).toUpperCase();
const clone = (o) => JSON.parse(JSON.stringify(o));
const deepEqual = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// ---------------------------------------------------------------- Stimulus

const StimKinds = {
  all: ['constant', 'clock', 'sequence', 'bitstream', 'counter', 'random'],
  title: { constant: 'Constant', clock: 'Clock', sequence: 'Sequence', bitstream: 'Bit Stream', counter: 'Counter', random: 'Random' },
  icon: { constant: 'symbol-operator', clock: 'pulse', sequence: 'graph-line', bitstream: 'symbol-array', counter: 'symbol-numeric', random: 'symbol-event' },
  help: {
    constant: 'Holds one value for the whole test.',
    clock: 'A periodic clock with a set period and duty cycle.',
    sequence: 'A list of values, each applied after a delay.',
    bitstream: 'Shifts out a string of bits (or values), one every bit time.',
    counter: 'Starts at a value and adds a step every interval.',
    random: 'A new random value every interval.',
  },
};

const Stim = {
  defaults() {
    return {
      kind: 'constant', constant: '0',
      period: 10, duty: 50, startHigh: false, clockDelay: 0,
      seqInitial: '0', steps: [], absoluteTimes: false, seqRepeat: false,
      bits: '10110010', bitTime: 10, bitDelay: 0, bitIdle: '0', bitRepeat: false,
      countStart: '0', countStep: '1', countInterval: 10, countDelay: 0,
      randInterval: 10, randSeed: 1, randDelay: 0,
    };
  },
  // Fills missing keys (files may omit them).
  normalize(s) {
    const d = Stim.defaults();
    const out = Object.assign(d, s || {});
    out.steps = (out.steps || []).map((st) => ({ id: st.id || newUUID(), delay: st.delay ?? 0, value: st.value ?? '0' }));
    return out;
  },
  constant(v) { return Object.assign(Stim.defaults(), { constant: v }); },
  clock(period) { return Object.assign(Stim.defaults(), { kind: 'clock', period }); },
  reset(activeLow, length) {
    return Object.assign(Stim.defaults(), {
      kind: 'sequence', seqInitial: activeLow ? '0' : '1',
      steps: [{ id: newUUID(), delay: length, value: activeLow ? '1' : '0' }], constant: activeLow ? '1' : '0',
    });
  },
  guess(port, clockPeriod = 10) {
    const n = port.name.toLowerCase();
    if (port.dir === 'inout') return Stim.constant('z');
    const oneBit = !port.ranges.length && PortInfoUtil.baseWidth(port) === 1;
    if (oneBit) {
      if (n === 'clk' || n === 'clock' || n.startsWith('clk_') || n.endsWith('_clk') || (n.endsWith('clk') && n.length <= 6)) return Stim.clock(clockPeriod);
      if (n.includes('rst') || n.includes('reset')) {
        const low = n.endsWith('_n') || n.endsWith('rstn') || n.endsWith('resetn') || n.endsWith('_ni') || n.startsWith('n') ||
          n.endsWith('_b') || n.endsWith('_l') || n.endsWith('rstb') || n.endsWith('resetb');
        return Stim.reset(low, clockPeriod * 2);
      }
    }
    return Stim.constant('0');
  },
  summary(s) {
    switch (s.kind) {
      case 'constant': return s.constant || '?';
      case 'clock': return Fmt.num(s.period);
      case 'sequence': return s.steps.length <= 1 ? (s.steps.length ? `${s.seqInitial}→${s.steps[0].value}` : s.seqInitial) : `${s.steps.length} steps`;
      case 'bitstream': { const t = s.bits.replace(/ /g, ''); return t.length > 8 ? t.slice(0, 7) + '…' : t; }
      case 'counter': return `${s.countStart}+${s.countStep}`;
      default: return 'rand';
    }
  },
  sameSignal(a, b) {
    const strip = (s) => Object.assign({}, s, { steps: s.steps.map((x) => ({ delay: x.delay, value: x.value })) });
    return deepEqual(Stim.sorted(strip(a)), Stim.sorted(strip(b)));
  },
  sorted(o) { const r = {}; for (const k of Object.keys(o).sort()) r[k] = o[k]; return r; },
  streamTokens(s, width) {
    const t = s.bits.trim();
    if ((width ?? 1) === 1) {
      const compact = t.replace(/[ _,\n]/g, '');
      if ([...compact].every((c) => '01xzXZ'.includes(c))) return [...compact].map((c) => c.toLowerCase());
    }
    return t.split(/[ ,\n\t;]/).filter(Boolean);
  },
  relativeSteps(s) {
    if (!s.absoluteTimes) return s.steps;
    let t = 0;
    return [...s.steps].sort((a, b) => a.delay - b.delay).map((st) => {
      const d = Math.max(0, st.delay - t);
      t = Math.max(t, st.delay);
      return { id: st.id, delay: d, value: st.value };
    });
  },
};

// ---------------------------------------------------------------- Source presets

const SourcePresets = {
  all: ['clock', 'resetHigh', 'resetLow', 'sequence', 'bitstream', 'counter', 'random', 'constant'],
  title: { clock: 'Clock', resetHigh: 'Reset (active high)', resetLow: 'Reset (active low)', sequence: 'Sequence', bitstream: 'Bit Stream', counter: 'Counter', random: 'Random', constant: 'Constant' },
  shortTitle(p) { return p === 'resetHigh' ? 'Reset (high)' : p === 'resetLow' ? 'Reset (low)' : SourcePresets.title[p]; },
  baseName: { clock: 'clk', resetHigh: 'rst', resetLow: 'rst_n', sequence: 'seq', bitstream: 'stream', counter: 'count', random: 'rand', constant: 'const' },
  width(p) { return p === 'counter' || p === 'random' ? 8 : 1; },
  kind: { clock: 'clock', resetHigh: 'sequence', resetLow: 'sequence', sequence: 'sequence', bitstream: 'bitstream', counter: 'counter', random: 'random', constant: 'constant' },
  guess(port) {
    const g = Stim.guess(port);
    if (g.kind === 'clock') return 'clock';
    if (g.kind === 'sequence') return g.seqInitial === '0' ? 'resetLow' : 'resetHigh';
    return 'constant';
  },
  stimulus(p, period) {
    switch (p) {
      case 'clock': return Stim.clock(period);
      case 'resetHigh': return Stim.reset(false, period * 2);
      case 'resetLow': return Stim.reset(true, period * 2);
      case 'sequence': return Object.assign(Stim.defaults(), { kind: 'sequence', steps: [{ id: newUUID(), delay: period * 2, value: '1' }, { id: newUUID(), delay: period * 2, value: '0' }] });
      case 'bitstream': return Object.assign(Stim.defaults(), { kind: 'bitstream', bitTime: period });
      case 'counter': return Object.assign(Stim.defaults(), { kind: 'counter', countInterval: period });
      case 'random': return Object.assign(Stim.defaults(), { kind: 'random', randInterval: period });
      default: return Stim.constant('0');
    }
  },
};

// ---------------------------------------------------------------- Instances

const Inst = {
  sourcePort(width) {
    return { name: 'out', dir: 'output', ranges: width > 1 ? [{ msb: String(width - 1), lsb: '0' }] : [], isSigned: false, dataType: 'reg' };
  },
  makeSource(name, width, stimulus, x, y) {
    return { id: newUUID(), name, moduleName: '', filePath: '', x, y, ports: [Inst.sourcePort(width)], params: [], paramOverrides: {}, stimuli: { out: stimulus }, logged: [], kind: 'source' };
  },
  makeDUT(module, name, x, y) {
    return { id: newUUID(), name, moduleName: module.name, filePath: module.file, x, y, ports: clone(module.ports), params: clone(module.params), paramOverrides: {}, stimuli: {}, logged: [], kind: 'dut' };
  },
  normalize(o) {
    const i = Object.assign({ id: newUUID(), filePath: '', x: 100, y: 100, ports: [], params: [], paramOverrides: {}, stimuli: {}, logged: [], kind: 'dut' }, o);
    i.ports = i.ports.map((p) => Object.assign({ ranges: [], isSigned: false, dataType: '' }, p));
    for (const k of Object.keys(i.stimuli)) i.stimuli[k] = Stim.normalize(i.stimuli[k]);
    return i;
  },
  isSource(i) { return i.kind === 'source'; },
  inputs(i) { return i.ports.filter((p) => p.dir === 'input'); },
  outputs(i) { return i.ports.filter((p) => p.dir === 'output'); },
  inouts(i) { return i.ports.filter((p) => p.dir === 'inout'); },
  sourceWidth(i) { const r = Inst.resolve(i, i.ports[0] || Inst.sourcePort(1)); return r ? r.width : 1; },
  setSourceWidth(i, w) { i.ports = [Inst.sourcePort(Math.max(1, Math.min(w, 4096)))]; },
  stimulus(i, port) {
    if (i.stimuli[port]) return i.stimuli[port];
    const p = i.ports.find((q) => q.name === port);
    return p ? Stim.guess(p) : Stim.defaults();
  },
  paramValues(i) {
    const env = {};
    for (const p of i.params) {
      let text = p.value;
      const o = i.paramOverrides[p.name];
      if (!p.isLocal && o != null && o.trim()) text = o.trim();
      const v = ExprEval.eval(text, env);
      if (v != null) env[p.name] = v;
    }
    return env;
  },
  // { msb, lsb, width, hasRange } or null
  resolve(i, port, env) {
    env = env || Inst.paramValues(i);
    if (!port.ranges.length) {
      const w = PortInfoUtil.baseWidth(port);
      return { msb: w - 1, lsb: 0, width: w, hasRange: w > 1 };
    }
    let total = 1, first = null;
    for (const r of port.ranges) {
      const m = ExprEval.eval(r.msb, env), l = ExprEval.eval(r.lsb, env);
      if (m == null || l == null) return null;
      if (!first) first = [m, l];
      total *= Math.abs(m - l) + 1;
    }
    if (!(total > 0) || total > (1 << 20)) return null;
    if (port.ranges.length === 1) return { msb: first[0], lsb: first[1], width: total, hasRange: true };
    return { msb: total - 1, lsb: 0, width: total, hasRange: true };
  },
  rangeLabel(i, port, env) {
    const r = Inst.resolve(i, port, env);
    if (r) return r.hasRange ? `[${r.msb}:${r.lsb}]` : '';
    return port.ranges.map((x) => `[${x.msb}:${x.lsb}]`).join('');
  },
};

// ---------------------------------------------------------------- Test state

const pinEq = (a, b) => a.instance === b.instance && a.pin === b.pin;
const pinKey = (r) => r.instance + '|' + r.pin;

const TS = {
  make(name) { return { name, instances: [], wires: [], unit: 'ns', precision: 'ps', duration: 200, autoOpenVCD: true }; },
  normalize(o) {
    const s = Object.assign(TS.make('Test'), o || {});
    s.instances = (s.instances || []).map(Inst.normalize);
    s.wires = (s.wires || []).map((w) => Object.assign({ id: newUUID() }, w));
    if (s.outputDir == null) delete s.outputDir;
    TS.migratePinStimuli(s);
    return s;
  },
  instance(s, id) { return s.instances.find((i) => i.id === id) || null; },
  duts(s) { return s.instances.filter((i) => !Inst.isSource(i)); },
  sources(s) { return s.instances.filter(Inst.isSource); },
  wireTo(s, ref) { return s.wires.find((w) => pinEq(w.to, ref)) || null; },
  wiresFrom(s, ref) { return s.wires.filter((w) => pinEq(w.from, ref)); },
  describe(s, ref) {
    const inst = TS.instance(s, ref.instance);
    if (!inst) return '?';
    return Inst.isSource(inst) ? inst.name : `${inst.name}.${ref.pin}`;
  },
  driverPins(s) {
    return TS.sources(s).map((i) => ({ instance: i.id, pin: 'out' }))
      .concat(TS.duts(s).flatMap((d) => Inst.outputs(d).filter((p) => p.unsupported == null).map((p) => ({ instance: d.id, pin: p.name }))));
  },
  inputPins(s) {
    return TS.duts(s).flatMap((d) => Inst.inputs(d).filter((p) => p.unsupported == null).map((p) => ({ instance: d.id, pin: p.name })));
  },
  uniqueName(s, base, excluding) {
    const taken = new Set(s.instances.filter((i) => i.id !== excluding).map((i) => i.name));
    if (!taken.has(base)) return base;
    let n = 2;
    while (taken.has(`${base}_${n}`)) n++;
    return `${base}_${n}`;
  },
  uniqueInstanceName(s, module, excluding) {
    const taken = new Set(s.instances.filter((i) => i.id !== excluding).map((i) => i.name));
    const base = 'u_' + module;
    if (!taken.has(base)) return base;
    let n = 1;
    while (taken.has(`${base}_${n}`)) n++;
    return `${base}_${n}`;
  },
  typicalClockPeriod(s) {
    for (const i of TS.sources(s)) { const st = Inst.stimulus(i, 'out'); if (st.kind === 'clock') return st.period; }
    return 10;
  },
  matchingSource(s, preset, width) {
    if (!(preset === 'clock' || preset === 'resetLow' || preset === 'resetHigh')) return null;
    const want = SourcePresets.stimulus(preset, TS.typicalClockPeriod(s));
    return TS.sources(s).find((src) => {
      const have = Inst.stimulus(src, 'out');
      if (Inst.sourceWidth(src) !== width || have.kind !== want.kind) return false;
      if (preset === 'clock') return true;
      return have.seqInitial === want.seqInitial && (have.steps[0] || {}).value === (want.steps[0] || {}).value;
    }) || null;
  },
  migratePinStimuli(s) {
    if (!s.instances.some((i) => !Inst.isSource(i) && Object.keys(i.stimuli).length && i.ports.length)) return;
    const groups = [];
    for (const inst of s.instances) {
      if (Inst.isSource(inst) || !inst.ports.length) continue;
      const env = Inst.paramValues(inst);
      for (const p of Inst.inputs(inst)) {
        if (p.unsupported != null) continue;
        const ref = { instance: inst.id, pin: p.name };
        const st = inst.stimuli[p.name];
        if (TS.wireTo(s, ref) || !st) continue;
        const r = Inst.resolve(inst, p, env);
        const w = r ? r.width : 1;
        const g = groups.find((x) => x.name === p.name && x.width === w && Stim.sameSignal(x.stim, st));
        if (g) g.pins.push(ref); else groups.push({ name: p.name, stim: st, width: w, pins: [ref] });
      }
    }
    for (const i of s.instances) if (!Inst.isSource(i) && i.ports.length) i.stimuli = {};
    if (!groups.length) return;
    const columnX = 20, columnRight = 340;
    const duts = TS.duts(s);
    if (duts.length) {
      const minX = Math.min(...duts.map((d) => d.x));
      if (minX < columnRight) for (const d of duts) d.x += columnRight - minX;
      const minY = Math.min(...duts.map((d) => d.y));
      if (minY < 60) for (const d of duts) d.y += 60 - minY;
    }
    const srcs = TS.sources(s);
    let y = srcs.length ? Math.max(...srcs.map((x) => x.y + 70)) : 60;
    for (const g of groups) {
      const src = Inst.makeSource(TS.uniqueName(s, Fmt.isIdentifier(g.name) ? g.name : 'src'), g.width, g.stim, columnX, y);
      s.instances.push(src);
      for (const pin of g.pins) s.wires.push({ id: newUUID(), from: { instance: src.id, pin: 'out' }, to: pin });
      y += 70;
    }
  },
};

// ---------------------------------------------------------------- .hdltest file

const TestFileIO = {
  // Text → { test, sources, savedDir }
  decode(text) {
    const d = JSON.parse(text);
    if (!d || typeof d !== 'object' || !d.test) throw new Error('The file is not an HDL Tester test.');
    return { format: d.format || 'hdltester-test', version: d.version || 1, test: TS.normalize(d.test), sources: d.sources || [], savedDir: d.savedDir || null };
  },
  // Re-points paths that no longer exist for a test now in testDir.
  relocate(file, testDir) {
    const cache = new Map();
    const fix = (path) => {
      if (cache.has(path)) return cache.get(path);
      let result = path;
      if (path && !Host.fs.exists(path)) {
        const candidates = [];
        if (file.savedDir) candidates.push(PathUtil.normalize(PathUtil.join(testDir, Library.relativePath(path, file.savedDir))));
        candidates.push(PathUtil.join(testDir, PathUtil.basename(path)));
        const found = candidates.find((c) => Host.fs.exists(c));
        if (found) result = found;
      }
      cache.set(path, result);
      return result;
    };
    file.sources = file.sources.map(fix);
    for (const i of file.test.instances) if (!Inst.isSource(i)) i.filePath = fix(i.filePath);
  },
  // Pretty JSON with sorted keys (like the Mac app writes).
  encode(test, sources, savedDir) {
    const strip = (v) => {
      if (Array.isArray(v)) return v.map(strip);
      if (v && typeof v === 'object') {
        const out = {};
        for (const k of Object.keys(v).sort()) { if (v[k] !== null && v[k] !== undefined) out[k] = strip(v[k]); }
        return out;
      }
      return v;
    };
    return JSON.stringify(strip({ format: 'hdltester-test', version: 1, test, sources, savedDir }), null, 2) + '\n';
  },
};

// ---------------------------------------------------------------- Test document (undo, edits)

class TestDocument {
  constructor(state, filePath = null) {
    this.id = newUUID();
    this._state = state;
    this.filePath = filePath;
    this.isDirty = false;
    this.selection = null;       // { type: 'instance'|'pin'|'wire', id, pin }
    this.zoom = 1;
    this.scroll = { x: 0, y: 0 };
    this.dragging = null;        // { id, dx, dy }
    this.pendingWire = null;
    this.status = { kind: 'idle' };
    this.log = [];
    this.lastVCD = null;
    this.lastRunSeconds = null;
    this.undoStack = [];
    this.redoStack = [];
    this.lastEdit = 0;
    this.process = null;
    this.onChange = null;
  }
  get state() { return this._state; }
  get name() { return this._state.name; }

  // Commits a new state (a fresh object). Coalesces quick consecutive edits into one undo step unless `checkpoint`.
  setState(next, { checkpoint = false, silent = false } = {}) {
    const old = this._state;
    if (deepEqual(old, next)) { this._state = next; return; }
    this._state = next;
    if (!silent) {
      this.isDirty = true;
      const now = Date.now();
      if (checkpoint || now - this.lastEdit > 1200) {
        this.undoStack.push(old);
        if (this.undoStack.length > 200) this.undoStack.shift();
        this.redoStack = [];
      }
      this.lastEdit = checkpoint ? 0 : now;
    }
    if (this.onChange) this.onChange(this);
  }
  // A discrete edit with its own undo step. body mutates a copy.
  edit(body) { const s = clone(this._state); body(s); this.setState(s, { checkpoint: true }); }
  // Continuous edits (typing in a field) coalesce.
  editTyping(body) { const s = clone(this._state); body(s); this.setState(s); }
  silently(body) { const s = clone(this._state); body(s); this.setState(s, { silent: true }); }

  get canUndo() { return this.undoStack.length > 0; }
  get canRedo() { return this.redoStack.length > 0; }
  undo() {
    const prev = this.undoStack.pop();
    if (!prev) return;
    this.redoStack.push(this._state);
    this._state = prev;
    this.isDirty = true; this.lastEdit = 0;
    this.validateSelection();
    if (this.onChange) this.onChange(this);
  }
  redo() {
    const next = this.redoStack.pop();
    if (!next) return;
    this.undoStack.push(this._state);
    this._state = next;
    this.isDirty = true; this.lastEdit = 0;
    this.validateSelection();
    if (this.onChange) this.onChange(this);
  }
  validateSelection() {
    const sel = this.selection;
    if (!sel) return;
    if (sel.type === 'wire') { if (!this._state.wires.some((w) => w.id === sel.id)) this.selection = null; return; }
    const inst = TS.instance(this._state, sel.id);
    if (!inst) { this.selection = null; return; }
    if (sel.type === 'pin' && !inst.ports.some((p) => p.name === sel.pin)) this.selection = { type: 'instance', id: inst.id };
  }

  removeInstance(id) {
    this.edit((s) => { s.instances = s.instances.filter((i) => i.id !== id); s.wires = s.wires.filter((w) => w.from.instance !== id && w.to.instance !== id); });
    if (this.selection && this.selection.type !== 'wire' && this.selection.id === id) this.selection = null;
  }
  connect(from, to) {
    const w = { id: newUUID(), from, to };
    this.edit((s) => { s.wires = s.wires.filter((x) => !pinEq(x.to, to)); s.wires.push(w); });
    this.selection = { type: 'wire', id: w.id };
  }
  removeWire(id) {
    this.edit((s) => { s.wires = s.wires.filter((w) => w.id !== id); });
    if (this.selection && this.selection.type === 'wire' && this.selection.id === id) this.selection = null;
  }
  disconnect(input) {
    if (!TS.wireTo(this._state, input)) return;
    this.edit((s) => { s.wires = s.wires.filter((w) => !pinEq(w.to, input)); });
  }
  addSource(preset, input) {
    const st = this._state;
    const dut = TS.instance(st, input.instance);
    const port = dut && dut.ports.find((p) => p.name === input.pin);
    if (!port) return null;
    const r = Inst.resolve(dut, port);
    const width = r ? r.width : 1;
    const idx = Math.max(0, Inst.inputs(dut).findIndex((p) => p.name === port.name));
    const pinY = dut.y + (BlockLayout.rowY(idx) - BlockLayout.labelH);
    const snap = (v) => Math.round(v / 10) * 10;
    const base = ['constant', 'counter', 'random', 'bitstream', 'sequence'].includes(preset)
      ? (Fmt.isIdentifier(port.name) ? port.name : SourcePresets.baseName[preset]) : SourcePresets.baseName[preset];
    const src = Inst.makeSource(TS.uniqueName(st, base), ['clock', 'resetLow', 'resetHigh'].includes(preset) ? 1 : width,
      SourcePresets.stimulus(preset, TS.typicalClockPeriod(st)), snap(Math.max(10, dut.x - 300)), snap(Math.max(10, pinY - SourceLayout.pinY)));
    while (st.instances.some((i) => Inst.isSource(i) && Math.abs(i.x - src.x) < 60 && Math.abs(i.y - src.y) < 50)) src.y += 60;
    this.edit((s) => {
      s.instances.push(src);
      s.wires = s.wires.filter((w) => !pinEq(w.to, input));
      s.wires.push({ id: newUUID(), from: { instance: src.id, pin: 'out' }, to: input });
    });
    return src.id;
  }
  addSourcesForUnwiredInputs(id) {
    const dut = TS.instance(this._state, id);
    if (!dut || Inst.isSource(dut)) return 0;
    const s = clone(this._state);
    const env = Inst.paramValues(dut);
    const snap = (v) => Math.round(v / 10) * 10;
    let y = snap(Math.max(10, dut.y - 10));
    let count = 0;
    for (const p of Inst.inputs(dut)) {
      if (p.unsupported != null) continue;
      const ref = { instance: dut.id, pin: p.name };
      if (TS.wireTo(s, ref)) continue;
      const r = Inst.resolve(dut, p, env);
      const width = r ? r.width : 1;
      const preset = SourcePresets.guess(p);
      const existing = TS.matchingSource(s, preset, width);
      if (existing) s.wires.push({ id: newUUID(), from: { instance: existing.id, pin: 'out' }, to: ref });
      else {
        while (s.instances.some((i) => Inst.isSource(i) && Math.abs(i.x - (dut.x - 300)) < 60 && Math.abs(i.y - y) < 50)) y += 60;
        const base = preset === 'constant' ? (Fmt.isIdentifier(p.name) ? p.name : 'const') : SourcePresets.baseName[preset];
        const src = Inst.makeSource(TS.uniqueName(s, base), preset === 'constant' ? width : 1,
          SourcePresets.stimulus(preset, TS.typicalClockPeriod(s)), snap(Math.max(10, dut.x - 300)), y);
        s.instances.push(src);
        s.wires.push({ id: newUUID(), from: { instance: src.id, pin: 'out' }, to: ref });
        y += 70;
      }
      count++;
    }
    if (count > 0) this.setState(s, { checkpoint: true });
    return count;
  }
  duplicateInstance(id) {
    const inst = TS.instance(this._state, id);
    if (!inst) return;
    const copy = clone(inst);
    copy.id = newUUID();
    copy.name = Inst.isSource(inst) ? TS.uniqueName(this._state, inst.name) : TS.uniqueInstanceName(this._state, inst.moduleName);
    copy.x += 40; copy.y += 40;
    this.edit((s) => s.instances.push(copy));
    this.selection = { type: 'instance', id: copy.id };
  }
  appendLog(kind, text) {
    for (const line of String(text).split('\n')) {
      let k = kind;
      const l = line.toLowerCase();
      if (kind === 'stdout') {
        if (l.includes('error') || l.includes('fatal') || l.includes('syntax')) k = 'error';
        else if (l.includes('warning')) k = 'warning';
      }
      if (!line && kind === 'stdout') continue;
      this.log.push({ kind: k, text: line });
    }
    if (this.log.length > 20000) this.log.splice(0, this.log.length - 20000);
  }
}

if (typeof module !== 'undefined') module.exports = { newUUID, clone, deepEqual, StimKinds, Stim, SourcePresets, Inst, TS, TestFileIO, TestDocument, pinEq, pinKey };
