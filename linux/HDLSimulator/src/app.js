'use strict';
/* global Host, PathUtil, Paths, Prefs, IS_WIN, IS_MAC, IS_LINUX, REVEAL_LABEL, REVEAL_SOURCE_LABEL, INSTALL_HINT, MOD, h, icon, $, Menus, Dialogs, showToast, matchKey, keyLabel, currentTheme, THEMES, Shell, store,
   Coder, CoderUI, Tester, TesterUI, Tools, Linter, HDLLanguage, Viewer, TS */
// HDL Simulator: the window. The Coder and Tester tabs, the app menu, keyboard shortcuts, settings and start-up.
// Port of HDLSimulator/App.swift.

const App = {
  tabSwitcher() {
    const tabs = [['coder', 'code', 'Coder', 'Ctrl+1'], ['tester', 'beaker', 'Tester', 'Ctrl+2']];
    return h('div', { class: 'tab-switcher' }, tabs.map(([id, ic, title, key]) => h('button', { class: 'app-tab' + (Shell.tab === id ? ' on' : ''), title: `HDL ${title} (${keyLabel(key)})`,
      onclick: () => Shell.show(id) }, icon(ic), h('span', null, title))));
  },
  menuButton() {
    return h('button', { class: 'tb-btn codicon codicon-menu', title: 'Menu', onclick: (e) => Menus.popup(this.appMenu(), e.currentTarget) });
  },

  updateWindowTitle() {
    let title = 'HDL Simulator';
    if (Shell.tab === 'coder' && Coder.active) title = `${Coder.active.name}${Coder.active.isDirty ? ' ●' : ''} — HDL Simulator`;
    if (Shell.tab === 'tester' && Tester.active) title = `${Tester.active.name}${Tester.active.isDirty ? ' ●' : ''} — HDL Simulator`;
    if (document.title !== title) { document.title = title; Host.setTitle(title); }
  },

  applyTheme() {
    const t = currentTheme();
    const root = document.documentElement.style;
    for (const [k, v] of Object.entries(t)) if (typeof v === 'string') root.setProperty('--' + k, v);
    root.colorScheme = t.dark ? 'dark' : 'light';
    document.body.classList.toggle('light', !t.dark);
    Host.setTheme({ dark: t.dark, editor: t.editor, titleBar: t.titleBar, titleFG: t.titleFG });
  },

  showTab(t) {
    document.getElementById('coder').style.display = t === 'coder' ? '' : 'none';
    document.getElementById('tester').style.display = t === 'tester' ? '' : 'none';
    if (!this.dev) store.set('app.tab', t);
    Coder.render('all');
    Tester.render('all');
    if (t === 'coder') Coder.focusEditor(); else if (document.activeElement) document.activeElement.blur();
  },

  // ---------------------------------------------------------------- App menu (the ☰ button; the Mac app's menu bar)

  appMenu() {
    const recentCoder = [...Coder.recentFolders.map((p) => ({ label: Paths.tilde(p), action: () => Coder.open([p]) })),
      ...(Coder.recentFolders.length && Coder.recentFiles.length ? [{ type: 'separator' }] : []),
      ...Coder.recentFiles.map((p) => ({ label: PathUtil.basename(p) + '   —   ' + Paths.tilde(PathUtil.dirname(p)), action: () => Coder.open([p]) })),
      { type: 'separator' }, { label: 'Clear Recent', action: () => Coder.clearRecent() }];
    const view = [
      { label: 'HDL Coder', accelerator: 'CmdOrCtrl+1', type: 'radio', checked: Shell.tab === 'coder', action: () => Shell.show('coder') },
      { label: 'HDL Tester', accelerator: 'CmdOrCtrl+2', type: 'radio', checked: Shell.tab === 'tester', action: () => Shell.show('tester') },
      { type: 'separator' },
    ];
    const theme = { label: 'Color Theme', submenu: Object.values(THEMES).map((t) => ({ label: t.name, type: 'radio', checked: Prefs.get('themeID') === t.id, action: () => Prefs.set('themeID', t.id) })) };
    const help = { label: 'Help', submenu: [
      { label: 'Open Example Project', action: () => Coder.openExamples() },
      { label: 'Open Example Test', action: () => Tester.openExample() },
      { type: 'separator' },
      { label: 'Toggle Developer Tools', accelerator: 'CmdOrCtrl+Shift+I', action: () => Host.toggleDevTools() },
      { label: `About HDL Simulator ${Host.launch.version}`, action: () => Dialogs.alert('HDL Simulator', `Version ${Host.launch.version}\nHDL Coder and HDL Tester in one window.`, 'info') }] };
    if (Shell.tab === 'coder') {
      const C = Coder, ed = () => C.editor;
      const act = (id) => () => { if (ed() && C.active) { ed().focus(); ed().trigger('menu', id, null); } };
      const d = C.active;
      return [
        { label: 'File', submenu: [
          { label: 'New File', accelerator: 'CmdOrCtrl+N', action: () => C.newFile() },
          { label: 'New File from Template…', accelerator: 'CmdOrCtrl+Alt+N', action: () => C.openPalette('newFile') },
          { type: 'separator' },
          { label: 'Open…', accelerator: 'CmdOrCtrl+O', action: () => C.showOpenPanel() },
          { label: 'Open Folder…', accelerator: 'CmdOrCtrl+Alt+O', action: () => C.showOpenFolderPanel() },
          { label: 'Open Recent', submenu: recentCoder },
          { label: 'Open Example Project', action: () => C.openExamples() },
          { type: 'separator' },
          { label: 'Save', accelerator: 'CmdOrCtrl+S', enabled: !!d, action: () => C.save(d) },
          { label: 'Save As…', accelerator: 'CmdOrCtrl+Shift+S', enabled: !!d, action: () => C.save(d, true) },
          { label: 'Save All', accelerator: 'CmdOrCtrl+Alt+S', action: () => C.saveAll() },
          { label: 'Revert File', enabled: !!(d && d.path), action: () => C.revert(d) },
          { type: 'separator' },
          { label: 'Close Editor', accelerator: 'CmdOrCtrl+W', enabled: !!d, action: () => C.closeActive() },
          { label: 'Close Folder', enabled: !!C.workspace.root, action: () => C.closeFolder() },
          { type: 'separator' },
          { label: 'Settings…', accelerator: 'CmdOrCtrl+,', action: () => this.openSettings() },
          { label: 'Exit', action: () => this.requestQuit() }] },
        { label: 'Edit', submenu: [
          { label: 'Undo', accelerator: 'CmdOrCtrl+Z', action: act('undo') }, { label: 'Redo', accelerator: 'CmdOrCtrl+Y', action: act('redo') }, { type: 'separator' },
          { label: 'Find…', accelerator: 'CmdOrCtrl+F', action: act('actions.find') },
          { label: 'Replace…', accelerator: 'CmdOrCtrl+H', action: act('editor.action.startFindReplaceAction') },
          { label: 'Find Next', accelerator: 'F3', action: act('editor.action.nextMatchFindAction') },
          { label: 'Find Previous', accelerator: 'Shift+F3', action: act('editor.action.previousMatchFindAction') },
          { type: 'separator' },
          { label: 'Find in Files', accelerator: 'CmdOrCtrl+Shift+F', action: () => { C.sidebarMode = 'search'; C.render('all'); } },
          { label: 'Replace in Files', accelerator: 'CmdOrCtrl+Shift+H', action: () => { C.sidebarMode = 'search'; C.search.showReplace = true; C.render('all'); } },
          { type: 'separator' },
          { label: 'Toggle Line Comment', accelerator: 'CmdOrCtrl+/', action: act('editor.action.commentLine') },
          { label: 'Indent Lines', accelerator: 'CmdOrCtrl+]', action: act('editor.action.indentLines') },
          { label: 'Outdent Lines', accelerator: 'CmdOrCtrl+[', action: act('editor.action.outdentLines') },
          { label: 'Reindent Lines', accelerator: 'CmdOrCtrl+Alt+I', action: () => C.reindentCommand(false) },
          { label: 'Trim Trailing Whitespace', action: () => d && C.trimTrailingWhitespace(d) }] },
        { label: 'Selection', submenu: [
          { label: 'Expand Selection to Line', accelerator: 'CmdOrCtrl+L', action: act('expandLineSelection') },
          { type: 'separator' },
          { label: 'Move Line Up', accelerator: 'Alt+Up', action: act('editor.action.moveLinesUpAction') },
          { label: 'Move Line Down', accelerator: 'Alt+Down', action: act('editor.action.moveLinesDownAction') },
          { label: 'Copy Line Up', accelerator: 'Shift+Alt+Up', action: act('editor.action.copyLinesUpAction') },
          { label: 'Copy Line Down', accelerator: 'Shift+Alt+Down', action: act('editor.action.copyLinesDownAction') },
          { label: 'Delete Line', accelerator: 'CmdOrCtrl+Shift+K', action: act('editor.action.deleteLines') },
          { label: 'Insert Line Below', accelerator: 'CmdOrCtrl+Enter', action: act('editor.action.insertLineAfter') },
          { label: 'Insert Line Above', accelerator: 'CmdOrCtrl+Shift+Enter', action: act('editor.action.insertLineBefore') },
          { type: 'separator' },
          { label: 'Go to Matching Bracket / begin–end', accelerator: 'CmdOrCtrl+Shift+\\', action: () => d && C.jumpToMatchingBracket(d) },
          { label: 'Trigger Suggestions', accelerator: 'CmdOrCtrl+Space', action: act('editor.action.triggerSuggest') }] },
        { label: 'View', submenu: [...view,
          { label: 'Toggle Sidebar', accelerator: 'CmdOrCtrl+B', action: () => C.toggleSidebar() },
          { label: 'Toggle Panel', accelerator: 'CmdOrCtrl+J', action: () => C.togglePanel() },
          { label: 'Explorer', accelerator: 'CmdOrCtrl+Shift+E', action: () => { C.sidebarMode = 'explorer'; C.render('all'); } },
          { label: 'Outline', action: () => { C.sidebarMode = 'outline'; C.render('all'); } },
          { label: 'Design Hierarchy', action: () => { C.sidebarMode = 'hierarchy'; C.render('all'); } },
          { label: 'Snippets', action: () => { C.sidebarMode = 'snippets'; C.render('all'); } },
          { label: 'Problems', accelerator: 'CmdOrCtrl+Shift+M', action: () => C.togglePanel('problems') },
          { label: 'Output', accelerator: 'CmdOrCtrl+Shift+U', action: () => C.togglePanel('output') },
          { type: 'separator' },
          { label: 'Word Wrap', accelerator: 'Alt+Z', type: 'checkbox', checked: Prefs.get('editor.wordWrap'), action: () => Prefs.set('editor.wordWrap', !Prefs.get('editor.wordWrap')) },
          { label: 'Zoom In', accelerator: 'CmdOrCtrl+=', action: () => C.zoom(1) },
          { label: 'Zoom Out', accelerator: 'CmdOrCtrl+-', action: () => C.zoom(-1) },
          { label: 'Reset Zoom', accelerator: 'CmdOrCtrl+0', action: () => C.zoom(0) },
          theme] },
        { label: 'Go', submenu: [
          { label: 'Back', accelerator: 'Alt+Left', action: () => C.goBack() },
          { label: 'Forward', accelerator: 'Alt+Right', action: () => C.goForward() },
          { type: 'separator' },
          { label: 'Go to File…', accelerator: 'CmdOrCtrl+P', action: () => C.openPalette('files', '') },
          { label: 'Command Palette…', accelerator: 'CmdOrCtrl+Shift+P', action: () => C.openPalette('commands') },
          { label: 'Go to Symbol in File…', accelerator: 'CmdOrCtrl+Shift+O', action: () => C.openPalette('symbols') },
          { label: 'Go to Module in Workspace…', accelerator: 'CmdOrCtrl+T', action: () => C.openPalette('modules') },
          { label: 'Go to Line…', accelerator: 'CmdOrCtrl+G', action: () => C.openPalette('line') },
          { type: 'separator' },
          { label: 'Go to Definition', accelerator: 'F12', action: () => C.goToDefinitionAtCaret() },
          { label: 'Find All References', accelerator: 'Shift+F12', action: () => { const w = C.selectedOrCaretWord(); if (w) C.findReferences(w); } },
          { type: 'separator' },
          { label: 'Descend into Module', accelerator: 'CmdOrCtrl+Alt+Down', action: () => C.descend() },
          { label: 'Ascend to Testbench / Parent', accelerator: 'CmdOrCtrl+Alt+Up', action: () => C.ascend() }] },
        { label: 'HDL', submenu: [
          { label: 'Run Simulation', accelerator: 'CmdOrCtrl+R', action: () => C.runActive() },
          { label: 'Stop Simulation', accelerator: 'CmdOrCtrl+.', enabled: C.isRunning, action: () => C.stopRun() },
          { label: 'Check File for Errors', accelerator: 'CmdOrCtrl+Shift+B', action: () => C.lintActive() },
          { type: 'separator' },
          { label: 'Insert Snippet…', accelerator: 'CmdOrCtrl+Shift+J', action: () => C.openPalette('snippet') },
          { label: 'Insert Module Instance…', accelerator: 'CmdOrCtrl+Shift+I', action: () => C.openPalette('instance') },
          { label: 'Copy Instantiation Template', accelerator: 'CmdOrCtrl+Shift+Alt+I', action: () => C.copyInstantiation() },
          { label: 'Generate Testbench File (Template)', accelerator: 'CmdOrCtrl+Shift+G', action: () => C.generateTestbench() },
          { type: 'separator' },
          { label: 'Open Waveform in HDL Viewer', accelerator: 'CmdOrCtrl+Shift+Y', action: () => C.openLastWaveform() },
          { label: 'Generate Testbench in HDL Tester', accelerator: 'CmdOrCtrl+Alt+T', action: () => C.generateTestbenchInTester() },
          { label: 'Open Simulation Output Folder', action: () => { const p = d && d.path ? PathUtil.join(PathUtil.dirname(d.path), 'sim_out') : null; if (p && Host.fs.exists(p)) Host.openPath(p); } },
          ...(IS_LINUX ? [{ type: 'separator' },
            { label: 'Synthesize and Place & Route in HDLPhy (SKY130)', enabled: !!(C.workspace.root || (d && d.path)) && !!Host.hdlphyPath(),
              action: () => Host.openInHDLPhy([C.workspace.root || d.path]).then((ok) => { if (!ok) showToast('HDLPhy is not installed (HDLTool/linux/build_apps.sh --install hdlphy)'); }) }] : []),
          { type: 'separator' },
          { label: 'Language Mode', submenu: HDLLanguage.all.map((l) => ({ label: HDLLanguage.displayName(l), type: 'radio', checked: !!d && d.language === l, action: () => { if (d) { d.setLanguage(l); C.scheduleLint(d, 0); C.render('all'); } } })) }] },
        help,
      ];
    }
    const T = Tester, doc = T.active;
    return [
      { label: 'File', submenu: [
        { label: 'New Test', accelerator: 'CmdOrCtrl+N', action: () => T.newTest() },
        { label: 'Open…', accelerator: 'CmdOrCtrl+O', action: () => T.showOpenPanel() },
        { label: 'Open Folder of Verilog Files…', action: () => T.showOpenFolderPanel() },
        { label: 'Open Recent Test', submenu: [...T.recentTests.map((p) => ({ label: PathUtil.basename(p), action: () => T.open([p]) })), { type: 'separator' }, { label: 'Clear Recent', action: () => T.clearRecent() }] },
        { label: 'Open Example Test', action: () => T.openExample() },
        { label: 'Open Wired Example', action: () => T.openExample('wired.hdltest') },
        { type: 'separator' },
        { label: 'Save Test', accelerator: 'CmdOrCtrl+S', enabled: !!doc, action: () => T.save(doc, false) },
        { label: 'Save Test As…', accelerator: 'CmdOrCtrl+Shift+S', enabled: !!doc, action: () => T.save(doc, true) },
        { label: 'Export Testbench', accelerator: 'CmdOrCtrl+E', enabled: !!doc, action: () => { const p = T.export(doc); if (p) Host.showInFolder(p); } },
        { type: 'separator' },
        { label: 'Close Test', accelerator: 'CmdOrCtrl+Shift+W', enabled: !!doc, action: () => T.closeActive() },
        { type: 'separator' },
        { label: 'Settings…', accelerator: 'CmdOrCtrl+,', action: () => this.openSettings() },
        { label: 'Exit', action: () => this.requestQuit() }] },
      { label: 'Edit', submenu: [
        { label: 'Undo', accelerator: 'CmdOrCtrl+Z', enabled: !!doc && doc.canUndo, action: () => T.undo() },
        { label: 'Redo', accelerator: 'CmdOrCtrl+Shift+Z', enabled: !!doc && doc.canRedo, action: () => T.redo() },
        { type: 'separator' },
        { label: 'Copy Stimulus', accelerator: 'CmdOrCtrl+Alt+C', action: () => T.copyStimulus() },
        { label: 'Paste Stimulus', accelerator: 'CmdOrCtrl+Alt+V', action: () => T.pasteStimulus() },
        { label: 'Duplicate DUT', accelerator: 'CmdOrCtrl+D', action: () => T.duplicate() },
        { label: 'Delete Selection', accelerator: 'Delete', action: () => T.deleteSelection() }] },
      { label: 'View', submenu: [...view,
        { label: 'Toggle Sidebar', accelerator: 'CmdOrCtrl+B', action: () => T.toggleSidebar() },
        { label: 'Toggle Panel', accelerator: 'CmdOrCtrl+J', action: () => { T.showPanel = !T.showPanel; T.render('all'); } },
        { label: 'Toggle Inspector', accelerator: 'CmdOrCtrl+Alt+B', action: () => { T.showInspector = !T.showInspector; T.render('all'); } },
        theme] },
      { label: 'Test', submenu: [
        { label: 'Run Test', accelerator: 'CmdOrCtrl+R', action: () => T.runActive() },
        { label: 'Run All Tests', accelerator: 'CmdOrCtrl+Shift+R', action: () => T.runAll() },
        { label: 'Stop', accelerator: 'CmdOrCtrl+.', action: () => doc && T.stop(doc) },
        { type: 'separator' },
        { label: 'Open Waveform in HDL Viewer', accelerator: 'CmdOrCtrl+Shift+Y', enabled: !!(doc && doc.lastVCD), action: () => Viewer.open(doc.lastVCD) },
        { label: 'Descend into DUT', accelerator: 'CmdOrCtrl+Alt+Down', action: () => T.descendSelected() },
        { type: 'separator' },
        { label: 'Open Output Folder', enabled: !!doc, action: () => { const p = T.outputDir(doc); if (Host.fs.exists(p)) Host.openPath(p); } },
        { type: 'separator' },
        { label: 'Zoom In', accelerator: 'CmdOrCtrl+=', action: () => T.zoom(1.25) },
        { label: 'Zoom Out', accelerator: 'CmdOrCtrl+-', action: () => T.zoom(1 / 1.25) },
        { label: 'Actual Size', accelerator: 'CmdOrCtrl+0', action: () => T.zoom(0) }] },
      help,
    ];
  },

  // ---------------------------------------------------------------- Keyboard shortcuts

  bindings() {
    const C = Coder, T = Tester;
    const coder = Shell.tab === 'coder';
    const common = [
      ['Ctrl+1', () => Shell.show('coder')], ['Ctrl+2', () => Shell.show('tester')], ['Ctrl+,', () => this.openSettings()],
      ['Ctrl+Shift+I', () => (coder ? C.openPalette('instance') : Host.toggleDevTools())], ['F11', () => Host.toggleMaximize()],
    ];
    if (coder) {
      const d = C.active;
      return common.concat([
        ['Ctrl+N', () => C.newFile()], ['Ctrl+Alt+N', () => C.openPalette('newFile')], ['Ctrl+O', () => C.showOpenPanel()], ['Ctrl+Alt+O', () => C.showOpenFolderPanel()],
        ['Ctrl+S', () => d && C.save(d)], ['Ctrl+Shift+S', () => d && C.save(d, true)], ['Ctrl+Alt+S', () => C.saveAll()], ['Ctrl+W', () => C.closeActive()], ['Ctrl+F4', () => C.closeActive()],
        ['Ctrl+Shift+F', () => { C.sidebarMode = 'search'; C.render('all'); setTimeout(() => { const i = document.querySelector('#coder [data-key="search-q"]'); if (i) { i.focus(); i.select(); } }, 30); }],
        ['Ctrl+Shift+H', () => { C.sidebarMode = 'search'; C.search.showReplace = true; C.render('all'); }],
        ['Ctrl+Alt+I', () => C.reindentCommand(false)], ['Ctrl+Shift+\\', () => d && C.jumpToMatchingBracket(d)],
        ['Alt+Left', () => C.goBack()], ['Alt+Right', () => C.goForward()],
        ['Ctrl+P', () => C.openPalette('files', '')], ['Ctrl+Shift+P', () => C.openPalette('commands')], ['F1', () => C.openPalette('commands')],
        ['Ctrl+Shift+O', () => C.openPalette('symbols')], ['Ctrl+T', () => C.openPalette('modules')], ['Ctrl+G', () => C.openPalette('line')],
        ['F12', () => C.goToDefinitionAtCaret()], ['Shift+F12', () => { const w = C.selectedOrCaretWord(); if (w) C.findReferences(w); }],
        ['Ctrl+Alt+Down', () => C.descend()], ['Ctrl+Alt+Up', () => C.ascend()],
        ['Ctrl+R', () => C.runActive()], ['F5', () => C.runActive()], ['Ctrl+.', () => C.stopRun()], ['Shift+F5', () => C.stopRun()], ['Ctrl+Shift+B', () => C.lintActive()],
        ['Ctrl+Shift+J', () => C.openPalette('snippet')], ['Ctrl+Shift+Alt+I', () => C.copyInstantiation()], ['Ctrl+Shift+G', () => C.generateTestbench()],
        ['Ctrl+Shift+Y', () => C.openLastWaveform()], ['Ctrl+Alt+T', () => C.generateTestbenchInTester()],
        ['Ctrl+B', () => C.toggleSidebar()], ['Ctrl+J', () => C.togglePanel()], ['Ctrl+Shift+E', () => { C.sidebarMode = 'explorer'; C.render('all'); }],
        ['Ctrl+Shift+M', () => C.togglePanel('problems')], ['Ctrl+Shift+U', () => C.togglePanel('output')],
        ['Alt+Z', () => Prefs.set('editor.wordWrap', !Prefs.get('editor.wordWrap'))],
        ['Ctrl+=', () => C.zoom(1)], ['Ctrl+Shift+=', () => C.zoom(1)], ['Ctrl+-', () => C.zoom(-1)], ['Ctrl+0', () => C.zoom(0)],
        ['Ctrl+Tab', () => this.cycleTabs(1)], ['Ctrl+Shift+Tab', () => this.cycleTabs(-1)],
      ]);
    }
    const doc = T.active;
    const noInput = (fn) => Object.assign(fn, { noInput: true });
    return common.concat([
      ['Ctrl+N', () => T.newTest()], ['Ctrl+O', () => T.showOpenPanel()], ['Ctrl+Shift+W', () => T.closeActive()],
      ['Ctrl+S', () => doc && T.save(doc, false)], ['Ctrl+Shift+S', () => doc && T.save(doc, true)], ['Ctrl+E', () => { if (doc) { const p = T.export(doc); if (p) Host.showInFolder(p); } }],
      ['Ctrl+Z', noInput(() => T.undo())], ['Ctrl+Shift+Z', noInput(() => T.redo())], ['Ctrl+Y', noInput(() => T.redo())],
      ['Ctrl+Alt+C', () => T.copyStimulus()], ['Ctrl+Alt+V', () => T.pasteStimulus()], ['Ctrl+D', noInput(() => T.duplicate())],
      ['Delete', noInput(() => T.deleteSelection())], ['Backspace', noInput(() => T.deleteSelection())], ['Escape', noInput(() => { if (doc && doc.selection) { doc.selection = null; T.render('all'); } })],
      ['Ctrl+R', () => T.runActive()], ['F5', () => T.runActive()], ['Ctrl+Shift+R', () => T.runAll()], ['Ctrl+.', () => doc && T.stop(doc)], ['Shift+F5', () => doc && T.stop(doc)],
      ['Ctrl+Shift+Y', () => { if (doc && doc.lastVCD) Viewer.open(doc.lastVCD); }], ['Ctrl+Alt+Down', () => T.descendSelected()],
      ['Ctrl+=', () => T.zoom(1.25)], ['Ctrl+Shift+=', () => T.zoom(1.25)], ['Ctrl+-', () => T.zoom(1 / 1.25)], ['Ctrl+0', () => T.zoom(0)],
      ['Ctrl+B', () => T.toggleSidebar()], ['Ctrl+J', () => { T.showPanel = !T.showPanel; T.render('all'); }], ['Ctrl+Alt+B', () => { T.showInspector = !T.showInspector; T.render('all'); }],
      ['Ctrl+Tab', () => this.cycleTabs(1)], ['Ctrl+Shift+Tab', () => this.cycleTabs(-1)],
    ]);
  },
  cycleTabs(dir) {
    if (Shell.tab === 'coder') {
      const docs = Coder.docs; if (docs.length < 2) return;
      const i = docs.findIndex((d) => d.id === Coder.activeID);
      Coder.activate(docs[(i + dir + docs.length) % docs.length]);
    } else {
      const docs = Tester.tests; if (docs.length < 2) return;
      const i = docs.findIndex((d) => d.id === Tester.activeID);
      Tester.activeID = docs[(i + dir + docs.length) % docs.length].id;
      Tester.render('all');
    }
  },
  onKeyDown(e) {
    if (document.querySelector('.modal-overlay')) return;
    if (this.chord) {
      const chord = this.chord;
      this.chord = null;
      if (chord === 'k' && matchKey(e, 'Ctrl+T')) { e.preventDefault(); e.stopPropagation(); if (Shell.tab === 'coder') Coder.openPalette('theme'); return; }
    }
    if (matchKey(e, 'Ctrl+K') && Shell.tab === 'coder') { this.chord = 'k'; setTimeout(() => { this.chord = null; }, 1500); return; }
    const tgt = e.target;
    const inMonaco = tgt && tgt.closest && tgt.closest('.monaco-editor');
    const inMonacoInput = inMonaco && !tgt.classList.contains('inputarea') && (tgt.tagName === 'TEXTAREA' || tgt.tagName === 'INPUT');
    const inInput = !inMonaco && tgt && (tgt.tagName === 'INPUT' || tgt.tagName === 'TEXTAREA' || tgt.tagName === 'SELECT' || tgt.isContentEditable);
    if (inMonacoInput) return;
    const hasMod = e.ctrlKey || e.metaKey || e.altKey || /^F\d+$/.test(e.key) || ['Delete', 'Backspace', 'Escape'].includes(e.key);
    if (!hasMod) return;
    for (const [spec, fn] of this.bindings()) {
      if (!matchKey(e, spec)) continue;
      if (fn.noInput && (inInput || inMonaco)) return;
      if (inInput && ['Ctrl+Z', 'Ctrl+Y', 'Ctrl+Shift+Z'].includes(spec)) return;
      e.preventDefault();
      e.stopPropagation();
      fn();
      return;
    }
  },

  // ---------------------------------------------------------------- Settings

  openSettings(tab = 0) {
    const field = (label, control, hint) => h('div', { class: 'set-row' }, h('div', { class: 'set-label' }, label), h('div', { class: 'set-control' }, control, hint ? h('div', { class: 'set-hint' }, hint) : null));
    const check = (key, label) => h('label', { class: 'vs-check' }, h('input', { type: 'checkbox', checked: Prefs.get(key), onchange: (e) => Prefs.set(key, e.target.checked) }), h('span', null, label));
    const select = (key, options) => h('select', { class: 'vs-select', onchange: (e) => Prefs.set(key, isNaN(+e.target.value) || e.target.value === '' ? e.target.value : +e.target.value) },
      options.map(([v, l]) => h('option', { value: v, selected: String(Prefs.get(key)) === String(v) ? 'selected' : null }, l)));
    const text = (key, placeholder) => h('input', { class: 'vs-input', placeholder, value: Prefs.get(key), spellcheck: 'false',
      onchange: (e) => { Prefs.set(key, e.target.value.trim()); Tools.detect(); }, onkeydown: (e) => e.stopPropagation() });
    const toolLine = (name, path, extra, missing) => h('div', { class: 'set-tool' }, h('b', null, name + ': '), h('span', { class: 'selectable' }, path ? path + (extra ? `  (version ${extra})` : '') : missing));
    const pages = [
      ['Editor', () => [
        h('div', { class: 'set-section' }, 'Startup'),
        field('', check('restoreSession', 'Reopen the files, folder and tests from the last session'),
          'Off: HDL Simulator starts on the welcome page and asks to save unsaved changes when you close it. Takes effect at the next launch.'),
        h('div', { class: 'set-section' }, 'Appearance'),
        field('Color theme', select('themeID', Object.values(THEMES).map((t) => [t.id, t.name]))),
        field('Font', select('editor.fontName', [['', 'Default (Cascadia Mono / Consolas)'], ['Consolas', 'Consolas'], ['Cascadia Code', 'Cascadia Code'], ['Cascadia Mono', 'Cascadia Mono'], ['Courier New', 'Courier New'], ['Lucida Console', 'Lucida Console'], ['JetBrains Mono', 'JetBrains Mono'], ['Fira Code', 'Fira Code'], ['Source Code Pro', 'Source Code Pro']])),
        field('Font size', select('editor.fontSize', Array.from({ length: 29 }, (_, i) => [i + 8, `${i + 8} pt`]))),
        h('div', { class: 'set-section' }, 'Indentation'),
        field('Tab size', select('editor.tabSize', [[2, '2'], [3, '3'], [4, '4'], [8, '8']])),
        field('', check('editor.insertSpaces', 'Insert spaces when pressing Tab'), 'Files that already use tabs or another indent size keep their own (shown in the status bar).'),
        h('div', { class: 'set-section' }, 'Editing'),
        field('', h('div', { class: 'vstack' }, check('editor.autoClose', 'Close brackets and quotes automatically'), check('editor.autoEnd', 'Insert end, endcase, endmodule… after Enter'),
          check('editor.suggest', 'Show suggestions while typing'), check('editor.wordWrap', 'Wrap long lines'), check('trimTrailingWhitespace', 'Trim trailing whitespace when saving'),
          check('insertFinalNewline', 'End files with a newline when saving'))),
        h('div', { class: 'set-section' }, 'Display'),
        field('', h('div', { class: 'vstack' }, check('editor.highlightLine', 'Highlight the current line'), check('editor.indentGuides', 'Show indent guides'),
          check('editor.inlineDiagnostics', 'Show problem messages at the end of the line'), check('editor.showInvisibles', 'Show invisible characters'), check('editor.minimap', 'Show the minimap'))),
      ]],
      ['Tools', () => [
        h('div', { class: 'set-section' }, 'Checking'),
        field('Check code with', select('linter', Linter.kinds)),
        field('', check('lintWhileTyping', 'Check while typing (otherwise on open and save)')),
        field('Language standard (Icarus)', select('languageStandard', [['-g1995', 'Verilog-1995'], ['-g2001', 'Verilog-2001'], ['-g2005', 'Verilog-2005'], ['-g2009', 'SystemVerilog 2009'], ['-g2012', 'SystemVerilog 2012']]),
          'Automatic uses Icarus Verilog if installed, otherwise Verilator. VHDL files are checked with GHDL when it is installed.'),
        h('div', { class: 'set-section' }, 'Simulation'),
        field('', h('div', { class: 'vstack' }, check('saveBeforeRun', 'Save files before running'), check('openWaveformsInViewer', 'Open waveforms in HDL Viewer after a run'))),
        h('div', { class: 'set-section' }, 'Tool locations'),
        field('Icarus Verilog', text('iverilogPath', IS_WIN ? 'Automatic (C:\\iverilog\\bin, OSS CAD Suite, MSYS2, PATH)' : IS_MAC ? 'Automatic (Homebrew, /usr/local/bin, PATH)' : 'Automatic (/usr/bin, /usr/local/bin, ~/.local/bin, OSS CAD Suite, PATH)'), 'A folder or the iverilog executable.'),
        field('Verilator', text('verilatorPath', 'Automatic')),
        field('GHDL', text('ghdlPath', 'Automatic')),
        h('div', { class: 'set-tools' },
          toolLine('Icarus Verilog', Tools.iverilog, Tools.iverilogVersion, IS_WIN ? 'Not found — install Icarus Verilog for Windows (bleyer.org/icarus)' : 'Not found — ' + INSTALL_HINT.iverilog),
          toolLine('Verilator', Tools.verilator, null, 'Not found (optional)'), toolLine('GHDL', Tools.ghdl, null, 'Not found (optional, for VHDL)'),
          toolLine('HDL Viewer', Viewer.path(), null, 'Not installed — waveforms open in the app registered for .vcd files')),
        h('button', { class: 'vs-button secondary', onclick: () => { Tools.detect(); close(); this.openSettings(1); } }, 'Detect Again'),
      ]],
      ['Tester', () => [
        field('', check('openResultsInViewer', 'Open waveforms in HDL Viewer after a run')),
        field('', h('div', { class: 'set-hint' }, 'The color theme and the Icarus Verilog location are shared with the Coder (Editor and Tools tabs).')),
      ]],
    ];
    let close = () => {};
    Dialogs.modal('Settings', (c) => {
      close = c;
      const body = h('div', { class: 'set-body' });
      const tabs = h('div', { class: 'set-tabs' });
      const show = (i) => {
        tabs.replaceChildren(...pages.map(([name], j) => h('button', { class: j === i ? 'on' : '', onclick: () => show(j) }, name)));
        body.replaceChildren(...pages[i][1]());
      };
      show(tab);
      return h('div', { class: 'settings' }, tabs, body, h('div', { class: 'modal-buttons' }, h('span', { class: 'grow' }), h('button', { class: 'vs-button', onclick: () => c(null) }, 'Done')));
    }, 620);
  },

  // ---------------------------------------------------------------- Quit

  // Asks to save unsaved files and tests, then quits.
  requestQuit() {
    if (Coder.sessionEnabled) { this.quitKeepingSession(); return; }
    if (!Coder.closeAll()) return;
    for (const t of [...Tester.tests]) {
      if (t.isDirty && t.state.instances.length) { if (!Tester.close(t)) return; }
    }
    Host.quitConfirmed();
  },
  // With "Reopen the last session" on: unsaved edits stay in the session (like the Mac app), no prompts.
  quitKeepingSession() {
    Coder.saveSession();
    Tester.saveSession();
    Host.quitConfirmed();
  },

  // Tests go to the Tester; source files and folders to the Coder.
  route(paths) {
    const tests = paths.filter((p) => Paths.ext(p) === 'hdltest');
    const rest = paths.filter((p) => Paths.ext(p) !== 'hdltest');
    if (rest.length) { Coder.open(rest); Shell.show('coder'); }
    if (tests.length) { Tester.open(tests); Shell.show('tester'); }
  },

  // ---------------------------------------------------------------- Start-up

  start() {
    const L = Host.launch;
    this.dev = L.dev;
    // Linux uses the Windows layout (frameless window, window controls drawn by Electron at the top right).
    document.body.classList.add(Host.platform === 'darwin' ? 'mac' : 'win');
    if (IS_LINUX) document.body.classList.add('linux');
    if (L.theme && THEMES[L.theme]) Prefs.set('themeID', L.theme);
    this.applyTheme();
    Prefs.onChange((k) => { if (k === 'themeID') this.applyTheme(); });
    Shell.tabChanged = (t) => this.showTab(t);
    // By default every launch starts on the landing page; Settings can turn on reopening the last session.
    const restore = !L.dev && Prefs.get('restoreSession');
    Coder.sessionEnabled = restore;
    Tester.sessionEnabled = restore;
    if (L.dev) { Coder.openWaveforms = false; Tester.openWaveforms = false; }
    CoderUI.build(document.getElementById('coder'));
    TesterUI.build(document.getElementById('tester'));
    Tools.detect();
    Coder.start();
    Tester.start();
    const saved = store.get('app.tab', 'coder');
    if (restore && (saved === 'coder' || saved === 'tester')) Shell.tab = saved;
    this.showTab(Shell.tab);
    window.addEventListener('keydown', (e) => this.onKeyDown(e), true);
    Host.onOpenFiles((files) => this.route(files));
    Host.onCloseRequested(() => this.requestQuit());
    if (L.files.length) this.route(L.files);
    if (L.tab) Shell.show(L.tab);
    if (L.panel) { if (Shell.tab === 'tester') Tester.panelTab = L.panel; else { Coder.panelTab = L.panel; Coder.showPanel = true; } }
    if (L.select) setTimeout(() => this.select(L.select), 300);
    if (L.actions) this.runActions(L.actions.split('|'));
    window.addEventListener('beforeunload', () => { if (Coder.sessionEnabled) { Coder.saveSession(); Tester.saveSession(); } });
  },
  select(spec) {
    const doc = Tester.active;
    if (!doc) return;
    const [name, pin] = spec.split('.');
    const inst = doc.state.instances.find((i) => i.name === name);
    if (inst) { doc.selection = pin ? { type: 'pin', id: inst.id, pin } : { type: 'instance', id: inst.id }; Tester.render('all'); }
  },
  // Developer helper (--actions "a|b|c"): tab:coder, tab:tester, select:<inst>, line:<n>, open:<path>, palette:<mode>, or a command id.
  async runActions(list) {
    await new Promise((r) => setTimeout(r, 1200));
    for (const a of list) {
      const [k, v] = a.split(/:(.*)/s);
      if (k === 'tab') Shell.show(v);
      else if (k === 'select') this.select(v);
      else if (k === 'line' && Coder.active) Coder.reveal(Coder.active, +v);
      else if (k === 'open') this.route([v]);
      else if (k === 'palette') Coder.openPalette(v.split(',')[0], v.split(',')[1] || undefined);
      else if (k === 'settings') this.openSettings(+v || 0);
      else if (k === 'type' && Coder.editor) { Coder.editor.focus(); Coder.editor.trigger('test', 'type', { text: v }); }
      else if (k === 'enter' && Coder.editor) { const d = Coder.active; if (!d || !Typing.newline(d, Coder.editor)) Coder.editor.trigger('test', 'type', { text: '\n' }); }
      else if (k === 'run') { if (Shell.tab === 'coder') await Coder.simulate(Coder.active); else await Tester.run(Tester.active); }
      else if (k === 'descend') { if (Shell.tab === 'coder') Coder.descend(); else Tester.descendSelected(); }
      else if (k === 'ascend') Coder.ascend();
      else if (k === 'testbench') Coder.generateTestbenchInTester();
      else if (k === 'log') console.log('[test] ' + this.debugState());
      else { const c = Coder.commands().find((x) => x.id === a); if (c) c.action(); }
      await new Promise((r) => setTimeout(r, 500));
    }
  },
  debugState() {
    const d = Coder.active, t = Tester.active;
    return `tab=${Shell.tab} | coder: ${d ? `${d.name} line ${d.caret.line}${d.isDirty ? ' (modified)' : ''}` : 'no file'} | tester: ${t ? `${t.name} duts=${TS.duts(t.state).map((x) => x.name).join(',')} sources=${TS.sources(t.state).length}` : 'no test'} | stack=${Shell.stack.map((f) => f.label).join(',')}`;
  },
};

window.addEventListener('DOMContentLoaded', () => App.start());
