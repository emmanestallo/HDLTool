'use strict';
/* global Tester, Shell, App, Host, PathUtil, Paths, Prefs, IS_WIN, IS_MAC, IS_LINUX, REVEAL_LABEL, REVEAL_SOURCE_LABEL, INSTALL_HINT, MOD, h, icon, Menus, Dialogs, showToast, copyText, splitter, replaceKeepingFocus,
   frameScheduler, keyLabel, currentTheme, THEMES, dirColor, stimColor, withAlpha, Syntax, store, TS, Inst, Stim, StimKinds, SourcePresets, LogicLiteral,
   BitsFormat, ExprEval, Fmt, TimeUnits, StimulusPreview, PinGeo, BlockLayout, SourceLayout, StimChip, pinKey, pinEq, newUUID, clone, Tools, Viewer,
   VerilogParser, Library */
// HDL Tester: the window content of the Tester tab. Port of TesterKit/Views.

const SVGNS = 'http://www.w3.org/2000/svg';
const svg = (tag, attrs = {}, ...kids) => { const e = document.createElementNS(SVGNS, tag); for (const [k, v] of Object.entries(attrs)) if (v != null) e.setAttribute(k, v); for (const c of kids) if (c) e.append(c); return e; };
const ptsAttr = (pts) => pts.map((p) => `${p.x},${p.y}`).join(' ');

const TesterUI = {
  dirty: new Set(),
  el: {},
  sidebarW: store.get('tester.sidebarWidth', 280),
  inspectorW: store.get('tester.inspectorWidth', 320),
  panelH: store.get('tester.panelHeight', 250),
  filter: '',
  drafts: new Map(),
  timeline: { zoom: 1, position: 0 },
  sourcesOpen: store.get('sourcesOpen', true),

  build(root) {
    const el = this.el;
    el.root = root;
    el.title = h('div', { class: 'titlebar' });
    el.activity = h('div', { class: 'activitybar' });
    el.sidebar = h('div', { class: 'sidebar' });
    el.sideSplit = h('div', { class: 'splitter v' });
    el.tabs = h('div', { class: 'tabbar' });
    el.canvasWrap = h('div', { class: 'canvas-wrap' });
    el.welcome = h('div', { class: 'welcome scroll' });
    el.panelSplit = h('div', { class: 'splitter h' });
    el.panel = h('div', { class: 'panel' });
    el.editorCol = h('div', { class: 'editor-col' }, el.tabs, el.canvasWrap, el.welcome, el.panelSplit, el.panel);
    el.inspSplit = h('div', { class: 'splitter v' });
    el.inspector = h('div', { class: 'inspector' });
    el.status = h('div', { class: 'statusbar' });
    root.append(el.title, h('div', { class: 'main' }, el.activity, el.sidebar, el.sideSplit, el.editorCol, el.inspSplit, el.inspector), el.status);
    splitter(el.sideSplit, 'x', (dx) => { this.sidebarW = Math.min(Math.max(this.sidebarW + dx, 200), 560); this.layout(); }, () => store.set('tester.sidebarWidth', this.sidebarW));
    splitter(el.inspSplit, 'x', (dx) => { this.inspectorW = Math.min(Math.max(this.inspectorW - dx, 260), 520); this.layout(); }, () => store.set('tester.inspectorWidth', this.inspectorW));
    splitter(el.panelSplit, 'y', (dy) => { this.panelH = Math.min(Math.max(this.panelH - dy, 120), Math.max(140, el.editorCol.clientHeight - 160)); this.layout(); }, () => store.set('tester.panelHeight', this.panelH));
    this.buildCanvas();
    this.schedule = frameScheduler(() => this.flush());
    Tester.render = (...parts) => { for (const p of parts) this.dirty.add(p); this.schedule(); };
    root.addEventListener('dragover', (e) => { if (e.dataTransfer.types.includes('Files')) { e.preventDefault(); root.classList.add('drop-target'); } });
    root.addEventListener('dragleave', (e) => { if (!root.contains(e.relatedTarget)) root.classList.remove('drop-target'); });
    root.addEventListener('drop', (e) => {
      root.classList.remove('drop-target');
      if (!e.dataTransfer.files.length) return;
      e.preventDefault();
      Tester.open([...e.dataTransfer.files].map((f) => Host.pathForFile(f)).filter(Boolean));
    });
    root.append(h('div', { class: 'drop-hint' }, icon('new-file'), ' Drop Verilog files to add their modules as DUTs'));
    Prefs.onChange(() => this.render('all'));
    Tools.onChange(() => this.render('status'));
    new ResizeObserver(() => this.render('canvas')).observe(el.canvasWrap);
  },
  render(...p) { Tester.render(...p); },

  layout() {
    const el = this.el;
    const side = !!Tester.sidebarMode;
    el.sidebar.style.display = side ? '' : 'none';
    el.sideSplit.style.display = side ? '' : 'none';
    el.sidebar.style.width = this.sidebarW + 'px';
    const doc = Tester.active;
    const insp = Tester.showInspector && !!doc;
    el.inspector.style.display = insp ? '' : 'none';
    el.inspSplit.style.display = insp ? '' : 'none';
    el.inspector.style.width = this.inspectorW + 'px';
    const panel = Tester.showPanel && !!doc;
    el.panel.style.display = panel ? '' : 'none';
    el.panelSplit.style.display = panel ? '' : 'none';
    el.panel.style.height = Math.min(this.panelH, Math.max(140, el.editorCol.clientHeight - 160)) + 'px';
    el.canvasWrap.style.display = doc ? '' : 'none';
    el.welcome.style.display = doc ? 'none' : '';
  },

  flush() {
    const d = this.dirty;
    const all = d.has('all');
    this.dirty = new Set();
    if (all) this.layout();
    if (all || d.has('title')) this.renderTitle();
    if (all || d.has('activity')) this.renderActivity();
    if (all || d.has('sidebar')) this.renderSidebar();
    if (all || d.has('tabs')) this.renderTabs();
    if (all || d.has('canvas')) this.renderCanvas();
    if (all || d.has('inspector')) this.renderInspector();
    if (all || d.has('panel')) this.renderPanel();
    if (all || d.has('status')) this.renderStatus();
    if (all) this.renderWelcome();
    App.updateWindowTitle();
  },

  // ---------------------------------------------------------------- Title bar & activity bar

  renderTitle() {
    const doc = Tester.active;
    const running = Tester.isRunning(doc);
    const enabled = doc && TS.duts(doc.state).length > 0;
    const down = doc ? Tester.descendTarget(doc) : null;
    const ib = (name, title, action, disabled) => h('button', { class: 'tb-btn codicon codicon-' + name + (disabled ? ' disabled' : ''), title, onclick: disabled ? null : action });
    this.el.title.replaceChildren(
      App.tabSwitcher(),
      h('div', { class: 'tb-spacer' }),
      h('div', { class: 'tb-title' }, doc ? `${doc.name}${doc.isDirty ? ' ●' : ''} — HDL Tester` : 'HDL Tester'),
      h('div', { class: 'tb-spacer' }),
      h('button', { class: 'run-button' + (running ? ' running' : '') + (!enabled && !running ? ' disabled' : ''),
        title: running ? `Stop the simulation (${keyLabel('Ctrl+.')})` : `Generate the testbench, compile and simulate (${keyLabel('Ctrl+R')})`,
        onclick: () => { if (!doc) return; if (running) Tester.stop(doc); else if (enabled) Tester.runActive(); } }, icon(running ? 'debug-stop' : 'play'), h('span', null, running ? 'Stop' : 'Run')),
      ib('pulse', `Open Last Waveform in HDL Viewer (${keyLabel('Ctrl+Shift+Y')})`, () => Viewer.open(doc.lastVCD), !(doc && doc.lastVCD)),
      h('div', { class: 'tb-sep' }),
      ib('debug-step-into', down ? `Descend into ${down.name} — edit ${PathUtil.basename(down.filePath)} (${keyLabel('Ctrl+Alt+Down')})` : `Descend into DUT — select a DUT first (${keyLabel('Ctrl+Alt+Down')})`, () => Tester.descendSelected(), !down),
      h('div', { class: 'tb-sep' }),
      ib(Tester.sidebarMode ? 'layout-sidebar-left' : 'layout-sidebar-left-off', `Toggle Sidebar (${keyLabel('Ctrl+B')})`, () => Tester.toggleSidebar()),
      ib(Tester.showPanel ? 'layout-panel' : 'layout-panel-off', `Toggle Panel (${keyLabel('Ctrl+J')})`, () => { Tester.showPanel = !Tester.showPanel; this.render('all'); }),
      ib(Tester.showInspector ? 'layout-sidebar-right' : 'layout-sidebar-right-off', `Toggle Inspector (${keyLabel('Ctrl+Alt+B')})`, () => { Tester.showInspector = !Tester.showInspector; this.render('all'); }),
      App.menuButton(),
      h('div', { class: 'tb-overlay-space' }));
  },

  renderActivity() {
    const item = (mode, ic, title) => h('button', { class: 'ab-item' + (Tester.sidebarMode === mode ? ' active' : ''), title, onclick: () => { Tester.sidebarMode = Tester.sidebarMode === mode ? null : mode; this.render('all'); } }, icon(ic));
    this.el.activity.replaceChildren(item('duts', 'chip', 'Available DUTs'), item('outline', 'list-tree', 'Test Outline'), h('div', { class: 'ab-spacer' }),
      h('button', { class: 'ab-item', title: 'Manage', onclick: (e) => Menus.popup([
        { label: 'Color Theme', submenu: Object.values(THEMES).map((t) => ({ label: t.name, type: 'radio', checked: Prefs.get('themeID') === t.id, action: () => Prefs.set('themeID', t.id) })) },
        { type: 'separator' },
        { label: 'Open Waveforms in HDL Viewer', type: 'checkbox', checked: Prefs.get('openResultsInViewer'), action: () => Prefs.set('openResultsInViewer', !Prefs.get('openResultsInViewer')) },
        { type: 'separator' }, { label: 'Settings…', accelerator: 'CmdOrCtrl+,', action: () => App.openSettings() }], e.currentTarget) }, icon('settings-gear')));
  },

  stimIcon(kind, size, color) {
    if (kind === 'clock') {
      const w = size * 1.25, hh = size * 0.8;
      return h('span', { class: 'stim-icon', style: `width:${size + 4}px;height:${size + 4}px`,
        html: `<svg width="${w}" height="${hh}" viewBox="0 0 10 8"><path d="M0.5 7.5 H2.5 V0.5 H5 V7.5 H7.5 V0.5 H9.5" fill="none" stroke="${color}" stroke-width="1.3" stroke-linejoin="miter"/></svg>` });
    }
    return icon(StimKinds.icon[kind], 'stim-icon', `color:${color};font-size:${size + 3}px`);
  },

  // ---------------------------------------------------------------- Sidebar

  renderSidebar() {
    const mode = Tester.sidebarMode;
    if (!mode) { this.el.sidebar.replaceChildren(); return; }
    const t = currentTheme();
    const lib = Tester.library;
    const header = h('div', { class: 'sb-title' }, h('span', null, mode === 'outline' ? 'TEST OUTLINE' : 'AVAILABLE DUTS'), h('span', { class: 'grow' }),
      ...(mode === 'outline' ? [] : [
        h('button', { class: 'icon-btn codicon codicon-new-file', title: `Open Verilog Files… (${keyLabel('Ctrl+O')})`, onclick: () => Tester.showOpenPanel() }),
        h('button', { class: 'icon-btn codicon codicon-refresh', title: 'Reload All Files', onclick: () => { for (const f of lib.files) lib.reload(f); Tester.libraryChanged(lib.files); } }),
        h('button', { class: 'icon-btn codicon codicon-collapse-all', title: 'Collapse All', onclick: () => { lib.collapsedFiles = new Set(lib.files.map((f) => f.path)); lib.expandedModules = new Set(); this.render('sidebar'); } })]));
    let body = [];
    if (mode === 'outline') body = this.outlinePane();
    else {
      const tiles = SourcePresets.all.map((p) => {
        const c = stimColor(t, SourcePresets.kind[p]);
        return h('div', { class: 'source-tile', style: `border-color:${withAlpha(c, 0.35)}`, draggable: 'true', title: `${SourcePresets.title[p]}: drag onto the canvas (or double-click), then drag from its dot to the inputs it should drive`,
          ondragstart: (e) => { e.dataTransfer.setData('text/plain', 'hdltester-source:' + p); e.dataTransfer.effectAllowed = 'copy'; },
          ondblclick: () => { if (!Tester.active) Tester.newTest(); Tester.placeSource(p, Tester.active); } },
        this.stimIcon(SourcePresets.kind[p], 10, c), h('span', null, SourcePresets.shortTitle(p)));
      });
      body.push(h('div', { class: 'section-header', onclick: () => { this.sourcesOpen = !this.sourcesOpen; store.set('sourcesOpen', this.sourcesOpen); this.render('sidebar'); } },
        icon(this.sourcesOpen ? 'chevron-down' : 'chevron-right'), h('span', null, 'SOURCES'), this.sourcesOpen ? h('span', { class: 'sub' }, 'drag onto the canvas, then wire') : null));
      if (this.sourcesOpen) body.push(h('div', { class: 'tile-grid' }, tiles));
      body.push(h('div', { class: 'hsep' }));
      if (!lib.files.length) {
        body.push(h('div', { class: 'sidebar-empty' }, h('div', null, 'No Verilog files are open yet.'), h('button', { class: 'vs-button', onclick: () => Tester.showOpenPanel() }, 'Open Verilog File'),
          h('div', { class: 'dim' }, 'Every module in the files you open shows up here as a DUT. You can also drag .v / .sv files or a folder into the window.')));
      } else {
        body.push(h('div', { class: 'pad-x' }, h('input', { class: 'vs-input', placeholder: 'Filter modules', 'data-key': 'dut-filter', value: this.filter, oninput: (e) => { this.filter = e.target.value; this.render('sidebar'); } })));
        const f = this.filter.trim().toLowerCase();
        const rows = [];
        for (const file of lib.files) {
          const mods = f ? file.modules.filter((m) => m.name.toLowerCase().includes(f)) : file.modules;
          if (f && !mods.length) continue;
          const collapsed = lib.collapsedFiles.has(file.path);
          rows.push(h('div', { class: 'trow file-row', title: file.path,
            onclick: () => { if (collapsed) lib.collapsedFiles.delete(file.path); else lib.collapsedFiles.add(file.path); this.render('sidebar'); },
            oncontextmenu: (e) => { e.preventDefault(); Menus.popup([{ label: 'Reload', action: () => { lib.reload(file); Tester.libraryChanged([file]); } },
              { label: 'Open in HDL Coder', action: () => Tester.openInCoder(file.path) }, { label: REVEAL_LABEL, action: () => Host.showInFolder(file.path) },
              { type: 'separator' }, { label: 'Remove from List', action: () => { lib.remove(file); this.render('all'); } }], e); } },
          icon(collapsed ? 'chevron-right' : 'chevron-down', 'chev'), icon('file', 'ficon'), h('span', { class: 'nm' }, PathUtil.basename(file.path)),
          h('span', { class: 'detail ellipsis-start' }, Paths.tilde(PathUtil.dirname(file.path))), h('span', { class: 'grow' }),
          file.errors.length && file.modules.length ? icon('warning', '', `color:${t.warning}`) : null,
          h('button', { class: 'icon-btn codicon codicon-close hover-only', title: 'Remove from list', onclick: (e) => { e.stopPropagation(); lib.remove(file); this.render('all'); } })));
          if (collapsed && !f) continue;
          for (const m of mods) {
            const id = m.file + '::' + m.name;
            const expanded = lib.expandedModules.has(id);
            rows.push(h('div', { class: 'trow module-row', style: 'padding-left:24px', draggable: 'true', title: `${m.name} — line ${m.line} of ${PathUtil.basename(m.file)}\nDrag onto the canvas to test it`,
              ondragstart: (e) => { e.dataTransfer.setData('text/plain', 'hdltester-dut:' + id); e.dataTransfer.effectAllowed = 'copy'; },
              ondblclick: () => Tester.placeInActive(m),
              oncontextmenu: (e) => { e.preventDefault(); Menus.popup([{ label: 'Add to Current Test', action: () => Tester.placeInActive(m) },
                { label: 'Add to New Test', action: () => { Tester.newTest(); Tester.placeInActive(m); } }, { type: 'separator' },
                { label: 'Open in HDL Coder', action: () => Tester.openInCoder(m.file, m.name, m.line) }], e); } },
            h('span', { class: `chev codicon codicon-${expanded ? 'chevron-down' : 'chevron-right'}`, onclick: (e) => { e.stopPropagation(); if (expanded) lib.expandedModules.delete(id); else lib.expandedModules.add(id); this.render('sidebar'); } }),
            icon('chip', 'ficon', `color:${dirColor(t, 'output')}`), h('span', { class: 'nm mono' }, m.name), h('span', { class: 'grow' }),
            m.warnings.length ? icon('warning', '', `color:${t.warning}`) : null,
            h('span', { class: 'detail' }, `${m.ports.filter((p) => p.dir === 'input').length} in · ${m.ports.filter((p) => p.dir !== 'input').length} out`),
            h('button', { class: 'icon-btn codicon codicon-add hover-only', title: 'Add to the current test', onclick: (e) => { e.stopPropagation(); Tester.placeInActive(m); } })));
            if (expanded) {
              for (const p of m.ports) {
                const range = p.ranges.map((r) => `[${r.msb}:${r.lsb}]`).join('');
                rows.push(h('div', { class: 'trow port-row', style: 'padding-left:52px', title: p.unsupported != null ? `Cannot be driven: ${p.unsupported}` : `${p.dir} ${p.dataType} ${range} ${p.name}` },
                  icon(p.dir === 'input' ? 'arrow-right' : (p.dir === 'output' ? 'arrow-left' : 'arrow-swap'), 'ficon', `color:${dirColor(t, p.dir)}`),
                  h('span', { class: 'nm mono' + (p.unsupported != null ? ' struck dim' : '') }, p.name), h('span', { class: 'detail mono' }, range)));
              }
            }
          }
          if (!file.modules.length) rows.push(h('div', { class: 'dim-row', style: `padding-left:30px;color:${t.warning}` }, file.errors[0] || 'No modules'));
        }
        body.push(h('div', { class: 'scroll', 'data-scroll-key': 'duts' }, rows));
        body.push(h('div', { class: 'sidebar-foot' }, 'Drag a module onto the canvas, or double-click it. Drag between pin dots to wire them.'));
      }
    }
    replaceKeepingFocus(this.el.sidebar, [header, ...body]);
  },

  outlinePane() {
    const doc = Tester.active;
    if (!doc) return [];
    const t = currentTheme();
    const st = doc.state;
    const sel = doc.selection;
    const rows = [];
    const heading = (s) => rows.push(h('div', { class: 'outline-heading' }, s));
    const row = (selected, onclick, ...kids) => rows.push(h('div', { class: 'trow' + (selected ? ' sel' : ''), onclick }, ...kids));
    const select = (s) => { doc.selection = s; this.render('all'); };
    if (TS.sources(st).length) {
      heading('SOURCES');
      for (const src of TS.sources(st)) {
        const s = Inst.stimulus(src, 'out');
        row(sel && sel.type !== 'wire' && sel.id === src.id, () => select({ type: 'instance', id: src.id }), this.stimIcon(s.kind, 9, stimColor(t, s.kind)),
          h('span', { class: 'nm mono' }, src.name), h('span', { class: 'grow' }), h('span', { class: 'detail', title: 'Number of inputs it drives' }, `→ ${TS.wiresFrom(st, { instance: src.id, pin: 'out' }).length}`));
      }
      heading('DUTS');
    }
    for (const inst of TS.duts(st)) {
      row(sel && sel.type === 'instance' && sel.id === inst.id, () => select({ type: 'instance', id: inst.id }), icon('chip', 'ficon', `color:${dirColor(t, 'output')}`),
        h('span', { class: 'nm mono' }, inst.name), h('span', { class: 'detail' }, inst.moduleName));
      for (const p of inst.ports) {
        const d = TS.wireTo(st, { instance: inst.id, pin: p.name });
        rows.push(h('div', { class: 'trow' + (sel && sel.type === 'pin' && sel.id === inst.id && sel.pin === p.name ? ' sel' : ''), style: 'padding-left:30px', onclick: () => select({ type: 'pin', id: inst.id, pin: p.name }) },
          icon(p.dir === 'output' ? 'arrow-left' : 'arrow-right', 'ficon', `color:${dirColor(t, p.dir)}`), h('span', { class: 'nm mono' }, p.name), h('span', { class: 'grow' }),
          d ? h('span', { class: 'detail mono' }, '← ' + TS.describe(st, d.from)) : (p.dir === 'input' && p.unsupported == null ? h('span', { class: 'detail', style: `color:${t.warning}` }, 'not wired')
            : (inst.logged.includes(p.name) ? icon('list-flat', 'dim') : null))));
      }
    }
    if (st.wires.length) {
      heading('WIRES');
      for (const w of st.wires) {
        row(sel && sel.type === 'wire' && sel.id === w.id, () => select({ type: 'wire', id: w.id }), h('span', { class: 'mono small' }, TS.describe(st, w.from)), icon('arrow-right', 'dim small'), h('span', { class: 'mono small' }, TS.describe(st, w.to)));
      }
    }
    if (!st.instances.length) rows.push(h('div', { class: 'dim-pad' }, 'This test has no DUTs yet.'));
    return [h('div', { class: 'scroll', 'data-scroll-key': 'outline' }, rows)];
  },

  // ---------------------------------------------------------------- Tabs

  renderTabs() {
    const t = currentTheme();
    if (!Tester.tests.length) { this.el.tabs.style.display = 'none'; return; }
    this.el.tabs.style.display = '';
    const tabs = Tester.tests.map((doc) => {
      const active = doc.id === Tester.activeID;
      const st = doc.status.kind;
      const statusIcon = st === 'compiling' || st === 'simulating' ? icon('loading', 'spin') : st === 'passed' ? icon('pass-filled', '', `color:${t.success}`)
        : st === 'failed' ? icon('error', '', `color:${t.error}`) : icon('beaker', '', `color:${t.wave1}`);
      return h('div', { class: 'tab' + (active ? ' active' : '') + (doc.isDirty ? ' dirty' : ''), title: doc.filePath || 'Not saved yet',
        onmousedown: (e) => { if (e.button === 1) { e.preventDefault(); Tester.close(doc); } },
        onclick: () => { Tester.activeID = doc.id; this.render('all'); },
        oncontextmenu: (e) => { e.preventDefault(); Menus.popup([{ label: 'Save', action: () => Tester.save(doc, false) }, { label: 'Save As…', action: () => Tester.save(doc, true) }, { type: 'separator' }, { label: 'Close', action: () => Tester.close(doc) }], e); } },
      statusIcon, h('span', { class: 'tab-name' }, doc.name), h('span', { class: 'tab-count', title: `${TS.duts(doc.state).length} DUTs` }, TS.duts(doc.state).length),
      h('button', { class: 'tab-close', title: `Close (${keyLabel('Ctrl+Shift+W')})`, onclick: (e) => { e.stopPropagation(); Tester.close(doc); } }, h('span', { class: 'dot' }), icon('close')));
    });
    this.el.tabs.replaceChildren(h('div', { class: 'tab-strip' }, tabs), h('button', { class: 'icon-btn codicon codicon-add tab-add', title: `New Test (${keyLabel('Ctrl+N')})`, onclick: () => Tester.newTest() }));
  },

  // ---------------------------------------------------------------- Canvas

  buildCanvas() {
    const el = this.el;
    el.scroller = h('div', { class: 'canvas-scroller' });
    el.sizer = h('div', { class: 'canvas-sizer' });
    el.stage = h('div', { class: 'canvas-stage' });
    el.wires = svg('svg', { class: 'wire-layer' });
    el.blocks = h('div', { class: 'block-layer' });
    el.pending = svg('svg', { class: 'wire-layer pending' });
    el.stage.append(el.wires, el.blocks, el.pending);
    el.sizer.append(el.stage);
    el.scroller.append(el.sizer);
    el.emptyHint = h('div', { class: 'canvas-empty' });
    el.addSource = h('button', { class: 'canvas-chip add-source', title: 'Add a clock, reset or other source that can be wired to several DUT inputs',
      onclick: (e) => { const doc = Tester.active; if (doc) Menus.popup(SourcePresets.all.map((p) => ({ label: SourcePresets.title[p], action: () => Tester.placeSource(p, doc) })), e.currentTarget); } }, icon('add'), 'Add Source');
    el.zoomCtl = h('div', { class: 'canvas-chip zoom-ctl' });
    el.canvasWrap.append(el.scroller, el.emptyHint, el.addSource, el.zoomCtl);

    const toCanvas = (e) => { const r = el.stage.getBoundingClientRect(); const z = Tester.active ? Tester.active.zoom : 1; return { x: (e.clientX - r.left) / z, y: (e.clientY - r.top) / z }; };
    this.toCanvas = toCanvas;
    el.stage.addEventListener('mousedown', (e) => {
      if (e.button !== 0 || (e.target !== el.stage && e.target !== el.wires && e.target.parentNode !== el.wires)) return;
      const doc = Tester.active;
      if (!doc) return;
      const p = toCanvas(e);
      const w = PinGeo.wireAt(p, doc.state, 6 / Math.min(doc.zoom, 1));
      doc.selection = w ? { type: 'wire', id: w } : null;
      this.render('all');
    });
    el.scroller.addEventListener('wheel', (e) => {
      const doc = Tester.active;
      if (!doc || !(e.ctrlKey || e.metaKey)) return;
      e.preventDefault();
      doc.zoom = Math.min(2, Math.max(0.4, doc.zoom * Math.exp(-e.deltaY * 0.0025)));
      this.render('canvas');
    }, { passive: false });
    el.stage.addEventListener('dragover', (e) => { if (e.dataTransfer.types.includes('text/plain')) { e.preventDefault(); el.canvasWrap.classList.add('drop-on'); } });
    el.stage.addEventListener('dragleave', () => el.canvasWrap.classList.remove('drop-on'));
    el.stage.addEventListener('drop', (e) => {
      el.canvasWrap.classList.remove('drop-on');
      const s = e.dataTransfer.getData('text/plain');
      const doc = Tester.active;
      if (!s || !doc) return;
      e.preventDefault();
      e.stopPropagation();
      const p = toCanvas(e);
      if (s.startsWith('hdltester-dut:')) {
        const id = s.slice('hdltester-dut:'.length);
        const m = Tester.library.modules.find((x) => x.file + '::' + x.name === id);
        if (m) Tester.place(m, doc, p);
      } else if (s.startsWith('hdltester-source:')) Tester.placeSource(s.slice('hdltester-source:'.length), doc, p);
    });
  },

  canvasSize(doc) {
    const z = doc.zoom;
    let w = this.el.canvasWrap.clientWidth / z, hh = this.el.canvasWrap.clientHeight / z;
    for (const inst of doc.state.instances) { w = Math.max(w, inst.x + 700); hh = Math.max(hh, inst.y + 500); }
    return { w: Math.max(w, 1200), h: Math.max(hh, 800) };
  },

  renderCanvas() {
    const doc = Tester.active;
    const el = this.el;
    if (!doc) return;
    const t = currentTheme();
    const size = this.canvasSize(doc);
    el.sizer.style.width = size.w * doc.zoom + 'px';
    el.sizer.style.height = size.h * doc.zoom + 'px';
    el.stage.style.width = size.w + 'px';
    el.stage.style.height = size.h + 'px';
    el.stage.style.transform = `scale(${doc.zoom})`;
    for (const s of [el.wires, el.pending]) { s.setAttribute('width', size.w); s.setAttribute('height', size.h); }
    if (this.lastDoc !== doc.id) { this.lastDoc = doc.id; el.scroller.scrollTop = doc.scroll.y; el.scroller.scrollLeft = doc.scroll.x; }
    el.scroller.onscroll = () => { doc.scroll = { x: el.scroller.scrollLeft, y: el.scroller.scrollTop }; };
    const gen = Tester.generated(doc);
    const badPins = new Set(gen.problems.filter((p) => p.severity === 'error' && p.instance).map((p) => `${p.instance}.${p.pin || ''}`));
    el.blocks.replaceChildren(...doc.state.instances.map((inst) => (Inst.isSource(inst) ? this.sourceBlock(doc, inst, badPins.has(`${inst.id}.out`)) : this.dutBlock(doc, inst, badPins))));
    this.drawWires(doc);
    this.drawPending(doc);
    // Overlays
    el.zoomCtl.replaceChildren(
      h('button', { class: 'icon-btn codicon codicon-remove', title: `Zoom Out (${keyLabel('Ctrl+-')})`, onclick: () => Tester.zoom(1 / 1.25) }),
      h('button', { class: 'zoom-label', title: `Actual Size (${keyLabel('Ctrl+0')})`, onclick: () => Tester.zoom(0) }, `${Math.round(doc.zoom * 100)}%`),
      h('button', { class: 'icon-btn codicon codicon-add', title: `Zoom In (${keyLabel('Ctrl+=')})`, onclick: () => Tester.zoom(1.25) }));
    const empty = !TS.duts(doc.state).length;
    el.emptyHint.style.display = empty ? '' : 'none';
    if (empty) {
      el.emptyHint.style.pointerEvents = Tester.library.files.length ? 'none' : 'auto';
      el.emptyHint.replaceChildren(h('div', { class: 'empty-box' }, icon('inspect', 'big'),
        Tester.library.files.length ? [h('div', { class: 'em1' }, 'Drag a DUT from Available DUTs and drop it here'), h('div', { class: 'em2' }, 'Double-clicking a module also adds it. Drag from a pin\'s dot to another pin to wire them.')]
          : [h('div', { class: 'em1' }, 'Open a Verilog file to see its modules under Available DUTs'), h('span', { class: 'link', onclick: () => Tester.showOpenPanel() }, `Open Verilog File…  ${keyLabel('Ctrl+O')}`)]));
    }
    void t;
  },

  // Begins moving a block with the mouse; commits the snapped position on release.
  startMove(e, doc, inst, minX, minY, blockEl) {
    if (e.button !== 0) return;
    e.preventDefault();
    const start = this.toCanvas(e);
    let moved = false;
    const move = (ev) => {
      const p = this.toCanvas(ev);
      const dx = p.x - start.x, dy = p.y - start.y;
      if (!moved && Math.hypot(dx, dy) * doc.zoom < 3) return;
      if (!moved) { moved = true; blockEl.classList.add('dragging'); if (!doc.selection || doc.selection.id !== inst.id) { doc.selection = { type: 'instance', id: inst.id }; this.render('inspector', 'title', 'sidebar'); } }
      doc.dragging = { id: inst.id, dx, dy };
      blockEl.style.translate = `${dx}px ${dy}px`;
      this.drawWires(doc);
    };
    const up = () => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      if (!moved) { doc.selection = { type: 'instance', id: inst.id }; this.render('all'); return; }
      const snap = (v) => Math.round(v / 10) * 10;
      const d = doc.dragging;
      doc.dragging = null;
      const nx = Math.max(minX, snap(inst.x + d.dx)), ny = Math.max(minY, snap(inst.y + d.dy));
      if (nx !== inst.x || ny !== inst.y) doc.edit((s) => { const i = s.instances.find((x) => x.id === inst.id); if (i) { i.x = nx; i.y = ny; } });
      else this.render('canvas');
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  },

  // Drag from a pin's dot to another pin to make a wire.
  startWire(e, doc, ref, isOutput) {
    if (e.button !== 0) return;
    e.preventDefault();
    e.stopPropagation();
    const move = (ev) => {
      const p = this.toCanvas(ev);
      doc.pendingWire = { start: ref, startIsOutput: isOutput, point: p, target: PinGeo.target(doc.state, p, !isOutput, ref) };
      this.drawPending(doc);
    };
    const up = () => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      const pw = doc.pendingWire;
      doc.pendingWire = null;
      this.drawPending(doc);
      if (pw && pw.target) { if (pw.startIsOutput) doc.connect(pw.start, pw.target); else doc.connect(pw.target, pw.start); this.render('all'); }
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  },

  dot(doc, ref, isOutput, color, connected) {
    const t = currentTheme();
    const d = h('div', { class: 'conn-dot' + (connected ? ' connected' : ''), title: isOutput ? 'Drag to an input pin to wire it' : 'Drag to an output or source to wire this input',
      style: `--c:${color};--bg:${t.editor}`, onmousedown: (e) => this.startWire(e, doc, ref, isOutput) }, h('span'));
    return d;
  },

  wireColor(doc, from) {
    const t = currentTheme();
    const inst = TS.instance(doc.state, from.instance);
    return inst && Inst.isSource(inst) ? stimColor(t, Inst.stimulus(inst, 'out').kind) : dirColor(t, 'output');
  },

  stubSvg(w, hh, rows) {
    const s = svg('svg', { class: 'stub-layer', width: w, height: hh });
    for (const r of rows) {
      s.append(svg('line', { x1: r.x0, y1: r.y, x2: r.x1, y2: r.y, stroke: r.color, 'stroke-opacity': 0.9, 'stroke-width': r.bus ? 3 : 1.5 }));
      if (r.bus) {
        const mx = r.x0 + 10;
        s.append(svg('line', { x1: mx - 3.5, y1: r.y + 5, x2: mx + 3.5, y2: r.y - 5, stroke: r.color, 'stroke-width': 1.2 }));
        const tx = svg('text', { x: mx + 4, y: r.y - 4, fill: r.color, class: 'bus-width' });
        tx.textContent = String(r.bus);
        s.append(tx);
      }
    }
    return s;
  },

  dutBlock(doc, inst, badPins) {
    const t = currentTheme();
    const env = Inst.paramValues(inst);
    const L = BlockLayout.make(inst, env);
    const st = doc.state;
    const sel = doc.selection;
    const instSelected = sel && sel.type !== 'wire' && sel.id === inst.id;
    const selectedPin = sel && sel.type === 'pin' && sel.id === inst.id ? sel.pin : null;
    const drivers = new Map();
    for (const p of Inst.inputs(inst)) { const w = TS.wireTo(st, { instance: inst.id, pin: p.name }); if (w) drivers.set(p.name, w.from); }
    const stubColor = (p) => {
      if (badPins.has(`${inst.id}.${p.name}`)) return t.error;
      const d = drivers.get(p.name);
      if (d) return this.wireColor(doc, d);
      return t.pin;
    };
    const rows = L.left.map((p, i) => { const r = Inst.resolve(inst, p, env); const w = r ? r.width : null; return { y: BlockLayout.rowY(i), x0: L.leftW - BlockLayout.stub, x1: L.leftW, bus: (w ?? 2) > 1 ? w : null, color: stubColor(p) }; })
      .concat(L.right.map((p, i) => { const r = Inst.resolve(inst, p, env); const w = r ? r.width : null; return { y: BlockLayout.rowY(i), x0: L.leftW + L.boxW, x1: L.leftW + L.boxW + BlockLayout.stub, bus: (w ?? 2) > 1 ? w : null, color: p.dir === 'inout' ? dirColor(t, 'inout') : t.pin }; }));
    const missing = !Host.fs.exists(inst.filePath);
    const unsupported = inst.ports.some((p) => p.unsupported != null);
    const block = h('div', { class: 'block dut', style: `left:${inst.x - L.leftW}px;top:${inst.y - BlockLayout.labelH}px;width:${L.totalW}px;height:${L.totalH}px` });
    const box = h('div', { class: 'block-box' + (instSelected ? ' selected' : ''), style: `left:${L.leftW}px;top:${BlockLayout.labelH}px;width:${L.boxW}px;height:${L.boxH}px`,
      title: `${inst.moduleName} — double-click to descend and edit ${PathUtil.basename(inst.filePath)}`,
      onmousedown: (e) => this.startMove(e, doc, inst, L.leftW, BlockLayout.labelH + 4, block),
      ondblclick: () => Tester.descend(inst, doc),
      oncontextmenu: (e) => { e.preventDefault(); this.blockMenu(doc, inst, e); } },
    h('div', { class: 'block-header' }, icon('chip', '', `color:${dirColor(t, 'output')}`), h('span', { class: 'block-title' }, inst.moduleName), h('span', { class: 'grow' }),
      missing ? icon('warning', '', `color:${t.error}`) : (unsupported ? icon('warning', '', `color:${t.warning}`) : null)));
    block.append(this.stubSvg(L.totalW, L.totalH, rows),
      h('div', { class: 'block-label' + (instSelected ? ' on' : ''), style: `left:${L.leftW + 2}px;width:${L.boxW}px` }, inst.name), box);
    const pinLabel = (p) => h('span', { class: 'pin-label' + (p.unsupported != null ? ' unsupported' : '') }, h('span', { class: 'pn' }, p.name),
      L.rangeLabels[p.name] ? h('span', { class: 'pr' }, L.rangeLabels[p.name]) : null);
    const help = (p, d) => {
      let s = `${p.name} — ${p.dir}`;
      if (d) s += `\nWired from ${TS.describe(st, d)}`; else if (p.dir === 'input' && p.unsupported == null) s += '\nNot wired: drag from its dot to a source or a DUT output';
      if (p.unsupported != null) s += `\nNot connected: ${p.unsupported}`;
      return s;
    };
    L.left.forEach((p, i) => {
      const y = BlockLayout.rowY(i) - BlockLayout.rowH / 2;
      block.append(h('div', { class: 'pin-row in' + (selectedPin === p.name ? ' sel' : ''), style: `left:0;top:${y}px;width:${L.leftW + L.boxW / 2}px;--sel-left:${L.leftW + 1}px;--sel-w:${L.boxW - 2}px`,
        title: help(p, drivers.get(p.name)),
        onmousedown: (e) => { if (e.button === 0) { e.stopPropagation(); doc.selection = { type: 'pin', id: inst.id, pin: p.name }; this.render('all'); } },
        oncontextmenu: (e) => { e.preventDefault(); this.inputMenu(doc, inst, p, drivers.get(p.name), e); } },
      h('span', { class: 'pin-label-wrap', style: `left:${L.leftW + BlockLayout.pad}px` }, pinLabel(p))));
    });
    L.right.forEach((p, i) => {
      const y = BlockLayout.rowY(i) - BlockLayout.rowH / 2;
      const x0 = L.leftW + L.boxW / 2;
      block.append(h('div', { class: 'pin-row out' + (selectedPin === p.name ? ' sel' : ''), style: `left:${x0}px;top:${y}px;width:${L.totalW - x0}px;--sel-right:${L.rightW + 1}px;--sel-w:${L.boxW - 2}px`,
        title: help(p, null),
        onmousedown: (e) => { if (e.button === 0) { e.stopPropagation(); doc.selection = { type: 'pin', id: inst.id, pin: p.name }; this.render('all'); } },
        oncontextmenu: (e) => { e.preventDefault(); this.outputMenu(doc, inst, p, e); } },
      h('span', { class: 'pin-label-wrap right', style: `right:${L.rightW + BlockLayout.pad}px` }, pinLabel(p)),
      inst.logged.includes(p.name) ? h('span', { class: 'logged-badge', title: 'Value changes are printed in the Output panel' }, icon('list-flat')) : null));
    });
    L.left.forEach((p, i) => {
      if (p.unsupported != null) return;
      const d = this.dot(doc, { instance: inst.id, pin: p.name }, false, stubColor(p), drivers.has(p.name));
      d.style.left = (L.leftW - BlockLayout.stub - 9) + 'px'; d.style.top = (BlockLayout.rowY(i) - 9) + 'px';
      block.append(d);
    });
    L.right.forEach((p, i) => {
      if (p.unsupported != null || p.dir !== 'output') return;
      const ref = { instance: inst.id, pin: p.name };
      const d = this.dot(doc, ref, true, dirColor(t, 'output'), TS.wiresFrom(st, ref).length > 0);
      d.style.left = (L.leftW + L.boxW + BlockLayout.stub - 9) + 'px'; d.style.top = (BlockLayout.rowY(i) - 9) + 'px';
      block.append(d);
    });
    return block;
  },

  sourceBlock(doc, inst, bad) {
    const t = currentTheme();
    const L = SourceLayout.make(inst);
    const stim = Inst.stimulus(inst, 'out');
    const color = bad ? t.error : stimColor(t, stim.kind);
    const selected = doc.selection && doc.selection.type !== 'wire' && doc.selection.id === inst.id;
    const w = Inst.sourceWidth(inst);
    const ref = { instance: inst.id, pin: 'out' };
    const block = h('div', { class: 'block source', style: `left:${inst.x}px;top:${inst.y}px;width:${L.boxW + SourceLayout.stub + 12}px;height:${L.boxH}px` });
    const summary = Stim.summary(stim);
    const chip = h('span', { class: 'stim-chip' + (selected ? ' selected' : '') + (bad ? ' invalid' : ''), style: `--c:${color}` }, this.stimIcon(stim.kind, 9, color),
      h('span', null, summary.length > 12 ? summary.slice(0, 11) + '…' : summary));
    const box = h('div', { class: 'source-box' + (selected ? ' selected' : ''), style: `width:${L.boxW}px;height:${L.boxH}px;--c:${color}`,
      title: `Source ${inst.name}: ${StimKinds.title[stim.kind]}, ${w} bit${w === 1 ? '' : 's'}`,
      onmousedown: (e) => this.startMove(e, doc, inst, 10, 10, block),
      oncontextmenu: (e) => {
        e.preventDefault();
        const inputs = TS.inputPins(doc.state);
        Menus.popup([{ label: 'Wire To', enabled: inputs.length > 0, submenu: inputs.map((tp) => ({ label: TS.describe(doc.state, tp), action: () => { doc.connect(ref, tp); this.render('all'); } })) },
          { type: 'separator' }, { label: 'Duplicate', action: () => { doc.duplicateInstance(inst.id); this.render('all'); } }, { label: 'Delete Source', action: () => { doc.removeInstance(inst.id); this.render('all'); } }], e);
      } },
    h('div', { class: 'source-header' }, this.stimIcon(stim.kind, 10, color), h('span', { class: 'source-name' }, inst.name)),
    h('div', { class: 'source-row' }, chip));
    const stub = this.stubSvg(L.boxW + SourceLayout.stub + 12, L.boxH, [{ y: SourceLayout.pinY, x0: L.boxW, x1: L.boxW + SourceLayout.stub, bus: w > 1 ? w : null, color }]);
    const d = this.dot(doc, ref, true, color, TS.wiresFrom(doc.state, ref).length > 0);
    d.style.left = (L.boxW + SourceLayout.stub - 9) + 'px'; d.style.top = (SourceLayout.pinY - 9) + 'px';
    block.append(stub, box, d);
    return block;
  },

  drawWires(doc) {
    const t = currentTheme();
    const el = this.el.wires;
    const pins = PinGeo.allPins(doc.state, doc.dragging);
    const sel = doc.selection;
    const selWire = sel && sel.type === 'wire' ? sel.id : null;
    const selInst = sel && sel.type !== 'wire' ? sel.id : null;
    const routed = PinGeo.routeAll(doc.state, pins, doc.dragging);
    const kids = [];
    const items = routed.map((r) => ({ r, color: this.wireColor(doc, r.wire.from), width: (r.width ?? 1) > 1 ? 3 : 1.6,
      hot: r.wire.id === selWire || r.wire.from.instance === selInst || r.wire.to.instance === selInst }));
    for (const it of items) if (!it.hot) kids.push(svg('polyline', { points: ptsAttr(it.r.points), fill: 'none', stroke: it.color, 'stroke-opacity': 0.85, 'stroke-width': it.width, 'stroke-linecap': 'square', 'stroke-linejoin': 'miter' }));
    for (const it of items) {
      if (!it.hot) continue;
      kids.push(svg('polyline', { points: ptsAttr(it.r.points), fill: 'none', stroke: t.focusBorder, 'stroke-opacity': 0.35, 'stroke-width': it.width + 5, 'stroke-linecap': 'square', 'stroke-linejoin': 'miter' }));
      kids.push(svg('polyline', { points: ptsAttr(it.r.points), fill: 'none', stroke: it.color, 'stroke-width': it.width + 0.5, 'stroke-linecap': 'square', 'stroke-linejoin': 'miter' }));
    }
    for (const it of items) {
      const a = it.r.points[0], b = it.r.points[it.r.points.length - 1];
      kids.push(svg('circle', { cx: a.x, cy: a.y, r: 3.5, fill: it.color }), svg('circle', { cx: b.x, cy: b.y, r: 3.5, fill: it.color }));
      const rr = it.width > 2 ? 4 : 3;
      for (const j of it.r.junctions) kids.push(svg('circle', { cx: j.x, cy: j.y, r: rr, fill: it.color }));
    }
    el.replaceChildren(...kids);
  },

  drawPending(doc) {
    const el = this.el.pending;
    const pw = doc.pendingWire;
    if (!pw) { el.replaceChildren(); return; }
    const t = currentTheme();
    const pins = PinGeo.allPins(doc.state, null);
    const sp = pins.get(pinKey(pw.start));
    if (!sp) { el.replaceChildren(); return; }
    const tp = pw.target ? pins.get(pinKey(pw.target)) : null;
    const end = tp ? tp.point : pw.point;
    const rects = PinGeo.obstacles(doc.state, null);
    const pts = pw.startIsOutput ? PinGeo.smartRoute(sp.point, end, rects) : PinGeo.smartRoute(end, sp.point, rects);
    const kids = [svg('polyline', { points: ptsAttr(pts), fill: 'none', stroke: t.focusBorder, 'stroke-width': 2, 'stroke-linejoin': 'miter', 'stroke-dasharray': pw.target ? null : '6 4' })];
    if (tp) {
      kids.push(svg('circle', { cx: tp.point.x, cy: tp.point.y, r: 8, fill: 'none', stroke: t.focusBorder, 'stroke-width': 2 }));
      kids.push(svg('rect', { x: tp.rowRect.x, y: tp.rowRect.y + 1, width: tp.rowRect.w, height: tp.rowRect.h - 2, fill: withAlpha(t.focusBorder, 0.12) }));
    }
    el.replaceChildren(...kids);
  },

  blockMenu(doc, inst, e) {
    const st = doc.state;
    const unwired = Inst.inputs(inst).filter((p) => p.unsupported == null && !TS.wireTo(st, { instance: inst.id, pin: p.name }));
    const items = [{ label: `Descend into ${inst.moduleName} (Edit Source)`, action: () => Tester.descend(inst, doc) }, { type: 'separator' },
      { label: `Add Sources for Unwired Inputs (${unwired.length})`, enabled: unwired.length > 0, action: () => { doc.addSourcesForUnwiredInputs(inst.id); this.render('all'); } },
      { type: 'separator' }, { label: 'Duplicate', action: () => { doc.duplicateInstance(inst.id); this.render('all'); } }, { label: 'Remove from Test', action: () => { doc.removeInstance(inst.id); this.render('all'); } }];
    if (st.wires.some((w) => w.from.instance === inst.id || w.to.instance === inst.id)) items.push({ label: 'Remove All Its Wires', action: () => doc.edit((s) => { s.wires = s.wires.filter((w) => w.from.instance !== inst.id && w.to.instance !== inst.id); }) });
    items.push({ type: 'separator' }, { label: REVEAL_SOURCE_LABEL, action: () => Host.showInFolder(inst.filePath) });
    Menus.popup(items, e);
  },
  inputMenu(doc, inst, p, driver, e) {
    const ref = { instance: inst.id, pin: p.name };
    const drivers = TS.driverPins(doc.state);
    const items = [{ label: 'Wire From', enabled: drivers.length > 0, submenu: drivers.map((d) => ({ label: TS.describe(doc.state, d), action: () => { doc.connect(d, ref); this.render('all'); } })) },
      { label: 'New Source', submenu: SourcePresets.all.map((pr) => ({ label: SourcePresets.title[pr], action: () => { const id = doc.addSource(pr, ref); if (id) doc.selection = { type: 'instance', id }; this.render('all'); } })) }];
    if (driver) items.push({ label: 'Disconnect Wire', action: () => doc.disconnect(ref) });
    Menus.popup(items, e);
  },
  outputMenu(doc, inst, p, e) {
    const logged = inst.logged.includes(p.name);
    const ref = { instance: inst.id, pin: p.name };
    const items = [];
    if (p.dir === 'output') {
      const inputs = TS.inputPins(doc.state);
      items.push({ label: 'Wire To', enabled: inputs.length > 0, submenu: inputs.map((tp) => ({ label: TS.describe(doc.state, tp), action: () => { doc.connect(ref, tp); this.render('all'); } })) });
      if (TS.wiresFrom(doc.state, ref).length) items.push({ label: 'Remove Its Wires', action: () => doc.edit((s) => { s.wires = s.wires.filter((w) => !pinEq(w.from, ref)); }) });
      items.push({ type: 'separator' });
    }
    items.push({ label: logged ? 'Stop Printing Changes' : 'Print Changes in Output', action: () => doc.edit((s) => {
      const i = s.instances.find((x) => x.id === inst.id);
      if (!i) return;
      if (logged) i.logged = i.logged.filter((x) => x !== p.name); else i.logged.push(p.name);
    }) });
    Menus.popup(items, e);
  },

  // ---------------------------------------------------------------- Stimulus wave drawing

  drawStimWave(canvas, segs, horizon, color, start = 0) {
    const t = currentTheme();
    const dpr = window.devicePixelRatio || 1;
    const w = canvas.clientWidth, hh = canvas.clientHeight;
    canvas.width = Math.round(w * dpr); canvas.height = Math.round(hh * dpr);
    const ctx = canvas.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, hh);
    if (!(horizon > start) || !segs.length || !w) return;
    const top = 4, bot = hh - 4, mid = hh / 2, span = horizon - start;
    const X = (tt) => (tt - start) / span * w;
    const isBus = segs.some((s) => s.level === 'bus');
    ctx.font = '9.5px "Cascadia Mono", Consolas, "SF Mono", monospace';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    const line = new Path2D();
    let lastY = null, started = false;
    for (let i = 0; i < segs.length; i++) {
      const s = segs[i];
      const x0 = Math.max(0, X(s.t));
      const x1 = Math.min(w, i + 1 < segs.length ? X(segs[i + 1].t) : w);
      if (x1 < 0) continue;
      if (x0 > w) break;
      if (isBus || s.level === 'bus') {
        const slant = Math.min(3, Math.max(0, (x1 - x0) / 2));
        const p = new Path2D();
        p.moveTo(x0, mid); p.lineTo(x0 + slant, top); p.lineTo(x1 - slant, top); p.lineTo(x1, mid); p.lineTo(x1 - slant, bot); p.lineTo(x0 + slant, bot); p.closePath();
        const c = s.level === 'x' ? t.waveX : (s.level === 'z' ? t.waveZ : color);
        ctx.fillStyle = withAlpha(c, s.level === 'x' ? 0.28 : 0.12); ctx.fill(p);
        ctx.strokeStyle = c; ctx.lineWidth = 1.2; ctx.stroke(p);
        if (x1 - x0 > s.label.length * 6.2 + 10) { ctx.fillStyle = t.fg; ctx.fillText(s.label, (x0 + x1) / 2, mid + 0.5); }
        continue;
      }
      const y = s.level === 'high' ? top : s.level === 'low' ? bot : mid;
      if (started) { line.lineTo(x0, lastY); line.lineTo(x0, y); } else { line.moveTo(x0, y); started = true; }
      lastY = y;
      if (s.level === 'x') { ctx.fillStyle = withAlpha(t.waveX, 0.25); ctx.fillRect(x0, top, x1 - x0, bot - top); }
      else if (s.level === 'z') { ctx.strokeStyle = t.waveZ; ctx.lineWidth = 1.5; ctx.beginPath(); ctx.moveTo(x0, mid); ctx.lineTo(x1, mid); ctx.stroke(); }
      if (i === segs.length - 1 || x1 >= w) line.lineTo(x1, y);
    }
    if (!isBus) { ctx.strokeStyle = color; ctx.lineWidth = 1.5; ctx.lineJoin = 'miter'; ctx.stroke(line); }
  },
  tickStep(span, maxTicks) {
    if (!(span > 0) || maxTicks <= 0) return 1;
    const raw = span / maxTicks;
    const mag = Math.pow(10, Math.floor(Math.log10(raw)));
    for (const m of [1, 2, 5, 10]) if (mag * m >= raw) return mag * m;
    return mag * 10;
  },
  drawRuler(canvas, start, end, unit, zeroLabel) {
    const t = currentTheme();
    const dpr = window.devicePixelRatio || 1;
    const w = canvas.clientWidth, hh = canvas.clientHeight;
    canvas.width = Math.round(w * dpr); canvas.height = Math.round(hh * dpr);
    const ctx = canvas.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, hh);
    const span = end - start;
    if (!(span > 0) || !w) return;
    const step = this.tickStep(span, Math.max(1, Math.floor(w / 90)));
    ctx.font = '10px "Cascadia Mono", Consolas, "SF Mono", monospace';
    ctx.textBaseline = 'middle';
    for (let tt = Math.ceil(start / step) * step; tt <= end + step * 0.001; tt += step) {
      const x = (tt - start) / span * w;
      ctx.strokeStyle = t.border; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(x, hh - 5); ctx.lineTo(x, hh); ctx.stroke();
      const label = Fmt.num(tt) + (tt === 0 && zeroLabel ? '' : ' ' + unit);
      ctx.fillStyle = t.dimFG;
      const right = x > w - (zeroLabel ? 40 : 50);
      ctx.textAlign = right ? 'right' : 'left';
      ctx.fillText(label, right ? Math.min(x - 3, w - 2) : Math.max(x + 3, 0), hh / 2 - 1);
    }
  },

  // ---------------------------------------------------------------- Inspector

  renderInspector() {
    const doc = Tester.active;
    if (!doc || !Tester.showInspector) return;
    const sel = doc.selection;
    let title = 'TEST SETTINGS', body;
    const st = doc.state;
    if (sel && sel.type === 'wire') {
      const w = st.wires.find((x) => x.id === sel.id);
      title = 'WIRE';
      body = w ? this.wireInspector(doc, w) : [];
    } else if (sel) {
      const inst = TS.instance(st, sel.id);
      if (!inst) body = this.testSettings(doc);
      else if (Inst.isSource(inst)) { title = 'SOURCE'; body = this.sourceInspector(doc, inst); }
      else if (sel.type === 'pin') {
        title = 'PIN';
        const port = inst.ports.find((p) => p.name === sel.pin);
        body = port ? this.pinInspector(doc, inst, port) : [];
      } else { title = 'DUT'; body = this.instanceInspector(doc, inst); }
    } else body = this.testSettings(doc);
    const key = sel ? JSON.stringify(sel) : 'settings';
    if (this.inspectorKey !== key) { this.drafts.clear(); this.inspectorKey = key; }
    replaceKeepingFocus(this.el.inspector, [
      h('div', { class: 'sb-title' }, h('span', null, title), h('span', { class: 'grow' }),
        sel ? h('button', { class: 'icon-btn codicon codicon-settings-gear', title: 'Test Settings', onclick: () => { doc.selection = null; this.render('all'); } }) : null),
      h('div', { class: 'scroll inspector-body', 'data-scroll-key': 'insp' }, body)]);
  },

  // ---- form controls
  propRow(label, control, labelWidth = 92) { return h('div', { class: 'prop-row' }, h('div', { class: 'prop-label', style: `width:${labelWidth}px`, title: label }, label), h('div', { class: 'prop-control' }, control)); },
  heading(text) { return h('div', { class: 'insp-heading' }, text); },
  note(text, cls = '') { return h('div', { class: 'insp-note ' + cls }, text); },
  notice(ic, color, text) { return h('div', { class: 'notice', style: `--c:${color}` }, icon(ic, '', `color:${color}`), h('span', null, text)); },
  button(title, ic, action, secondary = true, extra = {}) {
    return h('button', Object.assign({ class: 'vs-button' + (secondary ? ' secondary' : '') + ' full', onclick: action }, extra), ic ? icon(ic) : null, h('span', null, title));
  },
  checkbox(title, on, set) {
    return h('label', { class: 'vs-check' }, h('input', { type: 'checkbox', checked: on, onchange: (e) => set(e.target.checked) }), h('span', null, title));
  },
  textField(key, value, set, { placeholder = '', mono = false, invalid = false, commitInvalid = true, width = null } = {}) {
    const draft = this.drafts.get(key);
    return h('input', { class: 'vs-input' + (mono ? ' mono' : '') + (invalid ? ' invalid' : ''), spellcheck: 'false', 'data-key': key, placeholder, value: draft != null ? draft : value,
      style: width ? `width:${width}px` : null,
      oninput: (e) => { this.drafts.set(key, e.target.value); if (commitInvalid) set(e.target.value); else set(e.target.value); this.render('inspector'); },
      onblur: () => { this.drafts.delete(key); this.render('inspector'); },
      onkeydown: (e) => { if (e.key === 'Enter') e.target.blur(); } });
  },
  numField(key, value, set, { unit = '', minValue = null, width = 110 } = {}) {
    const draft = this.drafts.get(key);
    const input = h('input', { class: 'vs-input num', spellcheck: 'false', 'data-key': key, value: draft != null ? draft : Fmt.num(value),
      oninput: (e) => {
        this.drafts.set(key, e.target.value);
        const v = parseFloat(e.target.value);
        if (!isNaN(v) && /^\s*-?[\d.]+(e-?\d+)?\s*$/i.test(e.target.value) && (minValue == null || v >= minValue)) set(v);
        this.render('inspector');
      },
      onblur: () => { this.drafts.delete(key); this.render('inspector'); },
      onkeydown: (e) => {
        if (e.key === 'Enter') e.target.blur();
        if (e.key === 'ArrowUp' || e.key === 'ArrowDown') { e.preventDefault(); const v = value + (e.key === 'ArrowUp' ? 1 : -1); if (minValue == null || v >= minValue) { set(v); this.drafts.delete(key); this.render('inspector'); } }
      } });
    return h('div', { class: 'num-field', style: `width:${width}px` }, input, unit ? h('span', { class: 'unit' }, unit) : null);
  },
  valueField(key, value, set, placeholder = '') {
    return this.textField(key, value, set, { placeholder, mono: true, invalid: !!value && !LogicLiteral.parse(value) });
  },
  segmented(value, options, set, width) {
    return h('div', { class: 'segmented', style: width ? `width:${width}px` : null }, options.map(([v, label]) => h('button', { class: v === value ? 'on' : '', onclick: () => set(v) }, label)));
  },
  select(value, options, set, width = 130) {
    return h('select', { class: 'vs-select', style: `width:${width}px`, onchange: (e) => set(e.target.value) }, options.map(([v, label]) => h('option', { value: v, selected: v === value ? 'selected' : null }, label)));
  },
  menuButton(label, ic, items, cls = 'vs-button secondary full') {
    return h('button', { class: cls, onclick: (e) => Menus.popup(items(), e.currentTarget) }, ic ? icon(ic) : null, h('span', null, label));
  },

  editInst(doc, id, fn, typing = false) {
    const body = (s) => { const i = s.instances.find((x) => x.id === id); if (i) fn(i, s); };
    if (typing) doc.editTyping(body); else doc.edit(body);
  },

  // ---- Test settings
  testSettings(doc) {
    const s = doc.state;
    const outDir = Tester.outputDir(doc);
    const outs = TS.duts(s).reduce((a, d) => a + Inst.outputs(d).length, 0);
    const units = TimeUnits.all.map((u) => [u, '1 ' + u]);
    const running = Tester.isRunning(doc);
    return [
      this.propRow('Name', this.textField('t-name', s.name, (v) => doc.editTyping((st) => { st.name = v; }))),
      this.propRow('Duration', this.numField('t-dur', s.duration, (v) => doc.editTyping((st) => { st.duration = v; }), { unit: s.unit, minValue: 0, width: 130 })),
      this.propRow('Time unit', this.select(s.unit, units, (v) => doc.edit((st) => { st.unit = v; }))),
      this.propRow('Precision', this.select(s.precision, units, (v) => doc.edit((st) => { st.precision = v; }))),
      this.note(`\`timescale 1${s.unit}/1${s.precision} — every delay in this test is in ${s.unit}.`),
      this.heading('OUTPUT'),
      h('div', { class: 'mono small selectable wrap' }, Paths.tilde(outDir)),
      this.note(s.outputDir == null ? 'Default folder. Testbench, compiled sim and VCD go here.' : 'Custom folder.'),
      h('div', { class: 'btn-row' },
        this.button('Choose…', null, () => {
          const r = Dialogs.openFiles({ title: 'Choose where the testbench, simulation and waveform are written', properties: ['openDirectory', 'createDirectory'] });
          if (r.length) doc.edit((st) => { st.outputDir = r[0]; });
        }),
        this.button(IS_MAC ? 'Reveal' : 'Open', null, () => { if (Host.fs.exists(outDir)) Host.openPath(outDir); else showToast('The folder is created on the first run'); }),
        s.outputDir != null ? this.button('Default', null, () => doc.edit((st) => { delete st.outputDir; })) : null),
      this.checkbox('Open the waveform in HDL Viewer after each run', s.autoOpenVCD, (v) => doc.edit((st) => { st.autoOpenVCD = v; })),
      !Viewer.path() ? this.note('HDL Viewer isn\'t installed, so the VCD opens in its default app.', 'indent') : null,
      this.heading('SUMMARY'),
      h('div', { class: 'small' }, `${TS.duts(s).length} DUT${TS.duts(s).length === 1 ? '' : 's'} · ${TS.sources(s).length} source${TS.sources(s).length === 1 ? '' : 's'} · ${s.wires.length} wire${s.wires.length === 1 ? '' : 's'} · ${outs} output${outs === 1 ? '' : 's'}`),
      doc.lastVCD ? h('span', { class: 'link small', onclick: () => Viewer.open(doc.lastVCD) }, `Open last waveform (${PathUtil.basename(doc.lastVCD)})`) : null,
      this.button(running ? 'Running…' : 'Run Test', 'play', () => Tester.runActive(), false, { disabled: running || !TS.duts(s).length ? 'disabled' : null }),
      this.note('Select a DUT or a pin on the canvas to edit it.'),
    ];
  },

  // ---- DUT
  instanceInspector(doc, inst) {
    const t = currentTheme();
    const env = Inst.paramValues(inst);
    const st = doc.state;
    const draftName = this.drafts.get('i-name');
    const name = draftName != null ? draftName : inst.name;
    const taken = st.instances.some((i) => i.id !== inst.id && i.name === name);
    const bad = !Fmt.isIdentifier(name) || taken;
    const out = [
      h('div', { class: 'insp-title' }, icon('chip', '', `color:${dirColor(t, 'output')}`), h('span', { class: 'mono big' }, inst.moduleName)),
      h('span', { class: 'link small ellipsis-start', title: REVEAL_LABEL, onclick: () => Host.showInFolder(inst.filePath) }, Paths.tilde(inst.filePath)),
      this.propRow('Instance', this.textField('i-name', inst.name, (v) => {
        if (Fmt.isIdentifier(v) && !doc.state.instances.some((i) => i.id !== inst.id && i.name === v)) this.editInst(doc, inst.id, (i) => { i.name = v; }, true);
      }, { mono: true, invalid: bad })),
      bad ? this.note(taken ? 'Another DUT already uses this name.' : 'Use letters, digits and _ (not starting with a digit).', 'error indent') : null,
    ];
    if (inst.params.length) {
      out.push(this.heading('PARAMETERS'));
      for (const p of inst.params) {
        if (p.isLocal) { out.push(this.propRow(p.name, h('span', { class: 'mono dim', title: `localparam ${p.name} = ${p.value}` }, env[p.name] != null ? String(env[p.name]) : p.value))); continue; }
        const v = inst.paramOverrides[p.name] || '';
        const badV = !!v && ExprEval.eval(v, env) == null;
        const ph = p.value + (env[p.name] != null && ExprEval.eval(p.value, {}) == null ? `  (= ${env[p.name]})` : '');
        const f = this.textField('p-' + p.name, v, (nv) => this.editInst(doc, inst.id, (i) => { if (nv) i.paramOverrides[p.name] = nv; else delete i.paramOverrides[p.name]; }, true), { placeholder: ph, mono: true, invalid: badV });
        f.title = `Leave empty to use the default (${p.value}).`;
        out.push(this.propRow(p.name, f));
      }
    }
    out.push(this.heading('PINS'));
    out.push(h('div', { class: 'pin-list' }, inst.ports.map((p) => {
      const d = TS.wireTo(st, { instance: inst.id, pin: p.name });
      let right;
      if (p.unsupported != null) right = h('span', { class: 'small', style: `color:${t.warning}` }, 'not connected');
      else if (d) right = h('span', { class: 'small mono dim ellipsis' }, '← ' + TS.describe(st, d.from));
      else if (p.dir === 'input') right = h('span', { class: 'small', style: `color:${t.warning}` }, 'not wired');
      else if (inst.logged.includes(p.name)) right = icon('list-flat', 'dim');
      return h('div', { class: 'pin-list-row', onclick: () => { doc.selection = { type: 'pin', id: inst.id, pin: p.name }; this.render('all'); } },
        icon(p.dir === 'output' ? 'arrow-left' : (p.dir === 'input' ? 'arrow-right' : 'arrow-swap'), 'small', `color:${dirColor(t, p.dir)}`),
        h('span', { class: 'mono' }, p.name), h('span', { class: 'mono dim tiny' }, Inst.rangeLabel(inst, p, env)), h('span', { class: 'grow' }), right, icon('chevron-right', 'hover-only dim'));
    })));
    const unwired = Inst.inputs(inst).filter((p) => p.unsupported == null && !TS.wireTo(st, { instance: inst.id, pin: p.name }));
    if (unwired.length) out.push(this.button(`Add Sources for ${unwired.length} Unwired Input${unwired.length === 1 ? '' : 's'}`, 'add', () => { doc.addSourcesForUnwiredInputs(inst.id); this.render('all'); }, false,
      { title: 'Clock pins get a clock, reset pins a reset (shared with existing ones), everything else a constant 0' }));
    out.push(h('div', { class: 'btn-row' }, this.button('Duplicate', 'files', () => { doc.duplicateInstance(inst.id); this.render('all'); }), this.button('Remove', 'trash', () => { doc.removeInstance(inst.id); this.render('all'); })));
    return out;
  },

  // ---- Pin
  pinInspector(doc, inst, port) {
    const t = currentTheme();
    const env = Inst.paramValues(inst);
    const r = Inst.resolve(inst, port, env);
    const width = r ? r.width : null;
    const range = Inst.rangeLabel(inst, port, env);
    const ref = { instance: inst.id, pin: port.name };
    const st = doc.state;
    const w = TS.wireTo(st, ref);
    const out = [
      h('div', { class: 'insp-title mono big' }, h('span', { class: 'dim' }, inst.name + '.'), h('b', null, port.name)),
      h('div', { class: 'small dim' }, h('span', { style: `color:${dirColor(t, port.dir)}` }, port.dir), ' · ', width != null ? `${width} bit${width === 1 ? '' : 's'}` : 'width unknown',
        range ? h('span', { class: 'mono' }, ' ' + range) : null, port.dataType ? ` · ${port.dataType}` : ''),
    ];
    if (port.unsupported != null) out.push(this.notice('warning', t.warning, `This pin is left unconnected in the testbench: ${port.unsupported}.`));
    else if (port.dir === 'output') {
      out.push(this.heading('OUTPUT'), this.note('Every output is recorded in the waveform file (VCD), so you can inspect it in HDL Viewer after a run.'),
        this.checkbox('Print each value change in the Output panel', inst.logged.includes(port.name), (on) => this.editInst(doc, inst.id, (i) => { i.logged = i.logged.filter((x) => x !== port.name); if (on) i.logged.push(port.name); })));
      out.push(...this.wiringList(doc, ref));
    } else if (port.dir === 'input') out.push(...this.driverSection(doc, ref, w ? w.from : null));
    else out.push(this.notice('info', t.dimFG, 'inout pins are connected to a testbench wire that nothing drives, and are recorded in the waveform.'));
    return out;
  },

  driverSection(doc, input, driver) {
    const t = currentTheme();
    const st = doc.state;
    const inst = TS.instance(st, input.instance);
    const port = inst && inst.ports.find((p) => p.name === input.pin);
    const guess = port ? SourcePresets.guess(port) : 'constant';
    const rr = port ? Inst.resolve(inst, port) : null;
    const inputWidth = rr ? rr.width : 1;
    const newSource = (p) => { const id = doc.addSource(p, input); if (id) doc.selection = { type: 'instance', id }; this.render('all'); };
    const menuItems = () => {
      const items = [];
      if (driver) items.push({ label: 'Not wired', action: () => doc.disconnect(input) });
      const sources = TS.sources(st).map((s) => ({ instance: s.id, pin: 'out' }));
      if (sources.length) items.push({ type: 'header', label: 'Sources' }, ...sources.map((d) => ({ label: TS.describe(st, d), action: () => { doc.connect(d, input); this.render('all'); } })));
      const outs = TS.driverPins(st).filter((d) => { const i = TS.instance(st, d.instance); return i && !Inst.isSource(i); });
      if (outs.length) items.push({ type: 'header', label: 'DUT outputs' }, ...outs.map((d) => ({ label: TS.describe(st, d), action: () => { doc.connect(d, input); this.render('all'); } })));
      items.push({ type: 'header', label: 'New source' }, ...SourcePresets.all.map((p) => ({ label: SourcePresets.title[p], action: () => newSource(p) })));
      return items;
    };
    const out = [this.heading('DRIVEN BY'),
      h('button', { class: 'dropdown', onclick: (e) => Menus.popup(menuItems(), e.currentTarget) }, icon(driver ? 'git-merge' : 'warning', '', `color:${driver ? t.dimFG : t.warning}`),
        h('span', { class: driver ? 'mono' : '' }, driver ? `Wire from ${TS.describe(st, driver)}` : 'Not wired'), h('span', { class: 'grow' }), icon('chevron-down', 'dim'))];
    if (!driver) {
      out.push(this.note('Inputs are driven only by wires. Drag from the pin\'s dot to a source or a DUT output, pick one above, or add a new source:'));
      out.push(h('div', { class: 'btn-row' }, this.button(`New ${SourcePresets.shortTitle(guess)}`, 'add', () => newSource(guess)), guess !== 'constant' ? this.button('New Constant', 'add', () => newSource('constant')) : null));
      const match = TS.matchingSource(st, guess, inputWidth);
      if (match) out.push(this.button(`Wire to ${match.name}`, 'link', () => { doc.connect({ instance: match.id, pin: 'out' }, input); this.render('all'); }));
    } else {
      const di = TS.instance(st, driver.instance);
      out.push(h('div', { class: 'btn-row' },
        this.button('Go to Driver', 'reply', () => { doc.selection = di && Inst.isSource(di) ? { type: 'instance', id: driver.instance } : { type: 'pin', id: driver.instance, pin: driver.pin }; this.render('all'); }),
        this.button('Disconnect', 'debug-disconnect', () => doc.disconnect(input))));
      if (di && Inst.isSource(di)) out.push(this.note(`Edit the signal by selecting the ${di.name} source block.`));
      const same = TS.inputPins(st).filter((p) => p.pin === input.pin && !pinEq(p, input) && !(TS.wireTo(st, p) && pinEq(TS.wireTo(st, p).from, driver)));
      if (same.length) out.push(this.button(`Wire every “${input.pin}” pin to ${TS.describe(st, driver)} (${same.length} more)`, 'files', () => doc.edit((s) => {
        s.wires = s.wires.filter((w) => !same.some((p) => pinEq(p, w.to)));
        for (const p of same) s.wires.push({ id: newUUID(), from: driver, to: p });
      })));
    }
    return out;
  },

  wiringList(doc, from) {
    const t = currentTheme();
    const st = doc.state;
    const wires = TS.wiresFrom(st, from);
    const out = [this.heading('WIRED TO')];
    if (!wires.length) out.push(this.note('Not wired. Drag from the pin\'s dot to an input, or pick one below.'));
    for (const w of wires) {
      out.push(h('div', { class: 'wire-row' }, icon('arrow-right', 'small', `color:${dirColor(t, 'input')}`),
        h('span', { class: 'link mono plain', onclick: () => { doc.selection = { type: 'pin', id: w.to.instance, pin: w.to.pin }; this.render('all'); } }, TS.describe(st, w.to)),
        h('span', { class: 'grow' }), h('button', { class: 'icon-btn codicon codicon-close', title: 'Remove this wire', onclick: () => doc.removeWire(w.id) })));
    }
    const free = TS.inputPins(st).filter((p) => { const w = TS.wireTo(st, p); return !(w && pinEq(w.from, from)); });
    if (free.length) {
      out.push(this.menuButton('Wire to an Input', 'add', () => free.map((tp) => ({ label: TS.describe(st, tp) + (TS.wireTo(st, tp) ? '  (replaces its wire)' : ''), action: () => {
        doc.connect(from, tp);
        const fi = TS.instance(doc.state, from.instance);
        doc.selection = fi && Inst.isSource(fi) ? { type: 'instance', id: from.instance } : { type: 'pin', id: from.instance, pin: from.pin };
        this.render('all');
      } }))));
    }
    return out;
  },

  wireInspector(doc, w) {
    const t = currentTheme();
    const st = doc.state;
    const probs = Tester.generated(doc).problems.filter((p) => p.wire === w.id);
    const endpoint = (label, ref, isSource) => {
      const i = TS.instance(st, ref.instance);
      const p = i && i.ports.find((x) => x.name === ref.pin);
      const r = p ? Inst.resolve(i, p) : null;
      return this.propRow(label, h('span', null, h('span', { class: 'link mono', onclick: () => { doc.selection = isSource ? { type: 'instance', id: ref.instance } : { type: 'pin', id: ref.instance, pin: ref.pin }; this.render('all'); } }, TS.describe(st, ref)),
        r ? h('span', { class: 'small dim' }, `  ${r.width} bit${r.width === 1 ? '' : 's'}`) : null), 44);
    };
    const fi = TS.instance(st, w.from.instance);
    return [endpoint('From', w.from, !!(fi && Inst.isSource(fi))), endpoint('To', w.to, false),
      ...probs.map((p) => this.notice('warning', p.severity === 'error' ? t.error : t.warning, p.message)),
      this.note('In the testbench, the input uses the same signal as the output it is wired from.'),
      this.button('Delete Wire', 'trash', () => doc.removeWire(w.id)),
      this.note('Tip: select a wire and press Delete to remove it.')];
  },

  sourceInspector(doc, inst) {
    const st = doc.state;
    const draftName = this.drafts.get('s-name');
    const name = draftName != null ? draftName : inst.name;
    const taken = st.instances.some((i) => i.id !== inst.id && i.name === name);
    const bad = !Fmt.isIdentifier(name) || taken;
    return [
      this.note('A source drives every input it is wired to with the same signal.'),
      this.propRow('Name', this.textField('s-name', inst.name, (v) => {
        if (Fmt.isIdentifier(v) && !doc.state.instances.some((i) => i.id !== inst.id && i.name === v)) this.editInst(doc, inst.id, (i) => { i.name = v; }, true);
      }, { mono: true, invalid: bad })),
      bad ? this.note(taken ? 'Another block already uses this name.' : 'Use letters, digits and _ (not starting with a digit).', 'error indent') : null,
      this.propRow('Width', this.numField('s-width', Inst.sourceWidth(inst), (v) => this.editInst(doc, inst.id, (i) => Inst.setSourceWidth(i, Math.round(v)), true), { unit: 'bits', minValue: 1 })),
      ...this.wiringList(doc, { instance: inst.id, pin: 'out' }),
      ...this.stimulusBody(doc, inst, inst.ports[0]),
      h('div', { class: 'btn-row' }, this.button('Duplicate', 'files', () => { doc.duplicateInstance(inst.id); this.render('all'); }), this.button('Delete', 'trash', () => { doc.removeInstance(inst.id); this.render('all'); })),
    ];
  },

  stimulusBody(doc, inst, port) {
    const t = currentTheme();
    const r = Inst.resolve(inst, port);
    const width = r ? r.width : null;
    const s = Inst.stimulus(inst, port.name);
    const u = doc.state.unit;
    const apply = (ns) => this.editInst(doc, inst.id, (i) => { i.stimuli[port.name] = ns; });
    const set = (fn) => this.editInst(doc, inst.id, (i) => { const c = Inst.stimulus(i, port.name); fn(c); i.stimuli[port.name] = c; }, true);
    const setNow = (fn) => this.editInst(doc, inst.id, (i) => { const c = Inst.stimulus(i, port.name); fn(c); i.stimuli[port.name] = c; });
    const setKind = (k) => {
      if (s.kind === k) return;
      const c = clone(s);
      c.kind = k;
      if (k === 'sequence' && !c.steps.length) { c.seqInitial = '0'; c.steps = [{ id: newUUID(), delay: 20, value: '1' }]; }
      apply(c);
    };
    const out = [this.heading('STIMULUS'),
      h('div', { class: 'kind-grid' }, StimKinds.all.map((k) => {
        const on = k === s.kind;
        const c = stimColor(t, k);
        return h('button', { class: 'kind-btn' + (on ? ' on' : ''), style: `--c:${c}`, title: StimKinds.help[k], onclick: () => setKind(k) }, this.stimIcon(k, 15, on ? c : t.dimFG), h('span', null, StimKinds.title[k]));
      })),
      this.note(StimKinds.help[s.kind])];
    const k = (n) => `stim-${n}`;
    switch (s.kind) {
      case 'constant': {
        out.push(this.propRow('Value', this.valueField(k('const'), s.constant, (v) => set((c) => { c.constant = v; }))));
        out.push(h('div', { class: 'quick-values' }, ['0', '1', 'x', 'z'].map((v) => h('button', { class: 'mono', onclick: () => setNow((c) => { c.constant = v; }) }, v))));
        const l = LogicLiteral.parse(s.constant);
        const bits = width > 1 && l ? LogicLiteral.bits(l, width) : null;
        const v = bits ? BitsFormat.uint(bits) : null;
        if (v != null) out.push(h('div', { class: 'mono small dim indent' }, `= ${v} · 0x${BitsFormat.hex(bits)}`));
        break;
      }
      case 'clock': {
        const high = s.period * Math.min(Math.max(s.duty, 0), 100) / 100;
        const firstRise = s.clockDelay + (s.startHigh ? s.period : s.period - high);
        out.push(this.propRow('Period', h('div', { class: 'hstack' }, this.numField(k('per'), s.period, (v) => set((c) => { c.period = v; }), { unit: u, minValue: 0 }), h('span', { class: 'small dim' }, Fmt.frequency(s.period, u)))),
          this.propRow('Duty cycle', this.numField(k('duty'), s.duty, (v) => set((c) => { c.duty = v; }), { unit: '%', minValue: 0 })),
          this.propRow('Starts', this.segmented(s.startHigh, [[false, 'Low'], [true, 'High']], (v) => setNow((c) => { c.startHigh = v; }), 140)),
          this.propRow('Start delay', this.numField(k('cdel'), s.clockDelay, (v) => set((c) => { c.clockDelay = v; }), { unit: u, minValue: 0 })),
          h('div', { class: 'small dim indent' }, `First rising edge at ${Fmt.num(firstRise)} ${u}`));
        break;
      }
      case 'sequence': {
        out.push(this.propRow('Initial value', this.valueField(k('init'), s.seqInitial, (v) => set((c) => { c.seqInitial = v; }))),
          this.propRow('Times are', this.segmented(s.absoluteTimes, [[false, 'Delays'], [true, 'Absolute']], (v) => setNow((c) => { c.absoluteTimes = v; }), 160)),
          h('div', { class: 'seq-head' }, h('span', { class: 'n' }, '#'), h('span', { class: 'd' }, s.absoluteTimes ? `At time (${u})` : `After (${u})`), h('span', { class: 'v' }, 'Set to')));
        s.steps.forEach((step, i) => {
          out.push(h('div', { class: 'seq-row' }, h('span', { class: 'n mono' }, i + 1),
            this.numField(k('d-' + step.id), step.delay, (v) => set((c) => { const x = c.steps.find((y) => y.id === step.id); if (x) x.delay = v; }), { minValue: 0, width: 104 }),
            this.valueField(k('v-' + step.id), step.value, (v) => set((c) => { const x = c.steps.find((y) => y.id === step.id); if (x) x.value = v; })),
            h('button', { class: 'icon-btn codicon codicon-remove', title: 'Remove step', onclick: () => { const c = clone(s); c.steps = c.steps.filter((x) => x.id !== step.id); apply(c); } })));
        });
        out.push(h('div', { class: 'btn-row' },
          this.button('Add Step', 'add', () => {
            const c = clone(s);
            const last = c.steps[c.steps.length - 1];
            const lastValue = last ? last.value : c.seqInitial;
            let next = '1';
            if ((width ?? 1) === 1) next = lastValue === '1' ? '0' : '1';
            else { const l = LogicLiteral.parse(lastValue); const v = l ? LogicLiteral.intValue(l) : null; if (v != null) next = String(v + 1n); }
            const d = c.absoluteTimes ? (last ? last.delay : 0) + 10 : (last ? last.delay : 10);
            c.steps.push({ id: newUUID(), delay: d, value: next });
            apply(c);
          }),
          this.button('Edit as Text', 'list-flat', () => this.sequenceTextSheet(s, u, (steps) => { const c = clone(s); c.steps = steps; apply(c); }))));
        out.push(this.checkbox('Repeat the steps forever', s.seqRepeat, (v) => setNow((c) => { c.seqRepeat = v; })));
        const total = s.absoluteTimes ? Math.max(0, ...s.steps.map((x) => x.delay)) : s.steps.reduce((a, x) => a + x.delay, 0);
        out.push(h('div', { class: 'small dim' }, `Last change at ${Fmt.num(total)} ${u}` + (s.seqRepeat ? ', then starts over' : '')));
        break;
      }
      case 'bitstream': {
        const toks = Stim.streamTokens(s, width);
        const bad = toks.some((x) => !LogicLiteral.parse(x));
        out.push(this.propRow((width ?? 1) === 1 ? 'Bits' : 'Values', this.textField(k('bits'), s.bits, (v) => set((c) => { c.bits = v; }), { placeholder: (width ?? 1) === 1 ? '10110010' : 'A5 3C FF 00', mono: true, invalid: bad })),
          h('div', { class: 'small dim indent' }, (width ?? 1) === 1 ? 'Sent left to right, one bit per bit time.' : 'Separate values with spaces, e.g.  8\'hA5 8\'h3C 255'),
          this.propRow('Bit time', this.numField(k('bt'), s.bitTime, (v) => set((c) => { c.bitTime = v; }), { unit: u, minValue: 0 })),
          this.propRow('Start delay', this.numField(k('bd'), s.bitDelay, (v) => set((c) => { c.bitDelay = v; }), { unit: u, minValue: 0 })),
          this.propRow('Idle value', this.valueField(k('idle'), s.bitIdle, (v) => set((c) => { c.bitIdle = v; }))),
          this.checkbox('Repeat the stream forever', s.bitRepeat, (v) => setNow((c) => { c.bitRepeat = v; })),
          h('div', { class: 'small dim' }, `${toks.length} value${toks.length === 1 ? '' : 's'} · ${Fmt.num(toks.length * s.bitTime)} ${u} per pass`));
        break;
      }
      case 'counter':
        out.push(this.propRow('Start value', this.valueField(k('cs'), s.countStart, (v) => set((c) => { c.countStart = v; }))),
          this.propRow('Step', this.valueField(k('cst'), s.countStep, (v) => set((c) => { c.countStep = v; }), '1')),
          this.propRow('Every', this.numField(k('ci'), s.countInterval, (v) => set((c) => { c.countInterval = v; }), { unit: u, minValue: 0 })),
          this.propRow('Start delay', this.numField(k('cd'), s.countDelay, (v) => set((c) => { c.countDelay = v; }), { unit: u, minValue: 0 })));
        break;
      default:
        out.push(this.propRow('Every', this.numField(k('ri'), s.randInterval, (v) => set((c) => { c.randInterval = v; }), { unit: u, minValue: 0 })),
          this.propRow('Seed', this.numField(k('rs'), s.randSeed, (v) => set((c) => { c.randSeed = Math.trunc(v); }))),
          this.propRow('Start delay', this.numField(k('rd'), s.randDelay, (v) => set((c) => { c.randDelay = v; }), { unit: u, minValue: 0 })));
    }
    const probs = Tester.generated(doc).problems.filter((p) => p.instance === inst.id && p.pin === port.name);
    for (const p of probs) out.push(this.notice(p.severity === 'error' ? 'error' : 'warning', p.severity === 'error' ? t.error : t.warning, p.message.replace(`${inst.name}.${port.name}: `, '')));
    const horizon = StimulusPreview.suggestedHorizon(s, doc.state.duration);
    const wave = h('canvas', { class: 'stim-preview', style: `height:${(width ?? 1) > 1 ? 30 : 36}px` });
    const ruler = h('canvas', { class: 'stim-ruler' });
    out.push(h('div', { class: 'preview-head' }, this.heading('PREVIEW'), h('span', { class: 'grow' }), h('span', { class: 'small dim' }, `first ${Fmt.num(horizon)} ${u}`)),
      h('div', { class: 'preview-box' }, wave), h('div', { class: 'ruler-box' }, ruler));
    requestAnimationFrame(() => {
      this.drawStimWave(wave, StimulusPreview.segments(s, width, horizon), horizon, stimColor(t, s.kind));
      this.drawRuler(ruler, 0, horizon, u, true);
    });
    if (s.kind === 'random') out.push(this.note('Preview values are illustrative; the simulator\'s $random gives different numbers.'));
    const pr = TS.typicalClockPeriod(doc.state);
    out.push(h('div', { class: 'btn-row' },
      this.button('Copy', 'copy', () => { Tester.stimulusClipboard = clone(s); this.render('inspector'); }),
      this.button('Paste', 'clippy', () => { if (Tester.stimulusClipboard) apply(clone(Tester.stimulusClipboard)); }, true, { disabled: Tester.stimulusClipboard ? null : 'disabled' }),
      this.menuButton('Presets', 'wand', () => [
        { type: 'header', label: 'Clock' }, ...[[10, '100 MHz'], [20, '50 MHz'], [8, '125 MHz'], [40, '25 MHz']].map(([per, label]) => ({ label: `${label}  (${Fmt.num(per)} ${u})`, action: () => apply(Stim.clock(per)) })),
        { type: 'header', label: 'Reset' }, { label: 'Active-high reset for 2 cycles', action: () => apply(Stim.reset(false, pr * 2)) }, { label: 'Active-low reset for 2 cycles', action: () => apply(Stim.reset(true, pr * 2)) },
        { type: 'header', label: 'Pulse' }, { label: 'One-cycle pulse after 5 cycles', action: () => apply(Object.assign(Stim.defaults(), { kind: 'sequence', seqInitial: '0', steps: [{ id: newUUID(), delay: pr * 5, value: '1' }, { id: newUUID(), delay: pr, value: '0' }] })) },
        { type: 'header', label: 'Constant' }, { label: '0', action: () => apply(Stim.constant('0')) }, { label: '1', action: () => apply(Stim.constant('1')) },
        ...(width > 1 ? [{ label: 'All ones', action: () => apply(Stim.constant(`${width}'h` + 'f'.repeat(Math.ceil(width / 4)))) }] : []),
      ])));
    return out;
  },

  sequenceTextSheet(s, unit, onApply) {
    Dialogs.modal('Sequence steps', (close) => {
      const ta = h('textarea', { class: 'vs-textarea mono', spellcheck: 'false' });
      ta.value = s.steps.map((x) => `${Fmt.num(x.delay)} ${x.value}`).join('\n');
      const status = h('div', { class: 'small' });
      const applyBtn = h('button', { class: 'vs-button' }, 'Apply');
      const parse = () => {
        const steps = [], bad = [];
        ta.value.split('\n').forEach((raw, i) => {
          const line = raw.split('//')[0].trim();
          if (!line) return;
          const parts = line.split(/[ \t,]+/).filter(Boolean);
          const d = parts.length === 2 ? parseFloat(parts[0].replace(/#/g, '')) : NaN;
          if (parts.length !== 2 || isNaN(d) || !LogicLiteral.parse(parts[1])) { bad.push(i + 1); return; }
          steps.push({ id: newUUID(), delay: d, value: parts[1] });
        });
        return [steps, bad];
      };
      const update = () => {
        const [steps, bad] = parse();
        status.textContent = bad.length ? `Can't read line${bad.length === 1 ? '' : 's'} ${bad.join(', ')}` : `${steps.length} step${steps.length === 1 ? '' : 's'}`;
        status.style.color = bad.length ? currentTheme().error : '';
        ta.classList.toggle('invalid', bad.length > 0);
        applyBtn.disabled = bad.length > 0;
      };
      ta.addEventListener('input', update);
      ta.addEventListener('keydown', (e) => e.stopPropagation());
      applyBtn.onclick = () => { const [steps, bad] = parse(); if (!bad.length) { onApply(steps); close(true); } };
      update();
      return h('div', { class: 'modal-body' }, h('div', { class: 'modal-msg' }, `One step per line: ${s.absoluteTimes ? 'time' : 'delay'} in ${unit}, then the value.  Example:  20 8'hA5`), ta,
        h('div', { class: 'modal-buttons' }, status, h('span', { class: 'grow' }), h('button', { class: 'vs-button secondary', onclick: () => close(null) }, 'Cancel'), applyBtn));
    });
  },

  // ---------------------------------------------------------------- Bottom panel

  renderPanel() {
    const doc = Tester.active;
    if (!doc || !Tester.showPanel) return;
    const t = currentTheme();
    const gen = Tester.generated(doc);
    const tabs = [['testbench', 'TESTBENCH'], ['output', 'OUTPUT'], ['problems', 'PROBLEMS'], ['stimulus', 'STIMULUS']].map(([id, title]) => {
      const on = Tester.panelTab === id;
      const count = id === 'problems' ? gen.problems.length : 0;
      return h('button', { class: 'panel-tab' + (on ? ' active' : ''), onclick: () => { Tester.panelTab = id; this.render('panel'); } }, title,
        count ? h('span', { class: 'count-pill' + (gen.problems.some((p) => p.severity === 'error') ? ' err' : '') }, count) : null,
        id === 'output' && Tester.isRunning(doc) ? icon('loading', 'spin small') : null);
    });
    const ib = (ic, title, action) => h('button', { class: 'icon-btn codicon codicon-' + ic, title, onclick: action });
    const actions = [];
    if (Tester.panelTab === 'testbench') {
      actions.push(ib('copy', 'Copy Testbench', () => copyText(gen.source)), ib('save', 'Save Testbench As…', () => {
        const p = Dialogs.saveFile({ title: 'Save Testbench', defaultPath: PathUtil.join(Tester.outputDir(doc), gen.topName + '.v'), filters: [{ name: 'Verilog', extensions: ['v'] }] });
        if (p) { const err = Host.fs.writeText(p, gen.source); if (err) Dialogs.alert('Could not save the testbench', err); }
      }));
    } else if (Tester.panelTab === 'output') {
      if (doc.lastVCD) actions.push(ib('pulse', `Open ${PathUtil.basename(doc.lastVCD)} in HDL Viewer (${keyLabel('Ctrl+Shift+Y')})`, () => Viewer.open(doc.lastVCD)));
      actions.push(ib('folder', 'Reveal Output Folder', () => { const d = Tester.outputDir(doc); if (Host.fs.exists(d)) Host.openPath(d); }),
        ib('copy', 'Copy Output', () => copyText(doc.log.map((l) => l.text).join('\n'))), ib('trash', 'Clear Output', () => { doc.log = []; this.render('panel'); }));
    }
    const header = h('div', { class: 'panel-header' }, ...tabs, h('span', { class: 'grow' }), ...actions, ib('close', `Close Panel (${keyLabel('Ctrl+J')})`, () => { Tester.showPanel = false; this.render('all'); }));
    let body;
    if (Tester.panelTab === 'testbench') body = this.codeView(gen.source);
    else if (Tester.panelTab === 'output') {
      const color = (k) => ({ command: Syntax.colors(t).system, info: t.dimFG, stdout: t.fg, warning: t.warning, error: t.error, success: t.success }[k]);
      const lines = doc.log.map((l) => h('div', { class: 'out-line' + (l.kind === 'success' ? ' bold' : ''), style: `color:${color(l.kind)}` }, l.text || ' '));
      if (!lines.length) lines.push(h('div', { class: 'dim-pad' }, doc.status.kind === 'idle' ? `Run the test (${keyLabel('Ctrl+R')}) to compile it with Icarus Verilog and simulate it.` : ''));
      body = h('div', { class: 'scroll panel-body output selectable' }, lines);
    } else if (Tester.panelTab === 'problems') {
      const rows = gen.problems.map((p) => h('div', { class: 'problem-row', onclick: () => {
        if (p.wire) doc.selection = { type: 'wire', id: p.wire };
        else if (!p.instance) doc.selection = null;
        else doc.selection = p.pin ? { type: 'pin', id: p.instance, pin: p.pin } : { type: 'instance', id: p.instance };
        this.render('all');
      } }, icon(p.severity === 'error' ? 'error' : 'warning', '', `color:${p.severity === 'error' ? t.error : t.warning}`), h('span', { class: 'msg' }, p.message)));
      if (!rows.length) rows.push(h('div', { class: 'dim-pad' }, 'No problems have been detected in this test.'));
      body = h('div', { class: 'scroll panel-body', 'data-scroll-key': 'tprob' }, rows);
    } else body = this.timelineView(doc);
    const prev = this.el.panel.querySelector('.panel-body.output');
    const atBottom = !prev || prev.scrollTop + prev.clientHeight >= prev.scrollHeight - 30;
    replaceKeepingFocus(this.el.panel, [header, body]);
    if (Tester.panelTab === 'output' && atBottom) body.scrollTop = body.scrollHeight;
  },

  codeView(source) {
    const t = currentTheme();
    const syn = Syntax.colors(t);
    const types = new Set(['reg', 'wire', 'integer', 'logic', 'signed', 'real', 'time', 'genvar', 'localparam', 'parameter']);
    const lines = source.split('\n');
    const gutterW = String(lines.length).length * 7.5 + 22;
    const frag = lines.map((line, i) => {
      const spans = [];
      let k = 0;
      const add = (s, c) => spans.push(h('span', { style: `color:${c}` }, s));
      while (k < line.length) {
        const c = line[k];
        if (c === '/' && line[k + 1] === '/') { add(line.slice(k), syn.comment); break; }
        if (c === '"') { let j = k + 1; while (j < line.length && line[j] !== '"') { if (line[j] === '\\') j++; j++; } j = Math.min(j + 1, line.length); add(line.slice(k, j), syn.string); k = j; continue; }
        if (c === '`' || c === '$') { let j = k + 1; while (j < line.length && /[\p{L}\p{N}_]/u.test(line[j])) j++; add(line.slice(k, j), c === '`' ? syn.directive : syn.system); k = j; continue; }
        if (/\d/.test(c) || (c === "'" && /[bodhsBODHS]/.test(line[k + 1] || '')) || (c === '#' && /\d/.test(line[k + 1] || ''))) {
          let j = k + 1; while (j < line.length && /[0-9a-fA-F'xXzZ_.bodhsBODHS]/.test(line[j])) j++; add(line.slice(k, j), syn.number); k = j; continue;
        }
        if (/[\p{L}_]/u.test(c)) {
          let j = k + 1; while (j < line.length && /[\p{L}\p{N}_$]/u.test(line[j])) j++;
          const w = line.slice(k, j);
          add(w, types.has(w) ? syn.type : (VerilogParser.keywords.has(w) ? syn.keyword : syn.ident));
          k = j; continue;
        }
        add(c, t.fg); k++;
      }
      return h('div', { class: 'code-line' }, h('span', { class: 'gutter', style: `width:${gutterW}px` }, i + 1), h('span', { class: 'code' }, spans));
    });
    return h('div', { class: 'scroll panel-body code-view selectable', 'data-scroll-key': 'tbcode' }, frag);
  },

  timelineView(doc) {
    const t = currentTheme();
    const st = doc.state;
    const tl = this.timeline;
    const duration = Math.max(st.duration, 1e-9);
    const span = duration / tl.zoom;
    const start = (duration - span) * tl.position;
    const labelW = 190;
    const rows = TS.sources(st).filter((s) => s.ports[0]).map((s) => [s, s.ports[0]]);
    const zoomSlider = h('input', { type: 'range', min: 0, max: 8, step: 0.01, value: Math.log2(tl.zoom), oninput: (e) => { tl.zoom = Math.pow(2, +e.target.value); this.render('panel'); } });
    const posSlider = h('input', { type: 'range', min: 0, max: 1, step: 0.001, value: tl.position, disabled: tl.zoom <= 1.001 ? 'disabled' : null, oninput: (e) => { tl.position = +e.target.value; this.render('panel'); } });
    const ruler = h('canvas', { class: 'timeline-ruler' });
    const waves = [];
    const list = rows.map(([inst, port]) => {
      const s = Inst.stimulus(inst, port.name);
      const r = Inst.resolve(inst, port);
      const selected = doc.selection && doc.selection.type !== 'wire' && doc.selection.id === inst.id;
      const cv = h('canvas', { class: 'timeline-wave' });
      waves.push([cv, s, r ? r.width : null]);
      return h('div', { class: 'timeline-row' + (selected ? ' sel' : ''), onclick: () => { doc.selection = { type: 'instance', id: inst.id }; this.render('all'); } },
        h('div', { class: 'timeline-label', style: `width:${labelW}px` }, this.stimIcon(s.kind, 9, stimColor(t, s.kind)), h('span', { class: 'mono' }, inst.name)), cv);
    });
    if (!list.length) list.push(h('div', { class: 'dim-pad' }, 'Add a source block (Clock, Reset, …) to see its signal here.'));
    requestAnimationFrame(() => {
      this.drawRuler(ruler, start, start + span, st.unit, false);
      for (const [cv, s, w] of waves) this.drawStimWave(cv, StimulusPreview.segments(s, w, start + span), start + span, stimColor(t, s.kind), start);
    });
    return h('div', { class: 'panel-body timeline' },
      h('div', { class: 'timeline-controls' }, h('span', { class: 'small dim' }, 'Zoom'), zoomSlider, h('span', { class: 'small dim' }, 'Position'), posSlider, h('span', { class: 'grow' }),
        h('span', { class: 'small dim ellipsis' }, `Inputs over the whole test (${Fmt.num(st.duration)} ${st.unit}). Outputs appear after a run, in HDL Viewer.`)),
      h('div', { class: 'timeline-ruler-row' }, h('div', { style: `width:${labelW}px;flex:none` }), ruler),
      h('div', { class: 'scroll timeline-rows' }, list));
  },

  // ---------------------------------------------------------------- Status bar & welcome

  renderStatus() {
    const doc = Tester.active;
    const found = !!Tools.iverilog;
    const items = [h('div', { class: 'sb-item sb-accent' + (found ? '' : ' sb-error'), title: found ? Tools.iverilog : Tools.installHint() },
      icon(found ? 'chip' : 'warning'), found ? `Icarus Verilog ${Tools.iverilogVersion || ''}` : 'Icarus Verilog not found')];
    if (doc) {
      const gen = Tester.generated(doc);
      const errors = gen.problems.filter((p) => p.severity === 'error').length;
      const st = doc.state;
      items.push(h('div', { class: 'sb-item clickable', title: 'Show Problems', onclick: () => { Tester.panelTab = 'problems'; Tester.showPanel = true; this.render('all'); } },
        icon('error'), String(errors), icon('warning', 'gap'), String(gen.problems.length - errors)),
      h('div', { class: 'sb-item' }, icon('chip'), `${TS.duts(st).length} DUT${TS.duts(st).length === 1 ? '' : 's'}`),
      st.wires.length ? h('div', { class: 'sb-item' }, icon('git-merge'), `${st.wires.length} wire${st.wires.length === 1 ? '' : 's'}`) : null,
      h('div', { class: 'sb-item' }, icon('watch'), `${Fmt.num(st.duration)} ${st.unit}`), h('div', { class: 'sb-spacer' }));
      const rs = doc.status;
      const lab = { compiling: ['tools', 'Compiling…'], simulating: ['play', 'Simulating…'], passed: ['pass', 'Simulation finished' + (doc.lastRunSeconds != null ? ` in ${doc.lastRunSeconds.toFixed(2)} s` : '')],
        failed: ['error', rs.why], stopped: ['debug-stop', 'Stopped'] }[rs.kind];
      if (lab) items.push(h('div', { class: 'sb-item clickable', onclick: () => { Tester.panelTab = 'output'; Tester.showPanel = true; this.render('all'); } }, icon(lab[0]), lab[1]));
      items.push(h('div', { class: 'sb-item' }, icon('symbol-ruler'), `\`timescale 1${st.unit}/1${st.precision}`));
    } else items.push(h('div', { class: 'sb-spacer' }));
    this.el.status.replaceChildren(...items.filter(Boolean));
  },

  renderWelcome() {
    if (Tester.active) return;
    const link = (ic, title, detail, action) => h('div', { class: 'link-row' }, icon(ic), h('span', { class: 'link', onclick: action }, title), h('span', { class: 'dim small' }, detail));
    const step = (n, text) => h('div', { class: 'step-row' }, h('span', { class: 'step-num' }, n), h('span', null, text));
    this.el.welcome.replaceChildren(h('div', { class: 'welcome-inner' },
      h('div', null, h('h1', null, 'HDL Tester'), h('div', { class: 'subtitle' }, 'Testbenches for your Verilog modules, without writing one')),
      h('div', { class: 'cols' },
        h('div', { class: 'col' }, h('h2', null, 'Start'), link('add', 'New Test', keyLabel('Ctrl+N'), () => Tester.newTest()), link('go-to-file', 'Open Verilog File…', keyLabel('Ctrl+O'), () => Tester.showOpenPanel()),
          Tester.exampleDir() ? link('beaker', 'Open Example Test', '4 DUTs', () => Tester.openExample()) : null,
          Tester.exampleDir() ? link('git-merge', 'Open Wired Example', 'DUTs wired together', () => Tester.openExample('wired.hdltest')) : null),
        h('div', { class: 'col grow' }, h('h2', null, 'Recent Tests'), Tester.recentTests.length ? null : h('div', { class: 'dim' }, 'No saved tests yet'),
          Tester.recentTests.slice(0, 8).map((p) => h('div', { class: 'recent-row' }, h('span', { class: 'link', onclick: () => Tester.open([p]) }, PathUtil.basename(p)), h('span', { class: 'dim' }, Paths.tilde(PathUtil.dirname(p))))))),
      h('div', null, h('h2', null, 'How it works'),
        step(1, 'Open .v / .sv files. Every module appears under Available DUTs.'),
        step(2, 'Drag modules onto a test\'s canvas. Each becomes a box with its input and output pins.'),
        step(3, 'Add sources (clock, reset, constant, sequence, bit stream, counter, random) and drag from their dots to the DUT inputs. Outputs can be wired to other DUTs\' inputs too.'),
        step(4, `Press Run (${keyLabel('Ctrl+R')}). HDL Tester writes the testbench, runs Icarus Verilog and opens the waveform in HDL Viewer.`))));
  },
};

if (typeof module !== 'undefined') module.exports = { TesterUI };
