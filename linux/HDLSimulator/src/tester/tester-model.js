'use strict';
/* global Host, PathUtil, Paths, Prefs, Dialogs, showToast, copyText, store, Library, TS, Inst, Stim, SourcePresets, TestDocument, TestFileIO,
   TBGenerator, Fmt, Tools, execLines, shellQuote, Viewer, Shell, newUUID, clone, deepEqual, pinEq, MOD, BlockLayout, Coder */
// HDL Tester: tests, the DUT library, running and saving. Port of TesterKit AppModel.swift, Runner.swift, Hierarchy.swift.

const Tester = {
  library: new Library(),
  tests: [],
  activeID: null,
  sidebarMode: 'duts',
  showInspector: true,
  showPanel: true,
  panelTab: 'testbench',
  stimulusClipboard: null,
  recentTests: store.get('recentTests', []),
  sessionEnabled: true,
  genCache: new Map(),
  libraryVersion: 0,
  render: () => {},

  get active() { return this.tests.find((t) => t.id === this.activeID) || null; },
  get openResultsInViewer() { return Prefs.get('openResultsInViewer'); },

  start() {
    this.registerWithShell();
    if (this.sessionEnabled) this.restoreSession();
    if (!this.tests.length && this.sessionEnabled) this.newTest();
    setInterval(() => this.tick(), 1000);
  },
  watch(doc) { doc.onChange = () => this.render('all'); return doc; },

  generator(doc) { return new TBGenerator(doc.state, this.library.modules); },
  generated(doc) {
    const c = this.genCache.get(doc.id);
    if (c && c.state === doc.state && c.v === this.libraryVersion) return c.out;
    const out = this.generator(doc).generate();
    this.genCache.set(doc.id, { state: doc.state, v: this.libraryVersion, out });
    return out;
  },

  // ---------------------------------------------------------------- Tests

  newTest() {
    let n = this.tests.length + 1;
    const names = new Set(this.tests.map((t) => t.name));
    while (names.has(`Test ${n}`)) n++;
    const doc = this.watch(new TestDocument(TS.make(`Test ${n}`)));
    this.tests.push(doc);
    this.activeID = doc.id;
    this.render('all');
  },
  close(doc) {
    if (doc.isDirty && doc.state.instances.length) {
      this.activeID = doc.id;
      this.render('all');
      const r = Dialogs.saveChanges(doc.name);
      if (r === 'cancel') return false;
      if (r === 'save' && !this.save(doc, false)) return false;
    }
    this.stop(doc);
    const i = this.tests.indexOf(doc);
    if (i < 0) return true;
    this.tests.splice(i, 1);
    this.genCache.delete(doc.id);
    if (this.activeID === doc.id) this.activeID = this.tests.length ? this.tests[Math.min(i, this.tests.length - 1)].id : null;
    this.render('all');
    return true;
  },
  closeActive() { if (this.active) this.close(this.active); },
  closeAll() { for (const t of [...this.tests]) if (!this.close(t)) return false; return true; },

  // ---------------------------------------------------------------- Opening

  open(paths) {
    const verilog = [];
    for (const p of paths) { if (Paths.ext(p) === 'hdltest') this.openTest(p); else verilog.push(p); }
    if (verilog.length) {
      const added = this.library.add(verilog);
      this.libraryChanged(added);
      if (added.length) this.sidebarMode = 'duts';
      this.render('all');
    }
  },
  openTest(p) {
    const path = PathUtil.resolve(p);
    const existing = this.tests.find((t) => t.filePath && Paths.same(t.filePath, path));
    if (existing) { this.activeID = existing.id; this.render('all'); return; }
    let file;
    try {
      const text = Host.fs.readText(path);
      if (text == null) throw new Error('The file could not be read.');
      file = TestFileIO.decode(text);
    } catch (e) { Dialogs.alert(`Could not open “${PathUtil.basename(path)}”`, e.message || String(e)); return; }
    TestFileIO.relocate(file, PathUtil.dirname(path));
    const missing = file.sources.filter((s) => !Host.fs.exists(s));
    const have = new Set(this.library.files.map((f) => f.path));
    const toAdd = file.sources.filter((s) => !have.has(PathUtil.resolve(s)) && Host.fs.exists(s));
    this.libraryChanged(this.library.add(toAdd));
    const doc = this.watch(new TestDocument(file.test, path));
    if (this.tests.length === 1) {
      const only = this.tests[0];
      if (!only.filePath && !only.state.instances.length && !only.isDirty) this.tests = [];
    }
    this.tests.push(doc);
    this.activeID = doc.id;
    this.refresh(doc);
    this.addRecent(path);
    if (missing.length) doc.appendLog('warning', 'Missing source files: ' + missing.join(', '));
    this.render('all');
  },
  exampleDir() { const d = Host.launch.examples; return Host.fs.exists(PathUtil.join(d, 'demo.hdltest')) ? d : null; },
  openExample(file = 'demo.hdltest') {
    const dest = Coder.installExamples();
    if (!dest) return;
    this.open([PathUtil.join(dest, file)]);
  },
  showOpenPanel() {
    const paths = Dialogs.openFiles({ title: 'Choose Verilog files (.v, .sv) or a saved test (.hdltest)', properties: ['openFile', 'multiSelections'],
      filters: [{ name: 'Verilog and tests', extensions: [...Library.extensions, 'hdltest'] }, { name: 'All files', extensions: ['*'] }] });
    if (paths.length) this.open(paths);
  },
  showOpenFolderPanel() {
    const paths = Dialogs.openFiles({ title: 'Choose a folder of Verilog files', properties: ['openDirectory'] });
    if (paths.length) this.open(paths);
  },

  // ---------------------------------------------------------------- Saving

  sources(doc) {
    const out = [];
    for (const inst of TS.duts(doc.state)) if (!out.includes(inst.filePath)) out.push(inst.filePath);
    for (const f of this.generated(doc).sourceFiles) if (!out.includes(f)) out.push(f);
    return out;
  },
  save(doc, saveAs) {
    let path = doc.filePath;
    if (saveAs || !path) {
      const first = TS.duts(doc.state)[0];
      const dir = first ? PathUtil.dirname(first.filePath) : Host.launch.documents;
      const r = Dialogs.saveFile({ title: 'Save Test', defaultPath: PathUtil.join(dir, doc.name + '.hdltest'), filters: [{ name: 'HDL Tester test', extensions: ['hdltest'] }] });
      if (!r) return false;
      path = r;
    }
    const text = TestFileIO.encode(doc.state, this.sources(doc), PathUtil.dirname(path));
    const err = Host.fs.writeText(path, text);
    if (err) { Dialogs.alert(`Could not save “${PathUtil.basename(path)}”`, err); return false; }
    doc.filePath = PathUtil.resolve(path);
    doc.isDirty = false;
    this.addRecent(doc.filePath);
    this.render('all');
    return true;
  },
  addRecent(p) { this.recentTests = [p, ...this.recentTests.filter((x) => x !== p)].slice(0, 12); store.set('recentTests', this.recentTests); },
  clearRecent() { this.recentTests = []; store.set('recentTests', []); this.render('all'); },

  // ---------------------------------------------------------------- DUTs

  place(module, doc, point = null) {
    let pos;
    if (point) pos = { x: Math.max(140, point.x - 80), y: Math.max(40, point.y - 20) };
    else {
      const ys = doc.state.instances.map((i) => i.y + 28 + 22 * Math.max(Inst.inputs(i).length, Inst.outputs(i).length + Inst.inouts(i).length));
      pos = { x: 330, y: (ys.length ? Math.max(...ys) : 20) + 70 };
    }
    const snap = (v) => Math.round(v / 10) * 10;
    const inst = Inst.makeDUT(module, TS.uniqueInstanceName(doc.state, module.name), snap(pos.x), snap(pos.y));
    doc.edit((s) => s.instances.push(inst));
    doc.selection = { type: 'instance', id: inst.id };
    this.activeID = doc.id;
    this.render('all');
  },
  placeSource(preset, doc, point = null) {
    const snap = (v) => Math.round(v / 10) * 10;
    let pos;
    if (point) pos = { x: Math.max(10, point.x - 60), y: Math.max(10, point.y - 20) };
    else { const ys = TS.sources(doc.state).map((s) => s.y + 54); pos = { x: 30, y: (ys.length ? Math.max(...ys) : 50) + 20 }; }
    const inst = Inst.makeSource(TS.uniqueName(doc.state, SourcePresets.baseName[preset]), SourcePresets.width(preset),
      SourcePresets.stimulus(preset, TS.typicalClockPeriod(doc.state)), snap(pos.x), snap(pos.y));
    doc.edit((s) => s.instances.push(inst));
    doc.selection = { type: 'instance', id: inst.id };
    this.activeID = doc.id;
    this.render('all');
  },
  placeInActive(module) { if (!this.active) this.newTest(); if (this.active) this.place(module, this.active); },
  libraryChanged(files) {
    if (!files.length) return;
    this.libraryVersion++;
    for (const doc of this.tests) this.refresh(doc);
    this.render('all');
  },
  refresh(doc) {
    let changed = false;
    const s = clone(doc.state);
    for (const inst of s.instances) {
      if (Inst.isSource(inst)) continue;
      const m = this.library.module(inst.moduleName, inst.filePath);
      if (!m || !(Library.samePath(m.file, inst.filePath) || !Host.fs.exists(inst.filePath))) continue;
      if (!deepEqual(m.ports, inst.ports) || !deepEqual(m.params, inst.params) || !Library.samePath(m.file, inst.filePath)) {
        inst.ports = clone(m.ports);
        inst.params = clone(m.params);
        inst.filePath = m.file;
        const inputs = new Set(m.ports.filter((p) => p.dir === 'input').map((p) => p.name));
        s.wires = s.wires.filter((w) => !(w.to.instance === inst.id && !inputs.has(w.to.pin)));
        changed = true;
      }
    }
    if (changed) {
      TS.migratePinStimuli(s);
      doc.setState(s, { silent: true });
      doc.validateSelection();
    }
  },
  reloadChangedFiles() { const c = this.library.checkForChanges(true); if (c.length) this.libraryChanged(c); },

  // ---------------------------------------------------------------- Running

  outputDir(doc) {
    if (doc.state.outputDir) return doc.state.outputDir;
    const name = Fmt.identifier(doc.state.name);
    if (doc.filePath) return PathUtil.join(PathUtil.dirname(doc.filePath), name + '_sim');
    return PathUtil.join(Host.launch.documents, 'HDL Simulator', name);
  },
  export(doc) {
    const gen = this.generator(doc).generate();
    const dir = this.outputDir(doc);
    const p = PathUtil.join(dir, gen.topName + '.v');
    const err = Host.fs.writeText(p, gen.source);
    if (err) { doc.appendLog('error', `Could not write the testbench: ${err}`); this.render('panel'); return null; }
    return p;
  },
  runActive() { if (this.active) this.run(this.active); },
  async runAll() {
    for (const doc of [...this.tests]) {
      if (!TS.duts(doc.state).length) continue;
      this.activeID = doc.id;
      this.render('all');
      await this.run(doc);
    }
  },
  isRunning(doc) { return doc && (doc.status.kind === 'compiling' || doc.status.kind === 'simulating'); },
  stop(doc) {
    if (!this.isRunning(doc)) return;
    doc.status = { kind: 'stopped' };
    if (doc.process != null) Host.proc.kill(doc.process);
    doc.appendLog('warning', 'Stopped.');
    this.render('all');
  },
  async exec(doc, exe, args, cwd) {
    const r = execLines(exe, args, cwd, (l) => { doc.appendLog('stdout', l); this.render('panel'); });
    doc.process = r.id;
    const code = await r.promise;
    doc.process = null;
    return code;
  },
  async run(doc) {
    if (this.isRunning(doc)) return false;
    const started = Date.now();
    doc.log = [];
    doc.lastVCD = null;
    doc.lastRunSeconds = null;
    doc.status = { kind: 'compiling' };
    this.panelTab = 'output';
    this.showPanel = true;
    this.render('all');
    const fail = (why) => { doc.status = { kind: 'failed', why }; this.render('all'); return false; };
    if (!Tools.checked) Tools.detect();
    if (!Tools.iverilog || !Tools.vvp) {
      doc.appendLog('error', 'Icarus Verilog was not found. ' + Tools.installHint());
      doc.appendLog('info', `Or set its location in Settings (${MOD}+,).`);
      return fail('Icarus Verilog not found');
    }
    const gen = this.generator(doc).generate();
    const errors = gen.problems.filter((p) => p.severity === 'error');
    for (const p of gen.problems) doc.appendLog(p.severity === 'error' ? 'error' : 'warning', (p.severity === 'error' ? 'error: ' : 'warning: ') + p.message);
    if (errors.length) { doc.appendLog('error', 'Fix the problems above and run again.'); return fail(`${errors.length} problem${errors.length === 1 ? '' : 's'}`); }
    const dir = this.outputDir(doc);
    const tb = PathUtil.join(dir, gen.topName + '.v');
    const sim = PathUtil.join(dir, gen.topName + '.vvp');
    const vcd = PathUtil.join(dir, gen.vcdName);
    const err = Host.fs.writeText(tb, gen.source);
    if (err) { doc.appendLog('error', `Could not write ${tb}: ${err}`); return fail('Could not write testbench'); }
    doc.appendLog('info', `Testbench written to ${tb}`);
    const args = ['-g2012', '-o', sim, '-s', gen.topName];
    const dirs = [];
    for (const f of [...gen.sourceFiles, ...this.library.files.map((x) => x.path)]) { const d = PathUtil.dirname(f); if (!dirs.includes(d)) dirs.push(d); }
    for (const d of dirs) args.push('-I', d);
    for (const d of dirs) args.push('-y', d);
    args.push('-Y', '.v', '-Y', '.sv', tb, ...gen.sourceFiles);
    doc.appendLog('command', '$ iverilog ' + args.map(shellQuote).join(' '));
    this.render('panel');
    const compile = await this.exec(doc, Tools.iverilog, args, dir);
    if (doc.status.kind === 'stopped') return false;
    if (compile !== 0) { doc.appendLog('error', `Compile failed (iverilog exited with ${compile}).`); return fail('Compile failed'); }
    Host.fs.remove(vcd);
    doc.status = { kind: 'simulating' };
    doc.appendLog('command', '$ vvp -n ' + shellQuote(PathUtil.basename(sim)));
    this.render('all');
    const simStatus = await this.exec(doc, Tools.vvp, ['-n', sim], dir);
    if (doc.status.kind === 'stopped') return false;
    doc.lastRunSeconds = (Date.now() - started) / 1000;
    if (simStatus !== 0) { doc.appendLog('error', `Simulation failed (vvp exited with ${simStatus}).`); return fail('Simulation failed'); }
    if (Host.fs.exists(vcd)) {
      doc.lastVCD = vcd;
      doc.appendLog('success', `✓ Waveform saved to ${vcd}`);
      if (doc.state.autoOpenVCD && this.openResultsInViewer && this.openWaveforms !== false) Viewer.open(vcd);
    } else doc.appendLog('warning', 'The simulation finished but no waveform file was written.');
    doc.status = { kind: 'passed' };
    this.render('all');
    return true;
  },

  // ---------------------------------------------------------------- Shell: descend into DUTs, testbench from the Coder

  registerWithShell() {
    Shell.showTest = (id, inst) => {
      const doc = this.tests.find((t) => t.id === id);
      if (!doc) return false;
      this.reloadChangedFiles();
      this.activeID = id;
      if (inst && TS.instance(doc.state, inst)) doc.selection = { type: 'instance', id: inst };
      this.render('all');
      return true;
    };
    Shell.testbench = (path, module) => this.testbench(path, module);
    Shell.generateTestbench = (path, module) => this.generateTestbench(path, module);
    Shell.openInTester = (paths) => this.open(paths);
  },
  testbench(path, module) {
    const ordered = (this.active ? [this.active] : []).concat(this.tests.filter((t) => t.id !== this.activeID));
    for (const doc of ordered) {
      const inst = TS.duts(doc.state).find((d) => Library.samePath(d.filePath, path) && (module == null || d.moduleName === module));
      if (inst) return { place: { kind: 'test', id: doc.id, instance: inst.id }, label: doc.name, child: path };
    }
    return null;
  },
  descendTarget(doc) {
    const sel = doc.selection;
    if (sel && sel.type !== 'wire') { const inst = TS.instance(doc.state, sel.id); if (inst) return Inst.isSource(inst) ? null : inst; }
    const duts = TS.duts(doc.state);
    return duts.length === 1 ? duts[0] : null;
  },
  descend(inst, doc) {
    if (Inst.isSource(inst)) return;
    const path = PathUtil.resolve(inst.filePath);
    if (!Host.fs.exists(path)) { doc.appendLog('error', `Cannot descend into ${inst.name}: ${path} is missing`); this.render('panel'); return; }
    doc.selection = { type: 'instance', id: inst.id };
    const m = this.library.module(inst.moduleName, inst.filePath);
    const frame = { place: { kind: 'test', id: doc.id, instance: inst.id }, label: doc.name, child: path };
    Shell.descend(frame, path, m ? m.line : null, inst.moduleName);
  },
  descendSelected() {
    const doc = this.active;
    const inst = doc && this.descendTarget(doc);
    if (inst) this.descend(inst, doc);
  },
  openInCoder(p, module = null, line = null) {
    const path = PathUtil.resolve(p);
    if (this.active) {
      Shell.descend({ place: { kind: 'test', id: this.active.id, instance: null }, label: this.active.name, child: path }, path, line, module);
    } else {
      Shell.show('coder');
      if (Shell.openInCoder) Shell.openInCoder(path, line, module);
    }
  },
  generateTestbench(path, module) {
    this.libraryChanged(this.library.add([path]));
    this.reloadChangedFiles();
    this.sidebarMode = this.sidebarMode || 'duts';
    const frame = this.testbench(path, module);
    if (frame) { Shell.go(frame); return; }
    const info = this.library.module(module, path);
    if (!info) {
      Shell.show('tester');
      if (this.active) this.active.appendLog('error', `Module ${module} not found in ${path} — check it for syntax errors`);
      this.panelTab = 'output';
      this.showPanel = true;
      this.render('all');
      return;
    }
    const a = this.active;
    if (!(a && !a.state.instances.length && !a.filePath)) this.newTest();
    const doc = this.active;
    if (!doc) return;
    const names = new Set(this.tests.filter((t) => t.id !== doc.id).map((t) => t.name));
    let name = module, n = 2;
    while (names.has(name)) { name = `${module}_${n}`; n++; }
    doc.silently((s) => { s.name = name; });
    this.place(info, doc);
    const sel = doc.selection;
    if (sel && sel.id) { doc.addSourcesForUnwiredInputs(sel.id); doc.selection = { type: 'instance', id: sel.id }; }
    this.panelTab = 'testbench';
    Shell.show('tester');
    this.render('all');
  },

  // ---------------------------------------------------------------- Edit actions

  undo() { if (this.active) this.active.undo(); },
  redo() { if (this.active) this.active.redo(); },
  deleteSelection() {
    const doc = this.active;
    const sel = doc && doc.selection;
    if (!sel) return;
    if (sel.type === 'wire') doc.removeWire(sel.id);
    else if (sel.type === 'pin') {
      const inst = TS.instance(doc.state, sel.id);
      if (inst && Inst.isSource(inst)) doc.removeInstance(inst.id);
      else if (inst) {
        const ref = { instance: sel.id, pin: sel.pin };
        if (TS.wireTo(doc.state, ref)) doc.disconnect(ref);
        else if (TS.wiresFrom(doc.state, ref).length) doc.edit((s) => { s.wires = s.wires.filter((w) => !pinEq(w.from, ref)); });
      }
    } else doc.removeInstance(sel.id);
    this.render('all');
  },
  duplicate() { const doc = this.active; const sel = doc && doc.selection; if (sel && sel.type === 'instance') { doc.duplicateInstance(sel.id); this.render('all'); } },
  selectedSource() {
    const doc = this.active;
    const sel = doc && doc.selection;
    if (!sel || sel.type === 'wire') return null;
    const inst = TS.instance(doc.state, sel.id);
    return inst && Inst.isSource(inst) ? inst : null;
  },
  copyStimulus() { const s = this.selectedSource(); if (s) { this.stimulusClipboard = clone(Inst.stimulus(s, 'out')); showToast('Stimulus copied'); this.render('inspector'); } },
  pasteStimulus() {
    const s = this.selectedSource();
    if (!s || !this.stimulusClipboard) return;
    const c = clone(this.stimulusClipboard);
    this.active.edit((st) => { const i = st.instances.find((x) => x.id === s.id); if (i) i.stimuli.out = c; });
  },
  zoom(factor) {
    const doc = this.active;
    if (!doc) return;
    doc.zoom = factor === 0 ? 1 : Math.min(2, Math.max(0.4, doc.zoom * factor));
    this.render('canvas');
  },
  toggleSidebar() { this.sidebarMode = this.sidebarMode ? null : 'duts'; this.render('all'); },

  // ---------------------------------------------------------------- Timer & session

  tick() {
    const changed = this.library.checkForChanges();
    if (changed.length) this.libraryChanged(changed);
    if (this.sessionEnabled) this.saveSession();
  },
  sessionPath() { return PathUtil.join(Host.launch.userData, 'tester-session.json'); },
  saveSession() {
    const s = { sources: this.library.files.map((f) => f.path), tests: this.tests.map((t) => ({ state: t.state, path: t.filePath, dirty: t.isDirty })), active: this.tests.findIndex((t) => t.id === this.activeID) };
    const data = JSON.stringify(s);
    if (data === this.lastSession) return;
    this.lastSession = data;
    Host.fs.writeText(this.sessionPath(), data);
  },
  restoreSession() {
    const raw = Host.fs.readText(this.sessionPath());
    if (!raw) return;
    let s;
    try { s = JSON.parse(raw); } catch { return; }
    this.lastSession = raw;
    this.library.add((s.sources || []).filter((p) => Host.fs.exists(p)));
    this.libraryVersion++;
    for (const t of s.tests || []) {
      const doc = this.watch(new TestDocument(TS.normalize(t.state), t.path || null));
      doc.isDirty = !!t.dirty;
      this.tests.push(doc);
      this.refresh(doc);
    }
    this.activeID = (this.tests[s.active] || this.tests[0] || {}).id || null;
  },
};

if (typeof module !== 'undefined') module.exports = { Tester };
