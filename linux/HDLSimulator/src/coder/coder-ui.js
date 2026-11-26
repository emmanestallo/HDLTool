'use strict';
/* global Coder, EditorDocument, HDLEditor, Typing, monaco, Shell, App, Host, PathUtil, Paths, Prefs, MOD, IS_WIN, IS_MAC, IS_LINUX, REVEAL_LABEL, REVEAL_SOURCE_LABEL, INSTALL_HINT, h, icon, $, Menus, Dialogs,
   showToast, copyText, splitter, replaceKeepingFocus, frameScheduler, Fuzzy, keyLabel, currentTheme, THEMES, fileStyle, dirColor, symbolColor,
   SymbolKinds, symPorts, flattenSymbols, Snippets, Templates, HDLLanguage, Tools, Viewer, SearchEngine, store, Linter */
// HDL Coder: the window content of the Coder tab. Port of CoderKit/Views.

const CoderUI = {
  dirty: new Set(),
  el: {},
  sidebarW: store.get('sidebarWidth', 270),
  panelH: store.get('panelHeight', 230),
  collapsed: { openEditors: false, folder: false, outline: new Set(), hierarchy: new Set() },
  outlineFilter: '',
  showSearchInclude: false,
  paletteSel: 0,
  paletteOriginalTheme: null,

  build(root) {
    const el = this.el;
    el.root = root;
    el.title = h('div', { class: 'titlebar' });
    el.activity = h('div', { class: 'activitybar' });
    el.sidebar = h('div', { class: 'sidebar' });
    el.sideSplit = h('div', { class: 'splitter v' });
    el.tabs = h('div', { class: 'tabbar' });
    el.crumbs = h('div', { class: 'breadcrumbs' });
    el.banner = h('div', { class: 'banner' });
    el.editorHost = h('div', { class: 'editor-host' });
    el.welcome = h('div', { class: 'welcome scroll' });
    el.panelSplit = h('div', { class: 'splitter h' });
    el.panel = h('div', { class: 'panel' });
    el.editorCol = h('div', { class: 'editor-col' }, el.tabs, el.crumbs, el.banner, el.editorHost, el.welcome, el.panelSplit, el.panel);
    el.status = h('div', { class: 'statusbar' });
    el.palette = h('div', { class: 'palette-layer' });
    root.append(el.title, h('div', { class: 'main' }, el.activity, el.sidebar, el.sideSplit, el.editorCol), el.status, el.palette);
    splitter(el.sideSplit, 'x', (dx) => { this.sidebarW = Math.min(Math.max(this.sidebarW + dx, 180), 600); this.layout(); }, () => store.set('sidebarWidth', this.sidebarW));
    splitter(el.panelSplit, 'y', (dy) => { this.panelH = Math.min(Math.max(this.panelH - dy, 100), Math.max(120, el.editorCol.clientHeight - 140)); this.layout(); }, () => store.set('panelHeight', this.panelH));
    this.schedule = frameScheduler(() => this.flush());
    Coder.render = (...parts) => { for (const p of parts) this.dirty.add(p); this.schedule(); };
    Coder.applyDiagnostics = () => this.applyDiagnostics();
    Coder.applyPendingSelect = (doc) => this.applyPendingSelect(doc);
    HDLEditor.docFor = (model) => Coder.docs.find((d) => d.model === model) || null;
    HDLEditor.instanceModules = () => Coder.workspace.allModules;
    root.addEventListener('dragover', (e) => { if (e.dataTransfer.types.includes('Files')) { e.preventDefault(); root.classList.add('drop-target'); } });
    root.addEventListener('dragleave', (e) => { if (!root.contains(e.relatedTarget)) root.classList.remove('drop-target'); });
    root.addEventListener('drop', (e) => {
      root.classList.remove('drop-target');
      if (!e.dataTransfer.files.length) return;
      e.preventDefault();
      Coder.open([...e.dataTransfer.files].map((f) => Host.pathForFile(f)).filter(Boolean));
    });
    root.append(h('div', { class: 'drop-hint' }, icon('new-file'), ' Drop files to open them, or a folder to open it as the workspace'));
    HDLEditor.load().then(() => this.createEditor());
    Prefs.onChange((k) => {
      if (k.startsWith('editor.') && Coder.editor) Coder.editor.updateOptions(HDLEditor.options());
      if (k === 'themeID' && window.monaco) monaco.editor.setTheme('hdl-' + Prefs.get('themeID'));
      this.render('all');
    });
    Tools.onChange(() => this.render('status', 'welcome', 'panel'));
  },
  render(...p) { Coder.render(...p); },

  layout() {
    const el = this.el;
    const side = !!Coder.sidebarMode;
    el.sidebar.style.display = side ? '' : 'none';
    el.sideSplit.style.display = side ? '' : 'none';
    el.sidebar.style.width = this.sidebarW + 'px';
    const panel = Coder.showPanel;
    el.panel.style.display = panel ? '' : 'none';
    el.panelSplit.style.display = panel ? '' : 'none';
    el.panel.style.height = Math.min(this.panelH, Math.max(120, el.editorCol.clientHeight - 140)) + 'px';
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
    if (all || d.has('breadcrumbs')) this.renderCrumbs();
    if (all) this.renderBanner();
    if (all || d.has('editor')) this.showActive();
    if (all || d.has('welcome')) this.renderWelcome();
    if (all || d.has('panel')) this.renderPanel();
    if (all || d.has('status')) this.renderStatus();
    if (all || d.has('palette')) this.renderPalette();
    App.updateWindowTitle();
  },

  // ---------------------------------------------------------------- Editor

  createEditor() {
    const ed = HDLEditor.create(this.el.editorHost);
    Coder.editor = ed;
    const docOf = () => HDLEditor.docFor(ed.getModel());
    ed.onDidChangeModelContent((e) => {
      const doc = docOf();
      if (!doc) return;
      Coder.textChanged(doc);
      if (!e.isUndoing && !e.isRedoing && e.changes.length === 1 && e.changes[0].text.length === 1 && e.changes[0].rangeLength === 0) {
        const ch = e.changes[0].text;
        setTimeout(() => { if (docOf() === doc) Typing.afterType(doc, ed, ch); }, 0);
      }
    });
    ed.onDidChangeCursorSelection(() => { const doc = docOf(); if (doc) Coder.updateCaret(doc); });
    ed.onMouseDown((e) => {
      const b = e.event;
      if (!(IS_MAC ? b.metaKey : b.ctrlKey) || !b.leftButton || !e.target.position) return;
      const doc = docOf();
      if (!doc) return;
      const off = doc.model.getOffsetAt(e.target.position);
      const w = doc.wordAt(off);
      if (w) { setTimeout(() => Coder.goToDefinition(w[0], doc, off), 0); }
    });
    ed.onContextMenu((e) => this.editorMenu(e));
    ed.addCommand(monaco.KeyCode.Enter, () => {
      const doc = docOf();
      if (!doc || !Typing.newline(doc, ed)) ed.trigger('keyboard', 'type', { text: '\n' });
    }, 'editorTextFocus && !suggestWidgetVisible && !editorReadonly && !inSnippetMode');
    ed.addCommand(monaco.KeyCode.Tab, () => {
      if (!Typing.selectPlaceholder(ed, true)) ed.trigger('keyboard', 'tab', null);
    }, 'editorTextFocus && !suggestWidgetVisible && !inSnippetMode && !editorReadonly && !editorTabMovesFocus');
    ed.addCommand(monaco.KeyMod.Shift | monaco.KeyCode.Tab, () => {
      const m = ed.getModel(), sel = ed.getSelection();
      const s = m.getValueInRange(sel);
      if (/^<#[^#\n]*#>$/.test(s) && Typing.selectPlaceholder(ed, false)) return;
      ed.trigger('keyboard', 'outdent', null);
    }, 'editorTextFocus && !suggestWidgetVisible && !inSnippetMode && !editorReadonly');
    ed.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Space, () => ed.trigger('keyboard', 'editor.action.triggerSuggest', {}), 'editorTextFocus');
    this.render('all');
  },

  showActive() {
    const ed = Coder.editor;
    const doc = Coder.active;
    this.el.editorHost.style.display = doc ? '' : 'none';
    this.el.welcome.style.display = doc ? 'none' : '';
    if (!ed || !doc) return;
    const model = doc.ensureModel();
    if (ed.getModel() !== model) {
      const prev = HDLEditor.docFor(ed.getModel());
      if (prev) { prev.viewState = ed.saveViewState(); prev.lastOffset = prev.model.getOffsetAt(ed.getPosition()); }
      ed.setModel(model);
      if (doc.viewState) ed.restoreViewState(doc.viewState);
      else if (doc.initialSelection) {
        const p = model.getPositionAt(Math.min(doc.initialSelection, model.getValueLength()));
        ed.setPosition(p);
        ed.revealPositionInCenterIfOutsideViewport(p);
      }
      this.applyDiagnostics();
      Coder.updateCaret(doc);
      if (Shell.tab === 'coder' && !Coder.paletteMode && !document.querySelector('.modal-overlay')) setTimeout(() => ed.focus(), 0);
    }
    this.applyPendingSelect(doc);
  },

  applyPendingSelect(doc) {
    const ed = Coder.editor;
    if (!ed || !doc.model || ed.getModel() !== doc.model) { this.render('editor'); return; }
    const model = doc.model;
    let range = null;
    if (doc.pendingSelect) {
      const { offset, length } = doc.pendingSelect;
      const a = model.getPositionAt(Math.min(offset, model.getValueLength())), b = model.getPositionAt(Math.min(offset + length, model.getValueLength()));
      range = new monaco.Selection(a.lineNumber, a.column, b.lineNumber, b.column);
    } else if (doc.pendingReveal) {
      const { line, column, length } = doc.pendingReveal;
      const l = Math.min(Math.max(1, line), model.getLineCount());
      const c = Math.min(Math.max(1, column || 1), model.getLineMaxColumn(l));
      const start = model.getOffsetAt({ lineNumber: l, column: c });
      const b = model.getPositionAt(Math.min(start + (length || 0), model.getValueLength()));
      range = new monaco.Selection(l, c, b.lineNumber, b.column);
    }
    doc.pendingSelect = null;
    doc.pendingReveal = null;
    if (!range) return;
    ed.setSelection(range);
    ed.revealRangeInCenterIfOutsideViewport(range);
    if (Shell.tab === 'coder' && !Coder.paletteMode) ed.focus();
  },

  applyDiagnostics() {
    if (!window.monaco) return;
    const sev = { error: monaco.MarkerSeverity.Error, warning: monaco.MarkerSeverity.Warning, info: monaco.MarkerSeverity.Info };
    const inline = Prefs.get('editor.inlineDiagnostics');
    for (const doc of Coder.docs) {
      if (!doc.model) continue;
      const m = doc.model;
      const markers = doc.diagnostics.filter((d) => d.line >= 1 && d.line <= m.getLineCount()).map((d) => {
        const l = d.line;
        const content = m.getLineContent(l);
        let sc = /^[ \t]*/.exec(content)[0].length + 1, ec = content.replace(/\s+$/, '').length + 1;
        if (d.column) {
          sc = Math.min(d.column, content.length + 1);
          const off = m.getOffsetAt({ lineNumber: l, column: sc });
          const k = doc.tokenIndexTouching(off);
          if (k != null) { const t = doc.tokens()[k]; const a = m.getPositionAt(t.start), b = m.getPositionAt(t.end); sc = a.column; ec = b.lineNumber === l ? b.column : content.length + 1; }
          else ec = sc + 1;
        }
        if (ec <= sc) ec = sc + 1;
        return { severity: sev[d.severity], message: d.message, source: d.source, startLineNumber: l, startColumn: sc, endLineNumber: l, endColumn: ec };
      });
      monaco.editor.setModelMarkers(m, 'hdl', markers);
      // Messages at the end of the line (one per line, the most severe).
      const byLine = new Map();
      const rank = { error: 0, warning: 1, info: 2 };
      for (const d of doc.diagnostics) { const e = byLine.get(d.line); if (!e || rank[d.severity] < rank[e.severity]) byLine.set(d.line, d); }
      const decos = inline ? [...byLine.values()].filter((d) => d.line <= m.getLineCount()).map((d) => {
        let msg = d.message.split('\n')[0];
        if (msg.length > 160) msg = msg.slice(0, 157) + '…';
        const col = m.getLineMaxColumn(d.line);
        return { range: new monaco.Range(d.line, col, d.line, col), options: { showIfCollapsed: true, after: { content: '\u00A0\u00A0\u00A0\u00A0' + msg + '\u00A0', inlineClassName: `inline-diag ${d.severity}` } } };
      }) : [];
      doc._decos = m.deltaDecorations(doc._decos || [], decos);
      // <#placeholders#>
      const ph = [];
      const text = m.getValue();
      if (text.includes('<#')) {
        const re = /<#[^#\n]*#>/g; let x;
        while ((x = re.exec(text))) { const a = m.getPositionAt(x.index), b = m.getPositionAt(x.index + x[0].length); ph.push({ range: new monaco.Range(a.lineNumber, a.column, b.lineNumber, b.column), options: { inlineClassName: 'placeholder-token' } }); }
      }
      doc._ph = m.deltaDecorations(doc._ph || [], ph);
    }
  },

  editorMenu(e) {
    const doc = Coder.active;
    if (!doc) return;
    const ed = Coder.editor;
    const pos = e.target.position;
    if (pos) {
      const sel = ed.getSelection();
      if (sel.isEmpty() || !sel.containsPosition(pos)) ed.setPosition(pos);
    }
    const off = Coder.caretOffset(doc);
    const w = doc.wordAt(off);
    const act = (id) => () => { ed.focus(); ed.trigger('menu', id, null); };
    const items = [];
    if (w) items.push({ label: 'Go to Definition', accelerator: 'F12', action: () => Coder.goToDefinition(w[0], doc, off) },
      { label: 'Find All References', accelerator: 'Shift+F12', action: () => Coder.findReferences(w[0]) }, { type: 'separator' });
    if (doc.language !== 'plain') {
      items.push({ label: 'Copy Instantiation Template', accelerator: 'CmdOrCtrl+Shift+Alt+I', action: () => Coder.copyInstantiation() },
        { label: 'Generate Testbench', accelerator: 'CmdOrCtrl+Shift+G', action: () => Coder.generateTestbench() },
        { label: 'Insert Snippet…', accelerator: 'CmdOrCtrl+Shift+J', action: () => Coder.openPalette('snippet') }, { type: 'separator' },
        { label: 'Toggle Line Comment', accelerator: 'CmdOrCtrl+/', action: act('editor.action.commentLine') });
      if (HDLLanguage.isVerilogFamily(doc.language)) items.push({ label: 'Reindent Lines', accelerator: 'CmdOrCtrl+Alt+I', action: () => Coder.reindentCommand(false) });
      items.push({ type: 'separator' });
    }
    items.push({ label: 'Cut', accelerator: 'CmdOrCtrl+X', action: act('editor.action.clipboardCutAction') },
      { label: 'Copy', accelerator: 'CmdOrCtrl+C', action: act('editor.action.clipboardCopyAction') },
      { label: 'Paste', accelerator: 'CmdOrCtrl+V', action: () => { ed.focus(); const t = Host.clipboard.read(); ed.trigger('menu', 'paste', { text: t }); } },
      { type: 'separator' }, { label: 'Select All', accelerator: 'CmdOrCtrl+A', action: act('editor.action.selectAll') });
    Menus.popup(items, e.event.browserEvent);
  },

  // ---------------------------------------------------------------- Title bar

  renderTitle() {
    const t = currentTheme();
    const doc = Coder.active;
    const running = Coder.isRunning;
    const enabled = doc && doc.language !== 'plain';
    const down = Coder.descendTarget();
    const up = Coder.ascendTarget();
    const center = h('button', { class: 'command-center', title: `Go to File (${keyLabel('Ctrl+P')}) · Commands (${keyLabel('Ctrl+Shift+P')})`, onclick: () => Coder.openPalette('files', '') },
      icon('search'), h('span', null, Coder.workspace.root ? Coder.workspace.name : (doc ? doc.name : 'HDL Coder')));
    const run = h('button', { class: 'run-button' + (running ? ' running' : '') + (!enabled && !running ? ' disabled' : ''),
      title: running ? `Stop the simulation (${keyLabel('Ctrl+.')})` : `Compile and simulate this file with Icarus Verilog (${keyLabel('Ctrl+R')})`,
      onclick: () => { if (running) Coder.stopRun(); else if (enabled) Coder.runActive(); } },
    icon(running ? 'debug-stop' : 'play'), h('span', null, running ? 'Stop' : 'Run'));
    const ib = (name, title, action, disabled) => h('button', { class: 'tb-btn codicon codicon-' + name + (disabled ? ' disabled' : ''), title, onclick: disabled ? null : action });
    replaceKeepingFocus(this.el.title, [
      App.tabSwitcher(),
      h('div', { class: 'tb-spacer' }),
      center,
      h('div', { class: 'tb-spacer' }),
      run,
      ib('beaker', `Generate Testbench in HDL Tester (${keyLabel('Ctrl+Alt+T')})`, () => Coder.generateTestbenchInTester(), !doc || !doc.path || !HDLLanguage.isVerilogFamily(doc.language)),
      ib('pulse', `Open Last Waveform in HDL Viewer (${keyLabel('Ctrl+Shift+Y')})`, () => Coder.openLastWaveform(), !Coder.lastVCD),
      ib('pass', `Check File for Errors (${keyLabel('Ctrl+Shift+B')})`, () => Coder.lintActive(), !doc || doc.language === 'plain'),
      h('div', { class: 'tb-sep' }),
      ib('debug-step-into', down ? `Descend into ${down.def.symbol.name} (${keyLabel('Ctrl+Alt+Down')})` : `Descend into Module — put the caret on an instance (${keyLabel('Ctrl+Alt+Down')})`, () => Coder.descend(), !down),
      ib('debug-step-out', up ? `Ascend to ${up.label} (${keyLabel('Ctrl+Alt+Up')})` : `Ascend — nothing uses this module (${keyLabel('Ctrl+Alt+Up')})`, () => Coder.ascend(), !up),
      h('div', { class: 'tb-sep' }),
      ib(Coder.sidebarMode ? 'layout-sidebar-left' : 'layout-sidebar-left-off', `Toggle Sidebar (${keyLabel('Ctrl+B')})`, () => Coder.toggleSidebar()),
      ib(Coder.showPanel ? 'layout-panel' : 'layout-panel-off', `Toggle Panel (${keyLabel('Ctrl+J')})`, () => Coder.togglePanel()),
      App.menuButton(),
      h('div', { class: 'tb-overlay-space' }),
    ]);
    void t;
  },

  // ---------------------------------------------------------------- Activity bar

  renderActivity() {
    const modes = [['explorer', 'files', `Explorer (${keyLabel('Ctrl+Shift+E')})`], ['search', 'search', `Search (${keyLabel('Ctrl+Shift+F')})`],
      ['outline', 'list-tree', 'Outline'], ['hierarchy', 'type-hierarchy', 'Design Hierarchy'], ['snippets', 'symbol-snippet', 'Snippets']];
    const n = Coder.search.results.reduce((a, r) => a + r.matches.length, 0);
    this.el.activity.replaceChildren(
      ...modes.map(([m, ic, title]) => h('button', { class: 'ab-item' + (Coder.sidebarMode === m ? ' active' : ''), title,
        onclick: () => { Coder.sidebarMode = Coder.sidebarMode === m ? null : m; this.render('all'); } },
      icon(ic), m === 'search' && n ? h('span', { class: 'ab-badge' }, n > 999 ? '999+' : n) : null)),
      h('div', { class: 'ab-spacer' }),
      h('button', { class: 'ab-item', title: 'Manage', onclick: (e) => Menus.popup([
        { label: 'Color Theme', submenu: Object.values(THEMES).map((t) => ({ label: t.name, type: 'radio', checked: Prefs.get('themeID') === t.id, action: () => Prefs.set('themeID', t.id) })) },
        { type: 'separator' },
        { label: 'Command Palette…', accelerator: 'CmdOrCtrl+Shift+P', action: () => Coder.openPalette('commands') },
        { label: 'Open Example Project', action: () => Coder.openExamples() },
        { type: 'separator' },
        { label: 'Settings…', accelerator: 'CmdOrCtrl+,', action: () => App.openSettings() }], e.currentTarget) }, icon('settings-gear')));
  },

  // ---------------------------------------------------------------- Sidebar

  treeRow({ depth = 0, expandable = false, expanded = false, selected = false, title, detail = null, titleColor = null, italic = false, leading = null, trailing = null, onclick, ontoggle, oncontext, tooltip, draggable }) {
    return h('div', {
      class: 'trow' + (selected ? ' sel' : ''), style: `padding-left:${8 + depth * 12}px`, title: tooltip || null,
      onclick, oncontextmenu: oncontext ? (e) => { e.preventDefault(); oncontext(e); } : null, draggable: draggable ? 'true' : null,
      ondragstart: draggable ? (e) => draggable(e) : null,
    },
    expandable ? h('span', { class: `chev codicon codicon-${expanded ? 'chevron-down' : 'chevron-right'}`, onclick: (e) => { e.stopPropagation(); (ontoggle || onclick)(); } }) : h('span', { class: 'chev' }),
    leading,
    h('span', { class: 'nm' + (italic ? ' italic' : ''), style: titleColor ? `color:${titleColor}` : null }, title),
    detail ? h('span', { class: 'detail' }, detail) : null,
    h('span', { class: 'grow' }),
    trailing);
  },
  fileIcon(name) { const [ic, c] = fileStyle(currentTheme(), name); return icon(ic, 'ficon', `color:${c}`); },
  sectionHeader(title, open, toggle, actions = []) {
    return h('div', { class: 'section-header', onclick: toggle }, icon(open ? 'chevron-down' : 'chevron-right'), h('span', null, title), h('span', { class: 'grow' }),
      ...actions.map((a) => h('button', { class: 'icon-btn codicon codicon-' + a[0], title: a[1], onclick: (e) => { e.stopPropagation(); a[2](); } })));
  },

  renderSidebar() {
    const mode = Coder.sidebarMode;
    if (!mode) { this.el.sidebar.replaceChildren(); return; }
    const titles = { explorer: 'EXPLORER', search: 'SEARCH', outline: 'OUTLINE', hierarchy: 'DESIGN HIERARCHY', snippets: 'SNIPPETS' };
    const ws = Coder.workspace;
    let actions = [];
    if (mode === 'explorer') {
      actions = ws.root ? [['new-file', 'New File…', () => Coder.newFileIn(ws.root)], ['new-folder', 'New Folder…', () => Coder.newFolderIn(ws.root)],
        ['refresh', 'Refresh Explorer', () => ws.refreshListing()], ['collapse-all', 'Collapse Folders', () => { ws.expanded = new Set(); this.render('sidebar'); }]]
        : [['folder-opened', `Open Folder… (${keyLabel('Ctrl+Alt+O')})`, () => Coder.showOpenFolderPanel()]];
    } else if (mode === 'search') {
      actions = [['refresh', 'Refresh', () => Coder.runSearch()], ['clear-all', 'Clear Search Results', () => { Coder.search.options.query = ''; Coder.search.results = []; Coder.search.searched = false; this.render('sidebar', 'activity'); }],
        ['collapse-all', 'Collapse All', () => { Coder.search.collapsed = new Set(Coder.search.results.map((r) => r.path)); this.render('sidebar'); }]];
    } else if (mode === 'hierarchy') actions = [['refresh', 'Rescan Workspace', () => ws.refreshListing()]];
    else if (mode === 'snippets') actions = [['add', `Insert Snippet… (${keyLabel('Ctrl+Shift+J')})`, () => Coder.openPalette('snippet')]];
    const header = h('div', { class: 'sb-title' }, h('span', null, titles[mode]), h('span', { class: 'grow' }),
      ...actions.map((a) => h('button', { class: 'icon-btn codicon codicon-' + a[0], title: a[1], onclick: a[2] })));
    let body;
    if (mode === 'explorer') body = this.explorerPane();
    else if (mode === 'search') body = this.searchPane();
    else if (mode === 'outline') body = this.outlinePane();
    else if (mode === 'hierarchy') body = this.hierarchyPane();
    else body = this.snippetsPane();
    replaceKeepingFocus(this.el.sidebar, [header, ...body]);
  },

  explorerPane() {
    const ws = Coder.workspace;
    const t = currentTheme();
    const rows = [];
    rows.push(this.sectionHeader('OPEN EDITORS', !this.collapsed.openEditors, () => { this.collapsed.openEditors = !this.collapsed.openEditors; this.render('sidebar'); },
      [['save-all', `Save All (${keyLabel('Ctrl+Alt+S')})`, () => Coder.saveAll()], ['close-all', 'Close All Editors', () => Coder.closeAll()]]));
    if (!this.collapsed.openEditors) {
      for (const doc of Coder.docs) {
        rows.push(this.treeRow({ selected: doc.id === Coder.activeID, title: doc.name, detail: doc.path ? ws.relativePath(PathUtil.dirname(doc.path)) : null, italic: !doc.path,
          leading: this.fileIcon(doc.name), trailing: doc.isDirty ? h('span', { class: 'dirty-dot' }) : null, onclick: () => Coder.activate(doc),
          oncontext: (e) => Menus.popup([{ label: 'Close', action: () => Coder.close(doc) }, { label: 'Close Others', action: () => Coder.closeOthers(doc) }], e) }));
      }
      if (!Coder.docs.length) rows.push(h('div', { class: 'dim-row' }, 'No open editors'));
    }
    if (ws.root) {
      rows.push(this.sectionHeader(PathUtil.basename(ws.root).toUpperCase(), !this.collapsed.folder, () => { this.collapsed.folder = !this.collapsed.folder; this.render('sidebar'); },
        [['new-file', 'New File…', () => Coder.newFileIn(ws.root)]]));
      if (!this.collapsed.folder) {
        const problems = Coder.allProblems;
        const walk = (dir, depth) => {
          for (const item of ws.children(dir)) {
            const isActive = Coder.active && Coder.active.path && Paths.same(Coder.active.path, item.path);
            const errors = item.isDir ? 0 : problems.filter((p) => p.severity === 'error' && Paths.same(p.file, item.path)).length;
            const expanded = ws.expanded.has(item.path);
            rows.push(this.treeRow({ depth, expandable: item.isDir, expanded, selected: isActive, title: item.name, titleColor: errors ? t.error : null,
              leading: item.isDir ? icon(expanded ? 'folder-opened' : 'folder', 'ficon', `color:${t.dimFG}`) : this.fileIcon(item.name),
              trailing: errors ? h('span', { class: 'err-count' }, errors) : null, tooltip: item.path,
              onclick: () => { if (item.isDir) { ws.toggle(item.path); this.render('sidebar'); } else Coder.openFile(item.path); },
              oncontext: (e) => Menus.popup(item.isDir ? this.folderMenu(item.path) : this.fileMenu(item.path), e),
              draggable: (e) => { e.dataTransfer.setData('text/plain', item.path); } }));
            if (item.isDir && expanded) walk(item.path, depth + 1);
          }
        };
        walk(ws.root, 0);
      }
    } else {
      rows.push(h('div', { class: 'sidebar-empty' },
        h('div', null, 'You have not yet opened a folder.'),
        h('button', { class: 'vs-button', onclick: () => Coder.showOpenFolderPanel() }, 'Open Folder'),
        h('div', { class: 'dim' }, 'Opening a folder lets HDL Coder find your modules across files: the design hierarchy, go to definition, and automatic compile order.'),
        Coder.exampleDir() ? h('button', { class: 'vs-button secondary', onclick: () => Coder.openExamples() }, 'Open Example Project') : null));
    }
    return [h('div', { class: 'scroll', 'data-scroll-key': 'explorer' }, rows)];
  },
  folderMenu(p) {
    const items = [{ label: 'New File…', action: () => Coder.newFileIn(p) }, { label: 'New Folder…', action: () => Coder.newFolderIn(p) }, { type: 'separator' },
      { label: REVEAL_LABEL, action: () => Host.showInFolder(p) }, { label: 'Copy Path', action: () => copyText(p) }];
    if (!Paths.same(p, Coder.workspace.root)) items.push({ type: 'separator' }, { label: 'Rename…', action: () => Coder.rename(p) }, { label: 'Delete', action: () => Coder.moveToTrash(p) });
    return items;
  },
  fileMenu(p) {
    const e = Paths.ext(p);
    const items = [{ label: 'Open', action: () => Coder.openFile(p) }];
    if (['v', 'sv'].includes(e)) items.push({ label: 'Generate Testbench in HDL Tester', action: () => Coder.generateTestbenchInTesterFile(p) });
    if (['vcd', 'fst'].includes(e)) items.push({ label: 'Open in HDL Viewer', action: () => Viewer.open(p) });
    items.push({ type: 'separator' }, { label: REVEAL_LABEL, action: () => Host.showInFolder(p) },
      { label: 'Copy Path', action: () => copyText(p) }, { label: 'Copy Relative Path', action: () => copyText(Coder.workspace.relativePath(p)) },
      { type: 'separator' }, { label: 'Rename…', action: () => Coder.rename(p) }, { label: 'Delete', action: () => Coder.moveToTrash(p) });
    return items;
  },

  searchPane() {
    const s = Coder.search;
    const t = currentTheme();
    const opt = (key, ic, title) => h('button', { class: 'search-opt codicon codicon-' + ic + (s.options[key] ? ' on' : ''), title,
      onclick: () => { s.options[key] = !s.options[key]; Coder.runSearch(); this.render('sidebar'); } });
    const q = h('input', { class: 'bare-input', placeholder: 'Search', spellcheck: 'false', 'data-key': 'search-q', value: s.options.query,
      oninput: (e) => { s.options.query = e.target.value; Coder.runSearch(); }, onkeydown: (e) => { if (e.key === 'Enter') Coder.runSearch(); } });
    const top = h('div', { class: 'search-box' },
      h('button', { class: 'icon-btn codicon codicon-' + (s.showReplace ? 'chevron-down' : 'chevron-right'), title: 'Toggle Replace', onclick: () => { s.showReplace = !s.showReplace; this.render('sidebar'); } }),
      h('div', { class: 'search-fields' },
        h('div', { class: 'search-input' }, q, opt('caseSensitive', 'case-sensitive', 'Match Case'), opt('wholeWord', 'whole-word', 'Match Whole Word'), opt('regex', 'regex', 'Use Regular Expression')),
        s.showReplace ? h('div', { class: 'replace-row' },
          h('input', { class: 'vs-input', placeholder: 'Replace', spellcheck: 'false', 'data-key': 'search-r', value: s.replace, oninput: (e) => { s.replace = e.target.value; this.render('sidebar'); } }),
          h('button', { class: 'icon-btn codicon codicon-replace-all' + (s.results.length ? '' : ' disabled'), title: 'Replace All', onclick: () => Coder.replaceAll() })) : null));
    const details = h('div', { class: 'search-details' }, h('span', { class: 'grow' }), h('button', { class: 'icon-btn codicon codicon-ellipsis', title: 'Toggle Search Details', onclick: () => { this.showSearchInclude = !this.showSearchInclude; this.render('sidebar'); } }));
    const include = this.showSearchInclude ? [h('div', { class: 'small-label' }, 'files to include'),
      h('input', { class: 'vs-input', placeholder: 'e.g. *.v, rtl/**', 'data-key': 'search-inc', value: s.options.include, oninput: (e) => { s.options.include = e.target.value; Coder.runSearch(); } })] : [];
    let summary = null;
    const n = s.results.reduce((a, r) => a + r.matches.length, 0);
    if (s.running) summary = h('div', { class: 'small-dim' }, 'Searching…');
    else if (s.searched) {
      if (!SearchEngine.makeRegex(s.options) && s.options.query) summary = h('div', { class: 'small-dim', style: `color:${t.error}` }, 'Invalid regular expression');
      else if (!n) summary = h('div', { class: 'small-dim' }, 'No results found.' + (Coder.workspace.root ? '' : ' Open a folder to search all its files.'));
      else summary = h('div', { class: 'small-dim' }, `${n} result${n === 1 ? '' : 's'} in ${s.results.length} file${s.results.length === 1 ? '' : 's'}`);
    }
    const rows = [];
    let shown = 0;
    for (const r of s.results) {
      const collapsed = s.collapsed.has(r.path);
      rows.push(this.treeRow({ expandable: true, expanded: !collapsed, title: PathUtil.basename(r.path), detail: Coder.workspace.relativePath(PathUtil.dirname(r.path)),
        leading: this.fileIcon(r.path), trailing: h('span', { class: 'count-badge' }, r.matches.length),
        onclick: () => { if (collapsed) s.collapsed.delete(r.path); else s.collapsed.add(r.path); this.render('sidebar'); } }));
      if (collapsed) continue;
      for (const m of r.matches) {
        if (++shown > 3000) break;
        const pre = m.preview;
        const hit = pre.slice(m.start, m.start + m.length);
        const repl = s.showReplace && s.replace ? h('span', { class: 'repl' }, s.replace) : null;
        rows.push(h('div', { class: 'match-row', onclick: () => { const d = Coder.openFile(r.path); if (d) Coder.select(d, m.offset, m.matchLength); } },
          h('span', { class: 'preview' }, pre.slice(0, m.start), h('span', { class: 'hit' + (repl ? ' struck' : '') }, hit), repl, pre.slice(m.start + m.length)),
          h('span', { class: 'line-no' }, m.line + 1)));
      }
    }
    return [h('div', { class: 'search-pane' }, top, details, ...include, summary), h('div', { class: 'scroll', 'data-scroll-key': 'search' }, rows)];
  },

  outlinePane() {
    const doc = Coder.active;
    if (!doc) return [h('div', { class: 'dim-pad' }, 'Open a file to see its outline.')];
    const t = currentTheme();
    const filter = h('input', { class: 'vs-input', placeholder: 'Filter symbols', 'data-key': 'outline-filter', value: this.outlineFilter, oninput: (e) => { this.outlineFilter = e.target.value; this.render('sidebar'); } });
    const f = this.outlineFilter.toLowerCase();
    const caretLine = doc.caret.line - 1;
    const visible = (s) => (s.kind === 'instance' || s.kind === 'component' ? [] : s.children);
    const rows = [];
    const walk = (syms, depth) => {
      for (const s of syms) {
        const id = `${s.kind}:${s.name}:${s.line}:${s.offset}`;
        if (f) { if (s.name.toLowerCase().includes(f)) rows.push([s, 0, id]); walk(visible(s), 0); continue; }
        rows.push([s, depth, id]);
        if (!this.collapsed.outline.has(id)) walk(visible(s), depth + 1);
      }
    };
    walk(doc.symbols, 0);
    const detail = (s) => (s.kind === 'instance' ? s.target || '' : (s.kind === 'param' || s.kind === 'constant') ? (s.value != null ? `= ${s.value}` : '') : s.detail);
    const list = rows.map(([s, depth, id]) => {
      const current = s.line <= caretLine && caretLine <= s.endLine && !SymbolKinds.isContainer(s.kind) && ['process', 'function', 'task', 'instance'].includes(s.kind);
      const color = s.kind === 'port' ? dirColor(t, s.dir || '') : symbolColor(t, s.kind);
      return this.treeRow({ depth, expandable: visible(s).length > 0 && !f, expanded: !this.collapsed.outline.has(id), selected: current, title: s.name, detail: detail(s),
        leading: icon(SymbolKinds.icon(s.kind), 'ficon', `color:${color}`), tooltip: `${SymbolKinds.label(s.kind)} ${s.name}${s.detail ? ' — ' + s.detail : ''} · line ${s.line + 1}`,
        onclick: () => Coder.goToSymbol(s, doc.path),
        ontoggle: () => { if (this.collapsed.outline.has(id)) this.collapsed.outline.delete(id); else this.collapsed.outline.add(id); this.render('sidebar'); } });
    });
    if (!doc.symbols.length) list.push(h('div', { class: 'dim-pad' }, doc.language === 'plain' ? 'The outline is available for Verilog, SystemVerilog and VHDL files.' : 'No modules found in this file.'));
    return [h('div', { class: 'pad-x' }, filter), h('div', { class: 'scroll', 'data-scroll-key': 'outline' }, list)];
  },

  hierarchyPane() {
    const ws = Coder.workspace;
    const t = currentTheme();
    const tops = ws.hierarchy();
    const rows = [];
    if (!tops.length) rows.push(h('div', { class: 'dim-pad' }, ws.indexing ? 'Scanning…' : 'No modules found. Open a folder with Verilog, SystemVerilog or VHDL files.'));
    const open = (n) => {
      const def = ws.definitions(n.module)[0];
      if (def) Coder.goToSymbol(def.symbol, def.path); else if (n.file) Coder.goTo(n.file, n.line + 1);
    };
    const walk = (nodes, depth) => {
      for (const n of nodes) {
        rows.push(this.treeRow({ depth, expandable: n.children.length > 0, expanded: !this.collapsed.hierarchy.has(n.id), title: n.instance || n.module,
          detail: n.instance ? n.module : (n.children.length ? 'top' : null), titleColor: n.missing ? t.error : null,
          leading: icon(n.instance == null ? 'symbol-class' : (n.missing ? 'question' : 'symbol-module'), 'ficon', `color:${n.missing ? t.error : symbolColor(t, n.instance == null ? 'module' : 'instance')}`),
          tooltip: n.missing ? `Module “${n.module}” is not defined in the workspace` : (n.recursive ? 'Recursive instantiation' : n.module),
          onclick: () => open(n),
          ontoggle: () => { if (this.collapsed.hierarchy.has(n.id)) this.collapsed.hierarchy.delete(n.id); else this.collapsed.hierarchy.add(n.id); this.render('sidebar'); },
          oncontext: (e) => {
            const def = ws.definitions(n.module)[0];
            const items = [];
            if (def) items.push({ label: 'Go to Module Definition', action: () => Coder.goToSymbol(def.symbol, def.path) });
            if (n.instance && n.file) items.push({ label: 'Go to Instance', action: () => Coder.goTo(n.file, n.line + 1) });
            if (items.length) Menus.popup(items, e);
          } }));
        if (!this.collapsed.hierarchy.has(n.id)) walk(n.children, depth + 1);
      }
    };
    walk(tops, 0);
    return [h('div', { class: 'scroll', 'data-scroll-key': 'hier' }, rows)];
  },

  snippetsPane() {
    const doc = Coder.active;
    const lang = doc && doc.language !== 'plain' ? doc.language : 'verilog';
    return [h('div', { class: 'scroll' },
      h('div', { class: 'dim-pad' }, 'Click to insert at the cursor, or type the prefix in the editor and pick it from the suggestions. Tab jumps between the placeholders.'),
      Snippets.available(lang).map((s) => this.treeRow({ title: s.prefix, detail: s.title,
        leading: icon(s.family === 'vhdl' ? 'bracket' : (s.family === 'systemVerilog' ? 'symbol-structure' : 'symbol-snippet'), 'ficon'),
        tooltip: s.body.replace(/\t/g, '    '),
        onclick: () => { const d = Coder.active; if (d && d.language !== 'plain') Coder.insertSnippet(d, s); else showToast('Open a Verilog or VHDL file first'); } })))];
  },

  // ---------------------------------------------------------------- Tabs, breadcrumbs, banner

  renderTabs() {
    const t = currentTheme();
    if (!Coder.docs.length) { this.el.tabs.style.display = 'none'; return; }
    this.el.tabs.style.display = '';
    const tabs = Coder.docs.map((doc) => {
      const errors = doc.diagnostics.filter((d) => d.severity === 'error').length;
      const active = doc.id === Coder.activeID;
      return h('div', { class: 'tab' + (active ? ' active' : '') + (doc.isDirty ? ' dirty' : ''), title: doc.path || 'Not saved yet',
        onmousedown: (e) => { if (e.button === 1) { e.preventDefault(); Coder.close(doc); } },
        onclick: () => Coder.activate(doc),
        oncontextmenu: (e) => {
          e.preventDefault();
          const items = [{ label: 'Close', action: () => Coder.close(doc) }, { label: 'Close Others', action: () => Coder.closeOthers(doc) }, { label: 'Close All', action: () => Coder.closeAll() },
            { type: 'separator' }, { label: 'Save', action: () => Coder.save(doc) }, { label: 'Save As…', action: () => Coder.save(doc, true) }];
          if (doc.path) items.push({ type: 'separator' }, { label: 'Copy Path', action: () => copyText(doc.path) },
            { label: REVEAL_LABEL, action: () => Host.showInFolder(doc.path) },
            { label: 'Reveal in Explorer', action: () => { Coder.workspace.reveal(doc.path); Coder.sidebarMode = 'explorer'; this.render('all'); } });
          Menus.popup(items, e);
        } },
      this.fileIcon(doc.name),
      h('span', { class: 'tab-name' + (doc.path ? '' : ' italic'), style: errors ? `color:${t.error}` : null }, doc.name),
      errors ? h('span', { class: 'tab-err' }, errors) : null,
      h('button', { class: 'tab-close', title: `Close (${keyLabel('Ctrl+W')})`, onclick: (e) => { e.stopPropagation(); Coder.close(doc); } },
        h('span', { class: 'dot' }), icon('close')));
    });
    const strip = h('div', { class: 'tab-strip' }, tabs);
    this.el.tabs.replaceChildren(strip, h('button', { class: 'icon-btn codicon codicon-add tab-add', title: `New File (${keyLabel('Ctrl+N')})`, onclick: () => Coder.newFile() }));
    const act = strip.querySelector('.tab.active');
    if (act) act.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  },

  renderCrumbs() {
    const doc = Coder.active;
    if (!doc) { this.el.crumbs.style.display = 'none'; return; }
    this.el.crumbs.style.display = '';
    const ws = Coder.workspace;
    let parts = [];
    if (doc.path) {
      const dir = PathUtil.dirname(doc.path);
      if (ws.root && Paths.isUnder(doc.path, ws.root)) parts = [PathUtil.basename(ws.root), ...dir.slice(ws.root.length).split(/[\\/]/).filter(Boolean)];
      else parts = Paths.tilde(dir).split(/[\\/]/).filter(Boolean).slice(-2);
    }
    const chev = () => icon('chevron-right', 'crumb-chev');
    const items = [];
    parts.forEach((p, i) => { if (i) items.push(chev()); items.push(h('span', null, p)); });
    if (parts.length) items.push(chev());
    items.push(this.fileIcon(doc.name), h('span', null, doc.name));
    for (const s of doc.caret.symbolPath) { items.push(chev(), h('span', { class: 'crumb-link', onclick: () => Coder.openPalette('symbols') }, s)); }
    this.el.crumbs.replaceChildren(...items);
  },

  renderBanner() {
    const doc = Coder.active;
    if (!doc || !doc.changedOnDisk) { this.el.banner.style.display = 'none'; return; }
    this.el.banner.style.display = '';
    this.el.banner.replaceChildren(icon('warning', 'warn-icon'), h('span', null, `“${doc.name}” changed on disk while you have unsaved edits.`), h('span', { class: 'grow' }),
      h('button', { class: 'vs-button secondary small', onclick: () => Coder.revert(doc) }, 'Reload from Disk'),
      h('button', { class: 'vs-button small', onclick: () => { doc.changedOnDisk = false; this.render('all'); } }, 'Keep My Version'));
  },

  // ---------------------------------------------------------------- Welcome

  renderWelcome() {
    if (Coder.active) return;
    const link = (ic, title, detail, action) => h('div', { class: 'link-row' }, icon(ic), h('span', { class: 'link', onclick: action }, title), h('span', { class: 'dim small' }, detail));
    const recentRow = (p, folder) => h('div', { class: 'recent-row' }, icon(folder ? 'folder' : 'file'), h('span', { class: 'link', onclick: () => Coder.open([p]) }, PathUtil.basename(p)),
      h('span', { class: 'dim', title: p }, Paths.tilde(PathUtil.dirname(p))));
    const shortcut = (title, keys) => h('div', { class: 'shortcut-row' }, h('span', null, title), h('span', { class: 'mono dim' }, keys));
    const tool = (name, path, hint) => h('div', { class: 'tool-row', title: path || hint }, icon(path ? 'pass-filled' : 'circle-large-outline', path ? 'ok' : 'dim'), h('span', null, name), h('span', { class: 'dim small' }, path ? 'found' : hint));
    const viewer = Viewer.path();
    this.el.welcome.replaceChildren(h('div', { class: 'welcome-inner' },
      h('div', null, h('h1', null, 'HDL Coder'), h('div', { class: 'subtitle' }, 'A code editor for Verilog, SystemVerilog and VHDL')),
      h('div', { class: 'cols' },
        h('div', { class: 'col' }, h('h2', null, 'Start'),
          link('new-file', 'New File', keyLabel('Ctrl+N'), () => Coder.newFile()),
          link('file-code', 'New File from Template…', keyLabel('Ctrl+Alt+N'), () => Coder.openPalette('newFile')),
          link('go-to-file', 'Open File…', keyLabel('Ctrl+O'), () => Coder.showOpenPanel()),
          link('folder-opened', 'Open Folder…', keyLabel('Ctrl+Alt+O'), () => Coder.showOpenFolderPanel()),
          Coder.exampleDir() ? link('chip', 'Open Example Project', 'counter, UART, adder', () => Coder.openExamples()) : null),
        h('div', { class: 'col grow' }, h('h2', null, 'Recent'),
          !Coder.recentFolders.length && !Coder.recentFiles.length ? h('div', { class: 'dim' }, 'Nothing opened yet') : null,
          Coder.recentFolders.slice(0, 5).map((p) => recentRow(p, true)), Coder.recentFiles.slice(0, 6).map((p) => recentRow(p, false)))),
      h('div', { class: 'cols' },
        h('div', { class: 'col' }, h('h2', null, 'Shortcuts'),
          shortcut('Go to file / command palette', `${keyLabel('Ctrl+P')}  ·  ${keyLabel('Ctrl+Shift+P')}`),
          shortcut('Go to definition', `F12  ·  ${keyLabel('Ctrl')}-click`),
          shortcut('Suggestions / next placeholder', `${keyLabel('Ctrl+Space')}  ·  Tab`),
          shortcut('Toggle comment', keyLabel('Ctrl+/')),
          shortcut('Move / copy line', 'Alt+↑↓  ·  Shift+Alt+↑↓'),
          shortcut('Testbench in HDL Tester', keyLabel('Ctrl+Alt+T')),
          shortcut('Descend / ascend hierarchy', `${keyLabel('Ctrl+Alt+↓')}  ·  ${keyLabel('Ctrl+Alt+↑')}`),
          shortcut('Run simulation', `${keyLabel('Ctrl+R')}  ·  F5`)),
        h('div', { class: 'col' }, h('h2', null, 'Tools'),
          tool('Icarus Verilog', Tools.iverilog, INSTALL_HINT.iverilog),
          tool('Verilator', Tools.verilator, 'optional'),
          tool('GHDL', Tools.ghdl, 'for VHDL (optional)'),
          tool('HDL Viewer', viewer, 'opens waveforms')))));
  },

  // ---------------------------------------------------------------- Panel

  renderPanel() {
    if (!Coder.showPanel) return;
    const t = currentTheme();
    const problems = Coder.allProblems;
    const tab = (id, title) => {
      const on = Coder.panelTab === id;
      const count = id === 'problems' ? problems.length : 0;
      return h('button', { class: 'panel-tab' + (on ? ' active' : ''), onclick: () => { Coder.panelTab = id; this.render('panel'); } }, title,
        count ? h('span', { class: 'count-pill' + (problems.some((p) => p.severity === 'error') ? ' err' : '') }, count) : null,
        id === 'output' && Coder.isRunning ? icon('loading', 'spin small') : null);
    };
    const ib = (ic, title, action) => h('button', { class: 'icon-btn codicon codicon-' + ic, title, onclick: action });
    const actions = [];
    const doc = Coder.active;
    if (Coder.panelTab === 'problems') actions.push(ib('refresh', `Check Again (${keyLabel('Ctrl+Shift+B')})`, () => Coder.lintActive()));
    else {
      if (Coder.lastVCD) actions.push(ib('pulse', `Open Waveform in HDL Viewer (${keyLabel('Ctrl+Shift+Y')})`, () => Coder.openLastWaveform()));
      const simOut = doc && doc.path ? PathUtil.join(PathUtil.dirname(doc.path), 'sim_out') : null;
      if (simOut && Host.fs.exists(simOut)) actions.push(ib('folder', 'Reveal sim_out Folder', () => Host.openPath(simOut)));
      actions.push(ib('copy', 'Copy Output', () => copyText(Coder.output.map((l) => l.text).join('\n'))), ib('trash', 'Clear Output', () => { Coder.output = []; this.render('panel'); }));
    }
    const header = h('div', { class: 'panel-header' }, tab('problems', 'PROBLEMS'), tab('output', 'OUTPUT'), h('span', { class: 'grow' }), ...actions,
      ib('close', `Close Panel (${keyLabel('Ctrl+J')})`, () => { Coder.showPanel = false; this.render('all'); }));
    let body;
    if (Coder.panelTab === 'problems') {
      const rows = [];
      if (!problems.length) {
        const hasLinter = Tools.iverilog || Tools.verilator || (doc && doc.language === 'vhdl' && Tools.ghdl);
        rows.push(h('div', { class: 'dim-pad selectable' }, !hasLinter ? (doc && doc.language === 'vhdl' ? 'Install GHDL to check VHDL files as you type.' : 'Install Icarus Verilog to check your code as you type.')
          : Coder.linterKind === 'off' ? 'Checking is turned off in Settings.' : `No problems have been detected${Coder.lastLintTool ? ` (checked with ${Coder.lastLintTool})` : ''}.`));
      }
      const groups = new Map();
      for (const p of problems) { if (!groups.has(p.file)) groups.set(p.file, []); groups.get(p.file).push(p); }
      const order = [...groups.keys()].sort((a, b) => (doc && a === doc.key ? -1 : doc && b === doc.key ? 1 : a < b ? -1 : 1));
      this.collapsedProblems = this.collapsedProblems || new Set();
      for (const file of order) {
        const list = groups.get(file);
        let name = PathUtil.basename(file), detail = Coder.workspace.relativePath(PathUtil.dirname(file));
        if (file.startsWith('untitled:')) { const d = Coder.docs.find((x) => x.key === file); name = d ? d.name : 'Untitled'; detail = ''; }
        const collapsed = this.collapsedProblems.has(file);
        rows.push(this.treeRow({ expandable: true, expanded: !collapsed, title: name, detail, leading: this.fileIcon(name), trailing: h('span', { class: 'count-badge' }, list.length),
          onclick: () => { if (collapsed) this.collapsedProblems.delete(file); else this.collapsedProblems.add(file); this.render('panel'); } }));
        if (collapsed) continue;
        for (const d of list) {
          const color = d.severity === 'error' ? t.error : d.severity === 'warning' ? t.warning : t.info;
          rows.push(h('div', { class: 'problem-row', onclick: () => Coder.goTo(d.file, d.line, d.column),
            oncontextmenu: (e) => { e.preventDefault(); Menus.popup([{ label: 'Copy Message', action: () => copyText(`${d.file}:${d.line}: ${d.message}`) }], e); } },
          icon(d.severity === 'error' ? 'error' : d.severity === 'warning' ? 'warning' : 'info', '', `color:${color}`),
          h('span', { class: 'msg' }, d.message), h('span', { class: 'dim' }, d.source), h('span', { class: 'dim' }, `[Ln ${d.line}${d.column ? `, Col ${d.column}` : ''}]`)));
        }
      }
      body = h('div', { class: 'scroll panel-body', 'data-scroll-key': 'problems' }, rows);
    } else {
      const lines = Coder.output.map((l) => {
        const color = { info: t.dimFG, command: Syntax.colors(t).keyword, stdout: t.fg, error: t.error, warning: t.warning, success: t.success }[l.kind];
        return l.link ? h('div', { class: 'out-line link', style: `color:${color}`, title: `Go to ${PathUtil.basename(l.link.path)}:${l.link.line}`, onclick: () => Coder.goTo(l.link.path, l.link.line) }, l.text)
          : h('div', { class: 'out-line', style: `color:${color}` }, l.text || ' ');
      });
      if (!lines.length) lines.push(h('div', { class: 'dim-pad' }, `Press Run (${keyLabel('Ctrl+R')}) to compile and simulate the active file. The top module without ports is used as the testbench; modules it instantiates are found in the open folder.`));
      body = h('div', { class: 'scroll panel-body output selectable' }, lines);
    }
    const prev = this.el.panel.querySelector('.panel-body.output');
    const atBottom = !prev || prev.scrollTop + prev.clientHeight >= prev.scrollHeight - 30;
    replaceKeepingFocus(this.el.panel, [header, body]);
    if (Coder.panelTab === 'output' && atBottom) body.scrollTop = body.scrollHeight;
  },

  // ---------------------------------------------------------------- Status bar

  renderStatus() {
    const t = currentTheme();
    const found = !!Tools.iverilog;
    const problems = Coder.allProblems;
    const errors = problems.filter((p) => p.severity === 'error').length, warnings = problems.filter((p) => p.severity === 'warning').length;
    const doc = Coder.active;
    const items = [
      h('div', { class: 'sb-item sb-accent' + (found ? '' : ' sb-error'), title: found ? Tools.iverilog : Tools.installHint() },
        icon(found ? 'chip' : 'warning'), found ? `Icarus Verilog ${Tools.iverilogVersion || ''}` : 'Icarus Verilog not found'),
      h('div', { class: 'sb-item clickable', title: `Show Problems (${keyLabel('Ctrl+Shift+M')})`, onclick: () => Coder.togglePanel('problems') }, icon('error'), String(errors), icon('warning', 'gap'), String(warnings)),
    ];
    if (doc && Coder.linting.has(doc.key)) items.push(h('div', { class: 'sb-item' }, icon('loading', 'spin'), 'Checking…'));
    const rs = Coder.runStatus;
    const runLabel = { compiling: ['tools', 'Compiling…'], simulating: ['play', 'Simulating…'], passed: ['pass', 'Simulation finished' + (Coder.lastRunSeconds != null ? ` in ${Coder.lastRunSeconds.toFixed(2)} s` : '')],
      failed: ['error', rs.why], stopped: ['debug-stop', 'Stopped'] }[rs.kind];
    if (runLabel) items.push(h('div', { class: 'sb-item clickable', onclick: () => Coder.togglePanel('output') }, icon(runLabel[0]), runLabel[1]));
    items.push(h('div', { class: 'sb-spacer' }));
    if (doc) {
      const c = doc.caret;
      if (c.numberHint) items.push(h('div', { class: 'sb-item mono', title: 'Value of the number at the cursor' }, c.numberHint));
      items.push(h('div', { class: 'sb-item clickable', title: `Go to Line (${keyLabel('Ctrl+G')})`, onclick: () => Coder.openPalette('line') },
        `Ln ${c.line}, Col ${c.column}` + (c.selected > 0 ? ` (${c.selected} selected${c.selectedLines > 1 ? `, ${c.selectedLines} lines` : ''})` : '')));
      items.push(h('div', { class: 'sb-item clickable', onclick: (e) => Menus.popup([
        { type: 'header', label: 'Indent Using Spaces' }, ...[2, 3, 4, 8].map((n) => ({ label: `Spaces: ${n}`, action: () => Coder.setIndentation(true, n) })),
        { type: 'separator' }, { type: 'header', label: 'Indent Using Tabs' }, ...[2, 4, 8].map((n) => ({ label: `Tab Size: ${n}`, action: () => Coder.setIndentation(false, n) })),
        { type: 'separator' }, { label: 'Convert Indentation to Spaces', action: () => Coder.convertIndentation(doc, true) }, { label: 'Convert Indentation to Tabs', action: () => Coder.convertIndentation(doc, false) }], e.currentTarget) },
      doc.useSpaces ? `Spaces: ${doc.tabSize}` : `Tab Size: ${doc.tabSize}`));
      items.push(h('div', { class: 'sb-item' }, 'UTF-8'), h('div', { class: 'sb-item' }, doc.lineEnding));
      items.push(h('div', { class: 'sb-item clickable', title: 'Select Language Mode', onclick: (e) => Menus.popup(HDLLanguage.all.map((l) => ({ label: HDLLanguage.displayName(l), type: 'radio', checked: doc.language === l,
        action: () => { doc.setLanguage(l); Coder.scheduleLint(doc, 0); this.render('all'); } })), e.currentTarget) }, icon('bracket'), HDLLanguage.displayName(doc.language)));
    }
    this.el.status.replaceChildren(...items);
    void t;
  },

  // ---------------------------------------------------------------- Command palette

  paletteEffectiveMode() {
    const mode = Coder.paletteMode || 'files';
    if (!['files', 'commands', 'symbols', 'line', 'modules'].includes(mode)) return mode;
    const t = Coder.paletteText;
    if (t.startsWith('>')) return 'commands';
    if (t.startsWith('@')) return 'symbols';
    if (t.startsWith(':')) return 'line';
    if (t.startsWith('#')) return 'modules';
    return 'files';
  },
  paletteQuery() {
    const m = this.paletteEffectiveMode();
    const t = Coder.paletteText;
    return ['commands', 'symbols', 'line', 'modules'].includes(m) ? t.slice(1).trim() : t.trim();
  },
  paletteItems() {
    const mode = this.paletteEffectiveMode();
    const q = this.paletteQuery();
    const t = currentTheme();
    const ws = Coder.workspace;
    const ranked = (items, key, limit = 200) => {
      if (!q) return items.slice(0, limit);
      const out = [];
      for (const it of items) { const s = Fuzzy.score(q, key(it)); if (s != null) { it.score = s; out.push(it); } }
      return out.sort((a, b) => b.score - a.score).slice(0, limit);
    };
    const doc = Coder.active;
    switch (mode) {
      case 'files': {
        const paths = [], seen = new Set();
        const push = (p) => { const k = IS_WIN ? p.toLowerCase() : p; if (!seen.has(k)) { seen.add(k); paths.push(p); } };
        for (const d of Coder.docs) if (d.path) push(d.path);
        for (const p of Coder.recentFiles) if (Host.fs.exists(p) && (!ws.root || Paths.isUnder(p, ws.root))) push(p);
        for (const p of ws.files) push(p);
        let items = paths.map((p) => {
          const [ic, c] = fileStyle(t, p);
          return { icon: ic, color: c, title: PathUtil.basename(p), detail: ws.relativePath(PathUtil.dirname(p)), trailing: Coder.docs.some((d) => d.path && Paths.same(d.path, p)) ? 'open' : '', action: () => Coder.openFile(p) };
        });
        for (const d of Coder.docs) if (!d.path) items.unshift({ icon: 'file', title: d.name, detail: '', trailing: 'open', action: () => Coder.activate(d) });
        if (!q) return items.slice(0, 60);
        const out = [];
        for (const it of items) {
          const a = Fuzzy.score(q, it.title), b = Fuzzy.score(q, it.detail + '/' + it.title);
          const s = Math.max(a != null ? a + 30 : -Infinity, b != null ? b : -Infinity);
          if (s > -Infinity) { it.score = s; out.push(it); }
        }
        return out.sort((x, y) => y.score - x.score).slice(0, 100);
      }
      case 'commands': return ranked(Coder.commands().map((c) => ({ icon: 'chevron-right', title: c.title, trailing: c.shortcut ? keyLabel(c.shortcut) : '', action: c.action })), (i) => i.title);
      case 'symbols': {
        if (!doc) return [];
        const syms = doc.symbols.flatMap((s) => [s, ...s.children.flatMap((c) => [c, ...(c.kind === 'instance' ? [] : c.children)])]);
        return ranked(syms.map((s) => ({ icon: SymbolKinds.icon(s.kind), color: symbolColor(t, s.kind), title: s.name, detail: s.kind === 'instance' ? (s.target || '') : s.detail, trailing: SymbolKinds.label(s.kind), action: () => Coder.goToSymbol(s, doc.path) })), (i) => i.title);
      }
      case 'line': {
        if (!doc) return [];
        const parts = q.split(':').map((x) => parseInt(x.trim(), 10));
        if (!(parts[0] > 0)) return [];
        const line = Math.min(parts[0], doc.caret.totalLines);
        const col = parts.length > 1 && parts[1] > 0 ? parts[1] : null;
        return [{ icon: 'arrow-right', title: `Go to line ${line}` + (col ? `, column ${col}` : ''), action: () => { Coder.recordNav(); Coder.reveal(doc, line, col); } }];
      }
      case 'modules': case 'instance': {
        const insert = mode === 'instance';
        return ranked(ws.allModules.map((d) => ({ icon: SymbolKinds.icon(d.symbol.kind), color: symbolColor(t, d.symbol.kind), title: d.symbol.name, detail: ws.relativePath(d.path), trailing: `${symPorts(d.symbol).length} ports`,
          action: () => { if (insert) Coder.insertInstance(d.symbol); else Coder.goToSymbol(d.symbol, d.path); } })), (i) => i.title);
      }
      case 'snippet': {
        const lang = doc && doc.language !== 'plain' ? doc.language : 'verilog';
        return ranked(Snippets.available(lang).map((s) => ({ icon: 'symbol-snippet', title: s.prefix, detail: s.title, action: () => { const d = Coder.active; if (d && d.language !== 'plain') Coder.insertSnippet(d, s); else showToast('Open a Verilog or VHDL file first'); } })), (i) => i.title + ' ' + i.detail);
      }
      case 'theme': return Object.values(THEMES).map((th) => ({ icon: th.dark ? 'color-mode' : 'lightbulb', title: th.name, trailing: th.id === (this.paletteOriginalTheme || Prefs.get('themeID')) ? 'current' : '', themeId: th.id, action: () => Prefs.set('themeID', th.id) }));
      case 'newFile': return ranked(Templates.kinds.map((k) => ({ icon: k.ext === 'vhd' ? 'bracket' : 'code', title: k.title, detail: '.' + k.ext,
        action: () => Coder.newFile({ kind: k.id, name: k.id === 'empty' ? null : k.defaultName, language: k.ext === 'vhd' ? 'vhdl' : (k.ext === 'sv' ? 'systemVerilog' : 'verilog') }) })), (i) => i.title);
      case 'language': return HDLLanguage.all.map((l) => ({ icon: 'bracket', title: HDLLanguage.displayName(l), trailing: doc && doc.language === l ? 'current' : '', action: () => { if (doc) { doc.setLanguage(l); Coder.scheduleLint(doc, 0); this.render('all'); } } }));
      default: return [];
    }
  },
  renderPalette() {
    const layer = this.el.palette;
    if (!Coder.paletteMode) { layer.style.display = 'none'; layer.replaceChildren(); this.paletteOriginalTheme = null; return; }
    layer.style.display = '';
    const mode = this.paletteEffectiveMode();
    if (mode === 'theme' && !this.paletteOriginalTheme) { this.paletteOriginalTheme = Prefs.get('themeID'); this.paletteSel = Object.keys(THEMES).indexOf(this.paletteOriginalTheme); }
    const items = this.paletteItems();
    this.paletteSel = Math.min(Math.max(0, this.paletteSel), Math.max(0, items.length - 1));
    const placeholders = {
      files: 'Search files by name (type > for commands, @ for symbols, : for a line, # for modules)', commands: 'Type a command', symbols: 'Go to symbol in file',
      line: 'Type a line number', modules: 'Go to module or entity in the workspace', instance: 'Choose a module to instantiate at the cursor', snippet: 'Choose a snippet to insert',
      theme: 'Select a color theme', newFile: 'Choose a template for the new file', language: 'Select the language of this file',
    };
    const run = (i) => {
      const it = items[i];
      if (!it) return;
      const before = [Coder.paletteMode, Coder.paletteText];
      this.paletteOriginalTheme = null;
      Coder.paletteMode = null;
      it.action();
      if (Coder.paletteMode == null || (Coder.paletteMode === before[0] && Coder.paletteText === before[1])) Coder.closePalette();
      else this.render('palette');
    };
    const cancel = () => { if (this.paletteOriginalTheme) Prefs.set('themeID', this.paletteOriginalTheme); this.paletteOriginalTheme = null; Coder.closePalette(); };
    const preview = () => { if (mode === 'theme' && items[this.paletteSel]) Prefs.set('themeID', items[this.paletteSel].themeId); };
    const input = h('input', { class: 'palette-input', spellcheck: 'false', placeholder: placeholders[mode], 'data-key': 'palette', value: Coder.paletteText,
      oninput: (e) => { Coder.paletteText = e.target.value; this.paletteSel = 0; this.render('palette'); },
      onkeydown: (e) => {
        if (e.key === 'ArrowDown') { e.preventDefault(); this.paletteSel = Math.min(this.paletteSel + 1, items.length - 1); preview(); this.render('palette'); }
        else if (e.key === 'ArrowUp') { e.preventDefault(); this.paletteSel = Math.max(this.paletteSel - 1, 0); preview(); this.render('palette'); }
        else if (e.key === 'PageDown') { e.preventDefault(); this.paletteSel = Math.min(this.paletteSel + 10, items.length - 1); this.render('palette'); }
        else if (e.key === 'PageUp') { e.preventDefault(); this.paletteSel = Math.max(this.paletteSel - 10, 0); this.render('palette'); }
        else if (e.key === 'Escape') { e.preventDefault(); cancel(); }
        else if (e.key === 'Enter') { e.preventDefault(); run(this.paletteSel); }
      } });
    let list;
    if (items.length) {
      list = h('div', { class: 'palette-list' }, items.map((it, i) => h('div', { class: 'palette-row' + (i === this.paletteSel ? ' sel' : ''), onmousedown: (e) => { e.preventDefault(); run(i); } },
        icon(it.icon, 'pi', it.color ? `color:${it.color}` : ''), h('span', { class: 'pt' }, it.title), h('span', { class: 'pd' }, it.detail || ''), h('span', { class: 'grow' }),
        it.trailing ? h('span', { class: 'pk' }, it.trailing) : null)));
    } else {
      let empty = 'No matching results.';
      if (mode === 'line') empty = doc0() ? `Current line: ${doc0().caret.line}. Type a line number between 1 and ${doc0().caret.totalLines}.` : 'Open a file first.';
      else if (mode === 'files') empty = !Coder.workspace.root && !Coder.docs.length ? 'Open a folder to search its files.' : 'No matching files.';
      else if (mode === 'symbols') empty = doc0() ? 'No matching symbols.' : 'Open a file first.';
      else if (mode === 'modules' || mode === 'instance') empty = 'No modules found in the workspace.';
      list = h('div', { class: 'palette-empty' }, empty);
    }
    const box = h('div', { class: 'palette' }, h('div', { class: 'palette-input-wrap' }, input), list);
    layer.onmousedown = (e) => { if (e.target === layer) cancel(); };
    replaceKeepingFocus(layer, [box]);
    if (document.activeElement !== input) { input.focus(); input.setSelectionRange(input.value.length, input.value.length); }
    const sel = box.querySelector('.palette-row.sel');
    if (sel) sel.scrollIntoView({ block: 'nearest' });
    function doc0() { return Coder.active; }
  },
};

if (typeof module !== 'undefined') module.exports = { CoderUI };
