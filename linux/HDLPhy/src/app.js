'use strict';
/* global Host, PathUtil, Paths, Prefs, store, IS_MAC, MOD, REVEAL_LABEL, h, icon, Menus, showToast, modal, splitter, Fmt,
   currentTheme, THEMES, SchematicView, LayoutView */
// HDLPhy: Verilog -> SKY130 gates (yosys) -> placed and routed layout (OpenROAD) -> GDS (KLayout).
// A project is a folder: its settings live in hdlphy.json, results in hdlphy_run/<top>/.

const STAGES = [
  { id: 'synth', title: 'Synthesis', tool: 'yosys', icon: 'symbol-structure', desc: 'RTL to SKY130 standard cells' },
  { id: 'floorplan', title: 'Floorplan', tool: 'OpenROAD', icon: 'layout', desc: 'Die, rows, tracks, taps, power grid' },
  { id: 'place', title: 'Placement', tool: 'OpenROAD', icon: 'symbol-namespace', desc: 'Global and detailed placement, I/O pins' },
  { id: 'cts', title: 'Clock Tree', tool: 'OpenROAD', icon: 'git-merge', desc: 'Clock buffering, timing repair' },
  { id: 'route', title: 'Routing', tool: 'OpenROAD', icon: 'type-hierarchy-sub', desc: 'Global and detailed routing, fill' },
  { id: 'gds', title: 'GDS', tool: 'KLayout', icon: 'file-binary', desc: 'Stream out with the cell layouts' },
];
const BUS_ORDERS = [['free', 'Free (shortest wires)'], ['ascending', 'In order, bit 0 at bottom / left'], ['descending', 'In order, bit 0 at top / right']];
const PIN_SIDES = [['any', 'Any edge (automatic)'], ['left', 'Left'], ['right', 'Right'], ['top', 'Top'], ['bottom', 'Bottom']];
const CORNERS = [['tt_025C_1v80', 'Typical (tt, 25 °C, 1.80 V)'], ['ss_100C_1v60', 'Slow (ss, 100 °C, 1.60 V)'], ['ff_n40C_1v95', 'Fast (ff, −40 °C, 1.95 V)']];

const App = {
  project: null,       // { dir, files: [paths], cfg: {...} }
  modules: [],         // [{ name, file, ports: [{ name, dir, width }] }]
  running: false,
  stageState: {},      // id -> { status: 'idle'|'running'|'done'|'failed'|'skipped', seconds }
  metrics: {},
  tools: null,
  output: [],
  tab: 'schematic',
  sidebarView: 'design',
  panelTab: 'output',
  panelOpen: true,

  // ---------------------------------------------------------------- start-up

  start() {
    const L = Host.launch;
    document.body.classList.add(IS_MAC ? 'mac' : 'win');
    if (Host.platform === 'linux') document.body.classList.add('linux');
    if (L.theme && THEMES[L.theme]) Prefs.set('themeID', L.theme);
    this.applyTheme();
    this.build();
    Host.flow.onOutput((lines) => this.onFlowLines(lines));
    Host.flow.onExit((r) => this.onFlowExit(r));
    Host.onOpenPaths((paths) => this.openPaths(paths));
    Host.onCloseRequested(() => this.requestClose());
    this.checkTools();
    if (L.paths.length) this.openPaths(L.paths);
    else if (!L.dev && Prefs.get('restoreProject')) { const last = store.get('lastProject'); if (last && Host.fs.exists(last)) this.openPaths([last]); }
    if (L.tab) this.showTab(L.tab);
    this.render();
    document.addEventListener('keydown', (e) => this.onKey(e));
  },

  applyTheme() {
    const t = currentTheme();
    const root = document.documentElement.style;
    for (const [k, v] of Object.entries(t)) if (typeof v === 'string') root.setProperty('--' + k, v);
    root.setProperty('--layoutBG', t.dark ? '#0B0B0D' : '#FCFCFC');
    root.setProperty('--cellOutline', t.dark ? 'rgba(255,255,255,0.28)' : 'rgba(0,0,0,0.3)');
    root.colorScheme = t.dark ? 'dark' : 'light';
    document.body.classList.toggle('light', !t.dark);
    Host.setTheme({ dark: t.dark, editor: t.editor, titleBar: t.titleBar, titleFG: t.titleFG });
    if (this.layout) this.layout.draw();
  },

  async checkTools() {
    this.tools = await Host.flow.check();
    this.renderStatus();
    if (this.sidebarView === 'design') this.renderSidebar();
  },

  // ---------------------------------------------------------------- layout of the window

  build() {
    const root = document.getElementById('app');
    this.tabBtns = {
      schematic: h('button', { class: 'app-tab', onclick: () => this.showTab('schematic'), title: 'Schematic after synthesis' }, icon('circuit-board'), 'Schematic'),
      layout: h('button', { class: 'app-tab', onclick: () => this.showTab('layout'), title: 'Layout after place and route' }, icon('layers'), 'Layout'),
    };
    this.runBtn = h('button', { class: 'run-button', onclick: () => (this.running ? this.stop() : this.run('synth', 'gds')) });
    this.titleEl = h('span', null, 'HDLPhy');
    const titlebar = h('div', { class: 'titlebar' },
      h('span', { class: 'codicon codicon-chip app-logo' }),
      h('div', { class: 'tab-switcher' }, this.tabBtns.schematic, this.tabBtns.layout),
      h('div', { class: 'tb-spacer' }),
      h('div', { class: 'command-center', onclick: () => this.openFolderDialog(), title: 'Open a folder of Verilog files' }, icon('folder-opened'), this.titleEl),
      h('div', { class: 'tb-spacer' }),
      this.runBtn,
      h('button', { class: 'tb-btn', title: 'Run one stage…', onclick: (e) => this.stageMenu(e) }, icon('debug-step-over')),
      h('div', { class: 'tb-sep' }),
      h('button', { class: 'tb-btn', title: 'Toggle side bar', onclick: () => { this.sidebarEl.classList.toggle('hidden'); this.sideSplit.classList.toggle('hidden'); } }, icon('layout-sidebar-left')),
      h('button', { class: 'tb-btn', title: 'Toggle panel', onclick: () => this.togglePanel() }, icon('layout-panel')),
      h('button', { class: 'tb-btn', title: 'Menu', onclick: (e) => this.appMenu(e) }, icon('menu')),
      h('div', { class: 'tb-overlay-space' }));
    titlebar.addEventListener('dblclick', (e) => { if (e.target === titlebar || e.target.classList.contains('tb-spacer')) Host.toggleMaximize(); });

    this.abItems = {};
    const ab = (id, ic, title) => (this.abItems[id] = h('div', { class: 'ab-item', title, onclick: () => this.showSidebar(id) }, icon(ic)));
    const activity = h('div', { class: 'activitybar' }, ab('design', 'files', 'Design'), ab('flow', 'run-all', 'Flow'), ab('reports', 'graph', 'Reports'),
      h('div', { class: 'ab-spacer' }), h('div', { class: 'ab-item', title: 'Settings', onclick: () => this.openSettings() }, icon('settings-gear')));

    this.sidebarEl = h('div', { class: 'sidebar', style: `width:${store.get('sidebarWidth', 300)}px` });
    this.sideSplit = splitter('v', () => this.sidebarEl.getBoundingClientRect().width, (w) => {
      w = Math.max(220, Math.min(560, w)); this.sidebarEl.style.width = w + 'px'; store.set('sidebarWidth', w);
    });

    this.schemRoot = h('div', { class: 'view-root' });
    this.layoutRoot = h('div', { class: 'view-root hidden' });
    this.panelEl = h('div', { class: 'panel', style: `height:${store.get('panelHeight', 200)}px` });
    this.panelSplit = splitter('h', () => this.panelEl.getBoundingClientRect().height, (v) => {
      v = Math.max(80, Math.min(window.innerHeight - 200, v)); this.panelEl.style.height = v + 'px'; store.set('panelHeight', v);
    }, true);
    const editor = h('div', { class: 'editor-col' }, this.schemRoot, this.layoutRoot, this.panelSplit, this.panelEl);
    this.statusEl = h('div', { class: 'statusbar' });
    root.append(titlebar, h('div', { class: 'main' }, activity, this.sidebarEl, this.sideSplit, editor), this.statusEl);

    this.schematic = new SchematicView(this.schemRoot, this);
    this.layout = new LayoutView(this.layoutRoot, this);
    this.showSidebar(store.get('sidebarView', 'design'));
    this.showTab(store.get('tab', 'schematic'));
    this.renderPanel();

    // drop a folder or Verilog files on the window
    root.addEventListener('dragover', (e) => { e.preventDefault(); });
    root.addEventListener('drop', (e) => {
      e.preventDefault();
      const paths = [...e.dataTransfer.files].map((f) => Host.pathForFile(f)).filter(Boolean);
      if (paths.length) this.openPaths(paths);
    });
  },

  showTab(t) {
    if (t !== 'schematic' && t !== 'layout') return;
    this.tab = t;
    store.set('tab', t);
    this.tabBtns.schematic.classList.toggle('on', t === 'schematic');
    this.tabBtns.layout.classList.toggle('on', t === 'layout');
    this.schemRoot.classList.toggle('hidden', t !== 'schematic');
    this.layoutRoot.classList.toggle('hidden', t !== 'layout');
    if (t === 'schematic') this.schematic.load(this.schematic.module);
    else { this.layout.resize(); this.layout.load(); }
  },

  showSidebar(v) {
    this.sidebarView = v;
    store.set('sidebarView', v);
    for (const [k, el] of Object.entries(this.abItems)) el.classList.toggle('active', k === v);
    this.sidebarEl.classList.remove('hidden');
    this.sideSplit.classList.remove('hidden');
    this.renderSidebar();
  },

  togglePanel() {
    this.panelOpen = !this.panelOpen;
    this.panelEl.classList.toggle('hidden', !this.panelOpen);
    this.panelSplit.classList.toggle('hidden', !this.panelOpen);
  },

  render() {
    this.titleEl.textContent = this.project ? `${PathUtil.basename(this.project.dir)} — ${this.project.cfg.top || 'no top module'}` : 'Open a folder of Verilog files…';
    Host.setTitle(this.project ? `${this.project.cfg.top || PathUtil.basename(this.project.dir)} — HDLPhy` : 'HDLPhy');
    this.runBtn.innerHTML = '';
    this.runBtn.append(icon(this.running ? 'debug-stop' : 'play'), this.running ? 'Stop' : 'Run Flow');
    this.runBtn.classList.toggle('running', this.running);
    this.runBtn.classList.toggle('disabled', !this.running && !(this.project && this.project.cfg.top));
    this.renderSidebar();
    this.renderStatus();
  },

  // ---------------------------------------------------------------- projects

  async openFolderDialog() {
    const r = await Host.openDialog({ properties: ['openDirectory'], title: 'Open a folder with Verilog sources' });
    if (r.length) this.openPaths(r);
  },
  async openFilesDialog() {
    const r = await Host.openDialog({ properties: ['openFile', 'multiSelections'], filters: [{ name: 'Verilog / SystemVerilog', extensions: ['v', 'sv', 'vh', 'svh'] }] });
    if (r.length) this.openPaths(r);
  },

  openPaths(paths) {
    if (this.running) { showToast('Stop the current run first'); return; }
    let dir = paths[0];
    let files = null;
    const st = Host.fs.stat(dir);
    if (!st) return;
    if (!st.isDir) {
      if (PathUtil.basename(dir) === 'hdlphy.json') { dir = PathUtil.dirname(dir); } else {
        files = paths.filter((p) => /\.(v|sv)$/i.test(p));
        dir = PathUtil.dirname(dir);
      }
    }
    const saved = this.readProjectFile(dir);
    const all = Host.fs.hdlFiles(dir);
    const cfg = Object.assign({ sources: null, top: null, clock_port: null, clock_period_ns: 10, utilization: 40, aspect_ratio: 1,
      core_margin_um: 5, place_density: 0.6, pin_input_side: 'any', pin_output_side: 'any', pin_clock_side: 'inputs',
      pin_bus_order: 'free', corner: 'tt_025C_1v80', defines: {}, include_dirs: [] }, saved || {});
    // sources are stored relative to the project folder
    // explicitly opened files win, then the saved list, then every non-testbench file in the folder
    let sources = files || (cfg.sources ? cfg.sources.map((s) => PathUtil.resolve(dir, s)) : all.filter((f) => !/(^|[/_])tb_|_tb\.s?v$|testbench/i.test(PathUtil.basename(f))));
    if (files && saved && saved.top) cfg.top = null;
    sources = sources.filter((s) => Host.fs.exists(s));
    this.project = { dir, all, cfg };
    this.project.cfg.sources = sources;
    this.scanModules();
    if (!cfg.top || !this.modules.some((m) => m.name === cfg.top)) cfg.top = this.guessTop();
    this.applyTopDefaults(!saved);
    this.saveProject();
    store.set('lastProject', dir);
    const recent = store.get('recentProjects', []).filter((p) => p !== dir);
    recent.unshift(dir);
    store.set('recentProjects', recent.slice(0, 10));
    this.loadRunState();
    this.render();
    this.schematic.loadedKey = null;
    this.layout.loadedKey = null;
    if (this.tab === 'schematic') this.schematic.load(null); else this.layout.load();
  },

  readProjectFile(dir) {
    const t = Host.fs.readText(PathUtil.join(dir, 'hdlphy.json'));
    if (!t) return null;
    try { return JSON.parse(t); } catch { return null; }
  },

  saveProject() {
    if (!this.project) return;
    const c = this.project.cfg;
    const out = Object.assign({}, c, { sources: c.sources.map((s) => PathUtil.relative(this.project.dir, s) || s) });
    Host.fs.writeText(PathUtil.join(this.project.dir, 'hdlphy.json'), JSON.stringify(out, null, 1) + '\n');
  },

  runDir() {
    if (!this.project || !this.project.cfg.top) return null;
    return PathUtil.join(this.project.dir, 'hdlphy_run', this.project.cfg.top);
  },
  lypPath() { return this.tools && this.tools.pdk ? this.tools.pdk.lyp : null; },
  layoutAvailable() { return this.layout.available(); },

  // Module declarations and ports, read from the sources with a light parser (enough for picking the top and the clock).
  scanModules() {
    const mods = [];
    for (const f of this.project.all) {
      let text = Host.fs.readText(f);
      if (!text) continue;
      text = text.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
      const re = /\bmodule\s+(\w+)\s*(#\s*\([\s\S]*?\)\s*)?\(([\s\S]*?)\)\s*;([\s\S]*?)\bendmodule\b/g;
      let m;
      while ((m = re.exec(text))) {
        const ports = [];
        const head = m[3], body = m[4];
        const decl = /\b(input|output|inout)\b\s*(?:wire|reg|logic|signed|\s)*\s*(\[[^\]]+\])?\s*([\w\s,]+?)(?=[;)]|,\s*(?:input|output|inout)\b|$)/g;
        let d;
        for (const src of [head, body]) {
          decl.lastIndex = 0;
          while ((d = decl.exec(src))) {
            for (const n of d[3].split(',').map((s) => s.trim()).filter((s) => /^\w+$/.test(s))) {
              if (!ports.some((p) => p.name === n)) ports.push({ name: n, dir: d[1], width: d[2] || '' });
            }
          }
        }
        const insts = [];
        const instRe = /^\s*(\w+)\s*(?:#\s*\([^;]*?\)\s*)?(\w+)\s*\(/gm;
        let k;
        while ((k = instRe.exec(body))) if (!/^(if|for|while|case|assign|always|initial|function|task|module|begin|end|else|wire|reg|logic|input|output|inout|parameter|localparam|generate|genvar|integer|return)$/.test(k[1])) insts.push(k[1]);
        mods.push({ name: m[1], file: f, ports, insts, included: this.project.cfg.sources.includes(f) });
      }
    }
    this.modules = mods;
  },

  guessTop() {
    const inc = this.modules.filter((m) => m.included);
    const used = new Set(inc.flatMap((m) => m.insts));
    const tops = inc.filter((m) => !used.has(m.name) && !/^tb|_tb$|testbench/i.test(m.name));
    const pick = tops.find((m) => m.ports.length) || tops[0] || inc[0];
    return pick ? pick.name : null;
  },

  topModule() { return this.project && this.modules.find((m) => m.name === this.project.cfg.top); },

  applyTopDefaults(fresh) {
    const top = this.topModule();
    const c = this.project.cfg;
    if (!top) return;
    const inputs = top.ports.filter((p) => p.dir === 'input');
    if (fresh || c.clock_port == null || (c.clock_port && !inputs.some((p) => p.name === c.clock_port))) {
      const clk = inputs.find((p) => /^(clk|clock|clk_i|i_clk|sys_clk|clk_in)$/i.test(p.name)) || inputs.find((p) => /cl(oc)?k/i.test(p.name));
      c.clock_port = clk ? clk.name : '';
    }
  },

  setCfg(k, v) {
    if (!this.project) return;
    this.project.cfg[k] = v;
    if (k === 'top') { this.applyTopDefaults(false); this.loadRunState(); this.schematic.loadedKey = null; this.layout.loadedKey = null; }
    if (k === 'sources') {
      this.scanModules();
      const inc = this.modules.filter((m) => m.included);
      if (!inc.some((m) => m.name === this.project.cfg.top)) { this.project.cfg.top = this.guessTop(); this.applyTopDefaults(false); this.loadRunState(); }
    }
    this.saveProject();
    this.render();
    if (k === 'top') { if (this.tab === 'schematic') this.schematic.load(null); else this.layout.load(); }
  },

  // Restores stage status and metrics from an earlier run of this top module.
  loadRunState() {
    this.stageState = {};
    this.metrics = {};
    const run = this.runDir();
    if (!run) return;
    const m = Host.fs.readText(PathUtil.join(run, 'reports', 'metrics.json'));
    if (m) { try { this.metrics = JSON.parse(m); } catch { /* ignore */ } }
    const results = PathUtil.join(run, 'results');
    const marks = { synth: 'gate.json', floorplan: '2_floorplan.odb', place: '3_place.odb', cts: '4_cts.odb', route: '5_route.odb', gds: 'final.gds' };
    for (const s of STAGES) if (Host.fs.exists(PathUtil.join(results, marks[s.id]))) this.stageState[s.id] = { status: 'done', seconds: null, old: true };
  },

  // ---------------------------------------------------------------- running the flow

  writeRunConfig() {
    const c = this.project.cfg;
    const run = this.runDir();
    const cfg = {
      design: c.top, top: c.top, sources: c.sources, include_dirs: (c.include_dirs || []).map((d) => PathUtil.resolve(this.project.dir, d)),
      defines: c.defines || {}, clock_port: c.clock_port || '', clock_period_ns: Number(c.clock_period_ns) || 10,
      utilization: Number(c.utilization) || 40, aspect_ratio: Number(c.aspect_ratio) || 1, core_margin_um: Number(c.core_margin_um) || 5,
      place_density: Number(c.place_density) || 0.6, pin_input_side: c.pin_input_side || 'any', pin_output_side: c.pin_output_side || 'any',
      pin_clock_side: c.pin_clock_side || 'inputs', pin_bus_order: c.pin_bus_order || 'free', corner: c.corner || 'tt_025C_1v80', threads: Prefs.get('threads'), run_dir: run,
    };
    const p = PathUtil.join(run, 'config.json');
    const err = Host.fs.writeText(p, JSON.stringify(cfg, null, 1) + '\n');
    if (err) { showToast('Could not write the run configuration: ' + err); return null; }
    return p;
  },

  async run(from, to) {
    if (this.running || !this.project) return;
    const c = this.project.cfg;
    if (!c.top) { showToast('Choose a top module first'); this.showSidebar('design'); return; }
    if (!c.sources.length) { showToast('Add Verilog sources first'); return; }
    const missing = this.missingTools(from, to);
    if (missing.length) {
      modal('Tools not found', h('div', { class: 'vstack small' }, ...missing.map((m) => h('div', null, h('b', null, m.name), ' — ', m.hint))), [{ label: 'OK', primary: true }],
        'HDLPhy runs yosys, OpenROAD and KLayout. These were not found:');
      return;
    }
    const cfgPath = this.writeRunConfig();
    if (!cfgPath) return;
    const i0 = STAGES.findIndex((s) => s.id === from), i1 = STAGES.findIndex((s) => s.id === to);
    for (let i = i0; i < STAGES.length; i++) delete this.stageState[STAGES[i].id];
    for (let i = i0; i <= i1; i++) this.stageState[STAGES[i].id] = { status: 'queued' };
    this.output = [];
    this.flowArgs = ['run', cfgPath, '--from', from, '--to', to];
    this.lastRange = [from, to];
    const r = await Host.flow.start(this.flowArgs);
    if (!r.ok) { showToast(r.error); return; }
    this.running = true;
    this.runStart = Date.now();
    this.panelTab = 'output';
    if (!this.panelOpen) this.togglePanel();
    this.showSidebar('flow');
    this.render();
    this.renderPanel();
    if (this.tab === 'schematic' && i0 === 0) this.schematic.showEmpty();
    if (this.tab === 'layout' && i0 <= 5) this.layout.showEmpty();
  },

  stop() { Host.flow.stop(); },

  missingTools(from, to) {
    if (!this.tools || !this.tools.tools) return [];
    const i0 = STAGES.findIndex((s) => s.id === from), i1 = STAGES.findIndex((s) => s.id === to);
    const need = new Set();
    for (let i = i0; i <= i1; i++) need.add(i === 0 ? 'yosys' : i === 5 ? 'klayout' : 'openroad');
    const hints = { yosys: 'build it with setup/install-eda-tools.sh build (into ~/eda/tools/yosys) or install the OSS CAD Suite',
      openroad: 'build it with setup/install-eda-tools.sh build (into ~/eda/tools/openroad)', klayout: 'sudo apt install klayout' };
    return [...need].filter((t) => !this.tools.tools[t]).map((t) => ({ name: t, hint: hints[t] }));
  },

  // Exports an intermediate layout view (floorplan / place / cts) through the flow driver.
  exportView(stage) {
    return new Promise(async (resolve) => {
      const cfgPath = this.writeRunConfig();
      if (!cfgPath) { resolve(false); return; }
      this.viewResolve = resolve;
      const r = await Host.flow.start(['view', cfgPath, stage]);
      if (!r.ok) { this.viewResolve = null; resolve(false); return; }
      this.exporting = true;
      this.renderStatus();
    });
  },

  onFlowLines(lines) {
    const add = [];
    for (const line of lines) {
      if (line.startsWith('##HDLPHY ')) {
        let ev;
        try { ev = JSON.parse(line.slice(9)); } catch { continue; }
        this.onFlowEvent(ev);
        if (ev.event === 'stage' || ev.event === 'error' || (ev.event === 'log' && ev.text)) add.push({ kind: 'event', text: this.describeEvent(ev), ev });
      } else add.push({ kind: /\b(ERROR|Error|error:)/.test(line) ? 'error' : /\b(WARNING|Warning)\b/.test(line) ? 'warning' : 'text', text: line });
    }
    this.output.push(...add);
    if (this.output.length > 20000) this.output.splice(0, this.output.length - 20000);
    this.appendOutput(add);
  },

  describeEvent(ev) {
    if (ev.event === 'stage') {
      const s = STAGES.find((x) => x.id === ev.stage);
      const name = s ? s.title : ev.stage;
      if (ev.status === 'start') return `▶ ${name}`;
      return ev.status === 'done' ? `✔ ${name} finished in ${Fmt.secs(ev.seconds)}` : `✖ ${name} failed after ${Fmt.secs(ev.seconds)}`;
    }
    if (ev.event === 'error') return '✖ ' + ev.message;
    return ev.text;
  },

  onFlowEvent(ev) {
    if (ev.event === 'stage') {
      this.stageState[ev.stage] = { status: ev.status === 'start' ? 'running' : ev.status, seconds: ev.seconds, started: ev.status === 'start' ? Date.now() : null };
      if (ev.status === 'done' && ev.stage === 'synth') { this.schematic.loadedKey = null; if (this.tab === 'schematic') this.schematic.load(null); }
      if (ev.status === 'done' && ev.stage === 'gds') { this.layout.loadedKey = null; this.layout.stageId = 'route'; if (this.tab === 'layout') this.layout.load(); }
      if (ev.status === 'done' && ev.stage === 'cts') {
        const cts = this.metrics.synth && this.metrics.synth.has_clock === false;
        if (cts) this.stageState.cts.note = 'no clock';
      }
      this.renderSidebar();
      this.renderStatus();
    } else if (ev.event === 'metrics') {
      this.metrics[ev.stage] = Object.assign(this.metrics[ev.stage] || {}, ev.values);
      if (this.sidebarView !== 'design') this.renderSidebar();
    } else if (ev.event === 'error') {
      showToast(ev.message, 5000);
    }
  },

  onFlowExit(r) {
    if (this.exporting) {
      this.exporting = false;
      const res = this.viewResolve;
      this.viewResolve = null;
      this.renderStatus();
      if (res) res(r.code === 0);
      return;
    }
    this.running = false;
    for (const [k, s] of Object.entries(this.stageState)) if (s.status === 'running' || s.status === 'queued') this.stageState[k] = { status: s.status === 'running' ? 'failed' : 'idle', note: r.signal ? 'stopped' : '' };
    const failed = Object.entries(this.stageState).find(([, s]) => s.status === 'failed');
    const msg = r.signal ? 'Run stopped' : failed ? `${STAGES.find((s) => s.id === failed[0]).title} failed — see the Output panel` : `Done in ${Fmt.secs((Date.now() - this.runStart) / 1000)}`;
    this.output.push({ kind: failed ? 'error' : 'event', text: (failed ? '✖ ' : '✔ ') + msg });
    this.appendOutput([this.output[this.output.length - 1]]);
    showToast(msg, 4000);
    const ran = this.stageState;
    this.loadRunState();
    // keep this run's times and failures; the files only tell which stages have results
    for (const [k, st] of Object.entries(ran)) if (st.status === 'done' || st.status === 'failed') this.stageState[k] = st;
    this.render();
    this.schematic.loadedKey = null;
    this.layout.loadedKey = null;
    if (this.tab === 'schematic') this.schematic.load(this.schematic.module); else this.layout.load();
  },

  // ---------------------------------------------------------------- cross-probing

  findInLayout(name) {
    this.showTab('layout');
    const go = () => { if (!this.layout.find(name)) showToast(`${name} is not in the layout (it may have been removed or renamed by optimization)`); };
    if (this.layout.data) go(); else setTimeout(go, 600);
  },
  findInSchematic(name) {
    this.showTab('schematic');
    const go = () => {
      if (this.schematic.view !== 'gate') { this.schematic.setView('gate'); setTimeout(go, 800); return; }
      if (this.schematic.result && this.schematic.result.cellInfo[name]) this.schematic.select(name);
      else showToast(`${name} is not in the synthesized netlist (added during place and route)`);
    };
    setTimeout(go, 300);
  },

  // ---------------------------------------------------------------- sidebar

  renderSidebar() {
    if (!this.sidebarEl) return;
    const v = this.sidebarView;
    this.sidebarEl.innerHTML = '';
    if (v === 'design') this.renderDesign();
    else if (v === 'flow') this.renderFlow();
    else this.renderReports();
  },

  section(title, ...rest) { return h('div', { class: 'section-header' }, icon('chevron-down'), title, ...rest); },

  renderDesign() {
    const sb = this.sidebarEl;
    sb.append(h('div', { class: 'sb-title' }, 'DESIGN', h('div', { class: 'grow' }),
      h('button', { class: 'icon-btn', title: 'Open folder…', onclick: () => this.openFolderDialog() }, icon('folder-opened')),
      h('button', { class: 'icon-btn', title: 'Reload sources', onclick: () => this.project && this.openPaths([this.project.dir]) }, icon('refresh'))));
    if (!this.project) {
      const recent = store.get('recentProjects', []).filter((p) => Host.fs.exists(p));
      sb.append(h('div', { class: 'sidebar-empty' },
        h('div', { class: 'dim' }, 'Open a folder with Verilog sources (for example one made in HDL Simulator). HDLPhy synthesizes it to SKY130 cells and places and routes it.'),
        h('button', { class: 'vs-button full', onclick: () => this.openFolderDialog() }, 'Open Folder'),
        h('button', { class: 'vs-button secondary full', onclick: () => this.openFilesDialog() }, 'Open Files'),
        h('button', { class: 'vs-button secondary full', onclick: () => this.openExample() }, 'Open Example (counter, UART)'),
        recent.length ? h('div', { class: 'small-dim', style: 'margin:8px 0 0' }, 'Recent') : null,
        ...recent.map((p) => h('div', { class: 'recent-row link', onclick: () => this.openPaths([p]) }, icon('folder'), h('span', null, PathUtil.basename(p)), h('span', { class: 'dim small' }, Paths.tilde(PathUtil.dirname(p)))))));
      return;
    }
    const c = this.project.cfg;
    const scroll = h('div', { class: 'scroll form' });
    sb.append(scroll);
    // sources
    scroll.append(this.section('SOURCES', h('span', { class: 'sub' }, `${c.sources.length} of ${this.project.all.length}`), h('div', { class: 'grow' }),
      h('button', { class: 'icon-btn', title: 'Add files…', onclick: async () => {
        const r = await Host.openDialog({ properties: ['openFile', 'multiSelections'], defaultPath: this.project.dir, filters: [{ name: 'Verilog', extensions: ['v', 'sv', 'vh', 'svh'] }] });
        if (r.length) { for (const f of r) if (!this.project.all.includes(f)) this.project.all.push(f); this.setCfg('sources', [...new Set([...c.sources, ...r])]); }
      } }, icon('add'))));
    for (const f of this.project.all) {
      const on = c.sources.includes(f);
      const mods = this.modules.filter((m) => m.file === f).map((m) => m.name).join(', ');
      scroll.append(h('label', { class: 'trow src-row', title: f },
        h('input', { type: 'checkbox', checked: on, onchange: (e) => this.setCfg('sources', e.target.checked ? [...c.sources, f] : c.sources.filter((s) => s !== f)) }),
        icon('file-code', 'ficon'), h('span', { class: 'nm' }, PathUtil.relative(this.project.dir, f)), h('span', { class: 'detail' }, mods)));
    }
    // top & clock
    const included = this.modules.filter((m) => c.sources.includes(m.file));
    const top = this.topModule();
    const field = (label, ctl, hint) => h('div', { class: 'form-row' }, h('div', { class: 'form-label' }, label), ctl, hint ? h('div', { class: 'set-hint' }, hint) : null);
    const num = (k, step, min, max, unit) => h('div', { class: 'hstack' }, h('input', { class: 'vs-input', type: 'number', step, min, max, value: c[k],
      onchange: (e) => { const v = parseFloat(e.target.value); if (!Number.isNaN(v)) this.setCfg(k, Math.max(min, Math.min(max, v))); } }), unit ? h('span', { class: 'dim small' }, unit) : null);
    scroll.append(this.section('TOP MODULE'),
      h('div', { class: 'form' },
        field('Top', h('select', { class: 'vs-select full', onchange: (e) => this.setCfg('top', e.target.value) },
          included.length ? included.map((m) => h('option', { value: m.name, selected: m.name === c.top }, m.name)) : h('option', null, 'No modules in the sources')),
        top ? `${top.ports.filter((p) => p.dir === 'input').length} inputs, ${top.ports.filter((p) => p.dir === 'output').length} outputs · ${PathUtil.basename(top.file)}` : null),
        field('Clock', h('select', { class: 'vs-select full', onchange: (e) => this.setCfg('clock_port', e.target.value) },
          h('option', { value: '', selected: !c.clock_port }, 'None (combinational)'),
          (top ? top.ports.filter((p) => p.dir === 'input' && !p.width) : []).map((p) => h('option', { value: p.name, selected: p.name === c.clock_port }, p.name)))),
        field('Clock period', num('clock_period_ns', 0.5, 1, 1000, 'ns'), c.clock_period_ns ? `${Fmt.num(1000 / c.clock_period_ns, 1)} MHz${c.clock_port ? '' : ' (virtual clock for I/O timing)'}` : null)));
    scroll.append(this.section('FLOORPLAN'),
      h('div', { class: 'form' },
        field('Utilization', num('utilization', 5, 5, 90, '%'), 'Cell area / core area'),
        field('Aspect ratio', num('aspect_ratio', 0.1, 0.2, 5, 'H / W')),
        field('Core margin', num('core_margin_um', 1, 2, 100, 'µm'), 'Space between the core and the die edge'),
        field('Placement density', num('place_density', 0.05, 0.2, 1, ''), 'Target density for global placement')));
    // I/O pin edges (applied by the floorplan, which sizes the die for them, and the placement)
    const sideSel = (k, extra) => h('select', { class: 'vs-select full', onchange: (e) => this.setCfg(k, e.target.value) },
      [...(extra || []), ...PIN_SIDES].map(([v, l]) => h('option', { value: v, selected: v === (c[k] || (extra ? extra[0][0] : 'any')) }, l)));
    const sideHint = (v) => (v === 'left' || v === 'right' ? 'met3 pins' : v === 'top' || v === 'bottom' ? 'met2 pins' : null);
    const clkSide = c.pin_clock_side === 'inputs' || !c.pin_clock_side ? c.pin_input_side : c.pin_clock_side;
    scroll.append(this.section('PINS'),
      h('div', { class: 'form' },
        field('Inputs', sideSel('pin_input_side'), sideHint(c.pin_input_side)),
        field('Outputs', sideSel('pin_output_side'), sideHint(c.pin_output_side)),
        c.clock_port ? field('Clock', sideSel('pin_clock_side', [['inputs', 'With the inputs']]), sideHint(clkSide)) : null,
        field('Bus order', h('select', { class: 'vs-select full', onchange: (e) => this.setCfg('pin_bus_order', e.target.value) },
          BUS_ORDERS.map(([v, l]) => h('option', { value: v, selected: v === (c.pin_bus_order || 'free') }, l))),
          c.pin_bus_order && c.pin_bus_order !== 'free' ? 'Each bus kept together, in bit-index order along its edge' : null),
        h('div', { class: 'set-hint' }, 'The die grows if an edge is too short for its pins. Takes effect from Floorplan.')));
    scroll.append(this.section('TECHNOLOGY'),
      h('div', { class: 'form' },
        field('PDK', h('div', { class: 'mono small' }, 'sky130A · sky130_fd_sc_hd')),
        field('Timing corner', h('select', { class: 'vs-select full', onchange: (e) => this.setCfg('corner', e.target.value) },
          CORNERS.map(([v, l]) => h('option', { value: v, selected: v === c.corner }, l)))),
        this.tools && this.tools.pdk ? h('div', { class: 'set-hint mono wrap' }, Paths.tilde(this.tools.pdk.pdk_dir)) : null));
    scroll.append(h('div', { class: 'pad-x', style: 'padding-top:12px' },
      h('button', { class: 'vs-button full', disabled: this.running || !c.top, onclick: () => this.run('synth', 'gds') }, icon('play'), 'Run Full Flow'),
      h('div', { style: 'height:6px' }),
      h('button', { class: 'vs-button secondary full', disabled: this.running || !c.top, onclick: () => this.run('synth', 'synth') }, icon('symbol-structure'), 'Synthesis Only')));
    scroll.append(h('div', { class: 'sidebar-foot' }, 'Settings are saved in ', h('span', { class: 'mono' }, 'hdlphy.json'), ', results in ', h('span', { class: 'link mono', onclick: () => this.runDir() && Host.openPath(this.runDir()) }, PathUtil.join('hdlphy_run', c.top || '…'))));
  },

  renderFlow() {
    const sb = this.sidebarEl;
    sb.append(h('div', { class: 'sb-title' }, 'FLOW', h('div', { class: 'grow' }),
      h('button', { class: 'icon-btn', title: 'Run all stages', onclick: () => this.run('synth', 'gds') }, icon('run-all'))));
    const scroll = h('div', { class: 'scroll' });
    sb.append(scroll);
    if (!this.project) { scroll.append(h('div', { class: 'dim-pad' }, 'Open a design first.')); return; }
    STAGES.forEach((s, i) => {
      const st = this.stageState[s.id] || { status: 'idle' };
      const ic = { running: 'loading spin', done: 'pass-filled', failed: 'error', queued: 'circle-large-outline', idle: 'circle-large-outline' }[st.status] || 'circle-large-outline';
      const prevDone = i === 0 || (this.stageState[STAGES[i - 1].id] || {}).status === 'done';
      const row = h('div', { class: 'stage-row ' + st.status },
        h('span', { class: `codicon codicon-${ic} stage-icon` }),
        h('div', { class: 'stage-text' },
          h('div', { class: 'stage-name' }, s.title, h('span', { class: 'dim small' }, ' · ' + s.tool)),
          h('div', { class: 'dim small' }, st.status === 'running' ? 'Running…' : st.status === 'failed' ? (st.note === 'stopped' ? 'Stopped' : 'Failed') : st.status === 'done' ? this.stageSummary(s.id, st) : s.desc)),
        h('button', { class: 'icon-btn hover-only', title: `Run ${s.title} only`, disabled: this.running || !prevDone, onclick: () => this.run(s.id, s.id) }, icon('play')),
        h('button', { class: 'icon-btn hover-only', title: `Run from ${s.title} to the end`, disabled: this.running || !prevDone, onclick: () => this.run(s.id, 'gds') }, icon('run-all')),
        h('button', { class: 'icon-btn hover-only', title: 'Show the log', onclick: () => this.showLog(s.id) }, icon('output')));
      scroll.append(row);
    });
    scroll.append(h('div', { class: 'pad-x', style: 'padding-top:12px' },
      this.running ? h('button', { class: 'vs-button full', style: 'background:var(--error)', onclick: () => this.stop() }, icon('debug-stop'), 'Stop')
        : h('button', { class: 'vs-button full', onclick: () => this.run('synth', 'gds') }, icon('play'), 'Run Full Flow')));
    scroll.append(h('div', { class: 'sidebar-foot' }, 'Each stage reads the previous stage\'s result, so a stage can be re-run after changing its settings. Logs: ',
      h('span', { class: 'link mono', onclick: () => this.runDir() && Host.openPath(PathUtil.join(this.runDir(), 'logs')) }, 'logs/')));
  },

  stageSummary(id, st) {
    const m = this.metrics;
    const t = st.seconds != null ? Fmt.secs(st.seconds) : 'earlier run';
    if (id === 'synth' && m.synth) return `${m.synth.cells} cells · ${Fmt.num(m.synth.cell_area_um2, 1)} µm² · ${t}`;
    if (id === 'floorplan' && m.floorplan) return `${Fmt.num(m.floorplan.die_width_um, 1)} × ${Fmt.num(m.floorplan.die_height_um, 1)} µm · ${t}`;
    if (id === 'place' && m.place) return `WNS ${Fmt.num(m.place.place_wns, 3)} ns · ${t}`;
    if (id === 'cts' && m.cts) return (m.synth && m.synth.has_clock === false ? 'no clock · ' : '') + `WNS ${Fmt.num(m.cts.cts_wns, 3)} ns · ${t}`;
    if (id === 'route' && m.route) return `${Fmt.num(m.route.drc_violations, 0)} DRC · ${Fmt.num(m.route.wirelength_um, 0)} µm wire · ${t}`;
    if (id === 'gds' && m.gds) return `${Fmt.num(m.gds.gds_bytes / 1024, 0)} KiB · ${t}`;
    return t;
  },

  renderReports() {
    const sb = this.sidebarEl;
    sb.append(h('div', { class: 'sb-title' }, 'REPORTS'));
    const scroll = h('div', { class: 'scroll' });
    sb.append(scroll);
    const m = this.metrics;
    if (!this.project || !Object.keys(m).length) { scroll.append(h('div', { class: 'dim-pad' }, 'Run the flow to see area, timing, power and routing results.')); return; }
    const row = (k, v, cls) => h('div', { class: 'kv-row' }, h('span', { class: 'dim' }, k), h('span', { class: 'mono ' + (cls || '') }, v));
    const slackCls = (v) => (v == null || v === '' ? '' : Number(v) < 0 ? 'bad' : 'good');
    const s = m.synth || {}, f = m.floorplan || {}, r = m.route || {}, c = m.cts || {};
    const final = m.route ? r : c.cts_wns != null ? c : m.place || {};
    const prefix = m.route ? 'route' : c.cts_wns != null ? 'cts' : 'place';
    scroll.append(this.section('SYNTHESIS'),
      row('Cells', Fmt.num(s.cells, 0)), row('Flip-flops', Fmt.num(s.flops, 0)), row('Cell area', `${Fmt.num(s.cell_area_um2, 2)} µm²`));
    if (s.cells_by_type) {
      const top = Object.entries(s.cells_by_type).sort((a, b) => b[1] - a[1]).slice(0, 12);
      scroll.append(h('div', { class: 'cell-bars' }, top.map(([k, v]) => h('div', { class: 'cell-bar', title: k },
        h('span', { class: 'mono small ellipsis' }, k.split('__').pop()), h('span', { class: 'bar', style: `width:${Math.max(4, 100 * v / top[0][1])}%` }), h('span', { class: 'dim small' }, v)))));
    }
    if (m.floorplan) scroll.append(this.section('FLOORPLAN'), row('Die', `${Fmt.num(f.die_width_um, 2)} × ${Fmt.num(f.die_height_um, 2)} µm`));
    if (final[prefix + '_wns'] != null || m.route) {
      scroll.append(this.section(m.route ? 'AFTER ROUTING' : 'TIMING'),
        row('Design area', `${Fmt.num(final[prefix + '_design_area'], 1)} µm²`),
        row('Instances', Fmt.num(final[prefix + '_instances'], 0)),
        row('Worst setup slack', `${Fmt.num(final[prefix + '_wns'], 3)} ns`, slackCls(final[prefix + '_wns'])),
        row('Worst hold slack', `${Fmt.num(final[prefix + '_whs'], 3)} ns`, slackCls(final[prefix + '_whs'])),
        row('Total negative slack', `${Fmt.num(final[prefix + '_tns'], 3)} ns`, slackCls(final[prefix + '_tns'])));
      if (m.route) scroll.append(row('Wire length', `${Fmt.num(r.wirelength_um, 0)} µm`), row('DRC violations', Fmt.num(r.drc_violations, 0), Number(r.drc_violations) > 0 ? 'bad' : 'good'), row('Power (est.)', Fmt.power(r.power_total_w)));
      if (m.route && r.pdn_vpwr_connected != null) {
        const pgOk = Number(r.pdn_vpwr_connected) === 1 && Number(r.pdn_vgnd_connected) === 1 && Number(r.pg_unconnected_pins) === 0;
        scroll.append(row('Power grid', pgOk ? 'VPWR, VGND connected' : `${Fmt.num(r.pg_unconnected_pins, 0)} open cell pins${Number(r.pdn_vpwr_connected) === 1 && Number(r.pdn_vgnd_connected) === 1 ? '' : ', grid not connected'}`, pgOk ? 'good' : 'bad'));
      }
    }
    const rep = this.runDir() && PathUtil.join(this.runDir(), 'reports');
    if (rep) {
      scroll.append(this.section('REPORT FILES'));
      for (const e of Host.fs.list(rep).filter((x) => !x.isDir).sort((a, b) => a.name.localeCompare(b.name))) {
        scroll.append(h('div', { class: 'trow', style: 'padding-left:20px', onclick: () => this.showReport(PathUtil.join(rep, e.name)) }, icon('file', 'ficon'), h('span', { class: 'nm' }, e.name)));
      }
    }
  },

  // ---------------------------------------------------------------- bottom panel (output, report viewer)

  renderPanel() {
    const p = this.panelEl;
    p.innerHTML = '';
    const tab = (id, label) => h('button', { class: 'panel-tab' + (this.panelTab === id ? ' active' : ''), onclick: () => { this.panelTab = id; this.renderPanel(); } }, label);
    p.append(h('div', { class: 'panel-header' }, tab('output', 'OUTPUT'), tab('report', this.reportPath ? 'REPORT · ' + PathUtil.basename(this.reportPath) : 'REPORT'), h('div', { class: 'grow' }),
      this.panelTab === 'output' ? h('button', { class: 'icon-btn', title: 'Clear', onclick: () => { this.output = []; this.renderPanel(); } }, icon('clear-all')) : null,
      h('button', { class: 'icon-btn', title: 'Close panel', onclick: () => this.togglePanel() }, icon('close'))));
    this.outBody = h('div', { class: 'panel-body output selectable' });
    p.append(this.outBody);
    if (this.panelTab === 'output') {
      if (!this.output.length) this.outBody.append(h('div', { class: 'dim' }, 'Tool output appears here when the flow runs.'));
      this.appendOutput(this.output.slice(-4000), true);
    } else {
      const text = this.reportPath ? (Host.fs.readText(this.reportPath) || '(empty)') : 'Pick a report in the Reports view.';
      this.outBody.append(h('pre', { class: 'report-text' }, text));
    }
  },

  appendOutput(items, initial = false) {
    if (this.panelTab !== 'output' || !this.outBody) return;
    const atEnd = initial || this.outBody.scrollTop + this.outBody.clientHeight >= this.outBody.scrollHeight - 30;
    const frag = document.createDocumentFragment();
    for (const it of items) frag.append(h('div', { class: 'out-line ' + it.kind }, it.text));
    this.outBody.append(frag);
    while (this.outBody.childElementCount > 6000) this.outBody.firstElementChild.remove();
    if (atEnd) this.outBody.scrollTop = this.outBody.scrollHeight;
  },

  showLog(stage) {
    const i = STAGES.findIndex((s) => s.id === stage) + 1;
    const p = this.runDir() && PathUtil.join(this.runDir(), 'logs', `${i}_${stage}.log`);
    if (!p || !Host.fs.exists(p)) { showToast('No log for this stage yet'); return; }
    this.showReport(p);
  },
  showReport(p) {
    this.reportPath = p;
    this.panelTab = 'report';
    if (!this.panelOpen) this.togglePanel();
    this.renderPanel();
  },

  // ---------------------------------------------------------------- status bar

  renderStatus() {
    if (!this.statusEl) return;
    const s = this.statusEl;
    s.innerHTML = '';
    const t = this.tools && this.tools.tools;
    const tool = (name, label) => h('span', { class: 'sb-item', title: t && t[name] ? t[name] : `${label} not found` },
      icon(t && t[name] ? 'check' : 'warning'), label);
    s.append(h('span', { class: 'sb-item sb-accent' }, icon('chip'), 'SKY130'));
    if (this.running) {
      const cur = STAGES.find((x) => (this.stageState[x.id] || {}).status === 'running');
      s.append(h('span', { class: 'sb-item' }, h('span', { class: 'codicon codicon-loading spin' }), cur ? cur.title + '…' : 'Starting…'));
    } else if (this.exporting) s.append(h('span', { class: 'sb-item' }, h('span', { class: 'codicon codicon-loading spin' }), 'Exporting layout…'));
    s.append(h('span', { class: 'sb-spacer' }));
    if (t) s.append(tool('yosys', 'yosys'), tool('openroad', 'OpenROAD'), tool('klayout', 'KLayout'));
  },

  // ---------------------------------------------------------------- menus, settings, keys

  stageMenu(e) {
    if (!this.project) return;
    Menus.popup([{ type: 'header', label: 'Run one stage' }, ...STAGES.map((s, i) => ({ label: s.title, enabled: !this.running && (i === 0 || (this.stageState[STAGES[i - 1].id] || {}).status === 'done'), action: () => this.run(s.id, s.id) })),
      { type: 'separator' }, { label: 'Synthesis Only', enabled: !this.running, action: () => this.run('synth', 'synth') }, { label: 'Up to Routing (no GDS)', enabled: !this.running, action: () => this.run('synth', 'route') }], e);
  },

  appMenu(e) {
    const recent = store.get('recentProjects', []).filter((p) => Host.fs.exists(p));
    Menus.popup([
      { label: 'Open Folder…', accelerator: 'Ctrl+O', action: () => this.openFolderDialog() },
      { label: 'Open Files…', action: () => this.openFilesDialog() },
      { label: 'Open Recent', submenu: recent.length ? recent.map((p) => ({ label: Paths.tilde(p), action: () => this.openPaths([p]) })) : [{ label: 'None', enabled: false }] },
      { label: 'Open Example', action: () => this.openExample() },
      { type: 'separator' },
      { label: 'Run Full Flow', accelerator: 'F5', enabled: !this.running && !!this.project, action: () => this.run('synth', 'gds') },
      { label: 'Stop', enabled: this.running, action: () => this.stop() },
      { type: 'separator' },
      { label: 'Schematic', accelerator: 'Ctrl+1', action: () => this.showTab('schematic') },
      { label: 'Layout', accelerator: 'Ctrl+2', action: () => this.showTab('layout') },
      { label: 'Open Results Folder', enabled: !!(this.runDir() && Host.fs.exists(this.runDir())), action: () => Host.openPath(this.runDir()) },
      { label: 'Open GDS in KLayout', enabled: this.layout.available(), action: () => this.layout.openKLayout() },
      { type: 'separator' },
      { label: 'Theme', submenu: Object.values(THEMES).map((t) => ({ label: t.name, checked: Prefs.get('themeID') === t.id, action: () => { Prefs.set('themeID', t.id); this.applyTheme(); } })) },
      { label: 'Settings…', accelerator: 'Ctrl+,', action: () => this.openSettings() },
      { label: 'Toggle Developer Tools', action: () => Host.toggleDevTools() },
      { type: 'separator' },
      { label: 'Quit', accelerator: 'Ctrl+Q', action: () => this.requestClose() },
    ], e);
  },

  openExample() {
    const dir = Host.launch.examples;
    if (!Host.fs.exists(dir)) { showToast('Examples not found'); return; }
    // work on a copy so results never land inside the app
    const dest = PathUtil.join(Host.launch.documents || Host.launch.home, 'HDLPhy Examples');
    Host.fs.mkdir(dest);
    for (const e of Host.fs.list(dir)) {
      if (e.isDir) continue;
      const target = PathUtil.join(dest, e.name);
      if (!Host.fs.exists(target)) Host.fs.writeText(target, Host.fs.readText(PathUtil.join(dir, e.name)) || '');
    }
    if (!Host.fs.exists(PathUtil.join(dest, 'hdlphy.json'))) {
      Host.fs.writeText(PathUtil.join(dest, 'hdlphy.json'), JSON.stringify({ sources: ['counter.v'], top: 'counter', clock_port: 'clk', clock_period_ns: 10 }, null, 1));
    }
    this.openPaths([dest]);
  },

  openSettings() {
    const theme = h('select', { class: 'vs-select', onchange: (e) => { Prefs.set('themeID', e.target.value); this.applyTheme(); } },
      Object.values(THEMES).map((t) => h('option', { value: t.id, selected: Prefs.get('themeID') === t.id }, t.name)));
    const threads = h('input', { class: 'vs-input', type: 'number', min: 1, max: 64, value: Prefs.get('threads'), onchange: (e) => Prefs.set('threads', Math.max(1, parseInt(e.target.value, 10) || 1)) });
    const maxCells = h('input', { class: 'vs-input', type: 'number', min: 100, max: 100000, step: 100, value: Prefs.get('schematicMaxCells'), onchange: (e) => Prefs.set('schematicMaxCells', Math.max(100, parseInt(e.target.value, 10) || 2500)) });
    const restore = h('input', { type: 'checkbox', checked: Prefs.get('restoreProject'), onchange: (e) => Prefs.set('restoreProject', e.target.checked) });
    const t = this.tools || {};
    const tl = (k, label) => h('div', { class: 'tool-row' }, icon(t.tools && t.tools[k] ? 'pass-filled' : 'error', t.tools && t.tools[k] ? 'ok' : ''), h('b', null, label),
      h('span', { class: 'dim mono small ellipsis' }, t.tools && t.tools[k] ? Paths.tilde(t.tools[k]) + (t.versions && t.versions[k] ? '  ·  ' + t.versions[k] : '') : 'not found'));
    modal('Settings', h('div', { class: 'settings' },
      h('div', { class: 'set-row' }, h('div', { class: 'set-label' }, 'Color theme'), h('div', { class: 'set-control' }, theme)),
      h('div', { class: 'set-row' }, h('div', { class: 'set-label' }, 'Tool threads'), h('div', { class: 'set-control' }, threads, h('div', { class: 'set-hint' }, 'OpenROAD threads (placement, routing).'))),
      h('div', { class: 'set-row' }, h('div', { class: 'set-label' }, 'Schematic size limit'), h('div', { class: 'set-control' }, maxCells, h('div', { class: 'set-hint' }, 'Larger netlists ask before drawing.'))),
      h('div', { class: 'set-row' }, h('div', { class: 'set-label' }, 'Start-up'), h('label', { class: 'vs-check' }, restore, 'Reopen the last design')),
      h('div', { class: 'set-section' }, 'Tools'),
      h('div', { class: 'set-tools' }, tl('yosys', 'yosys'), tl('openroad', 'OpenROAD'), tl('klayout', 'KLayout'),
        t.missing_pdk_files && t.missing_pdk_files.length ? h('div', { class: 'bad' }, 'Missing PDK files: ' + t.missing_pdk_files.join(', ')) : h('div', { class: 'dim' }, 'PDK: ' + (t.pdk ? Paths.tilde(t.pdk.pdk_dir) : '?'))),
      h('div', { class: 'set-hint' }, 'Tools are looked up in ~/eda/tools/<tool>/bin, the OSS CAD Suite and PATH; $HDLPHY_YOSYS, $HDLPHY_OPENROAD and $HDLPHY_KLAYOUT override them, $PDK_ROOT the PDK location.')),
    [{ label: 'Detect Again', action: () => { this.checkTools(); } }, { label: 'Close', primary: true }]);
  },

  onKey(e) {
    const mod = IS_MAC ? e.metaKey : e.ctrlKey;
    if (e.target && /^(INPUT|SELECT|TEXTAREA)$/.test(e.target.tagName)) return;
    if (mod && e.key === 'o') { e.preventDefault(); this.openFolderDialog(); } else if (mod && e.key === '1') { e.preventDefault(); this.showTab('schematic'); } else if (mod && e.key === '2') { e.preventDefault(); this.showTab('layout'); } else if (mod && e.key === ',') { e.preventDefault(); this.openSettings(); } else if (mod && e.key === 'q') { e.preventDefault(); this.requestClose(); } else if (e.key === 'F5') { e.preventDefault(); if (!this.running) this.run('synth', 'gds'); }
  },

  requestClose() {
    if (this.running) {
      const r = Host.messageBox({ type: 'question', buttons: ['Stop and Quit', 'Cancel'], defaultId: 1, message: 'A run is in progress.', detail: 'Quitting stops it.' });
      if (r !== 0) return;
      this.stop();
    }
    Host.quitConfirmed();
  },
};

window.addEventListener('DOMContentLoaded', () => App.start());
void MOD; void REVEAL_LABEL;
