'use strict';
/* global Coder, Shell, Host, PathUtil, Paths, HDLLanguage, SymbolScanner, symbolPathAt, symPorts, showToast, Prefs, Tools, MOD, THEMES */
// Descend / ascend through the design hierarchy and the hand-off to the Tester tab (Hierarchy.swift),
// plus the command list for the command palette.

Object.assign(Coder, {
  registerWithShell() {
    Shell.openInCoder = (path, line, module) => this.openForHierarchy(path, line, module);
    Shell.revealInCoder = (path, offset) => {
      const d = this.openFile(path);
      if (!d) return;
      this.select(d, Math.min(Math.max(offset, 0), d.text.length), 0);
      this.focusEditor();
    };
  },
  openForHierarchy(path, line, module) {
    const d = this.openFile(path);
    if (!d) return;
    const s = module && d.symbols.find((x) => (x.kind === 'module' || x.kind === 'entity') && x.name === module);
    if (s) this.goToSymbol(s, d.path);
    else if (line != null) this.reveal(d, line);
    this.focusEditor();
  },
  focusEditor() { setTimeout(() => { if (this.editor && this.active && Shell.tab === 'coder') this.editor.focus(); }, 0); },
  moduleAtCaret(d) {
    const line = d.hasModel ? d.lineIndex(this.caretOffset(d)) : 0;
    const isUnit = (s) => s.kind === 'module' || s.kind === 'entity';
    return symbolPathAt(d.symbols, line).find(isUnit) || d.symbols.find(isUnit) || null;
  },
  descendTarget() {
    const d = this.active;
    if (!d || !d.hasModel) return null;
    const off = this.caretOffset(d);
    const path = symbolPathAt(d.symbols, d.lineIndex(off));
    const inst = [...path].reverse().find((s) => s.kind === 'instance');
    if (inst && inst.target) { const def = this.definitionNear(inst.target, d); if (def) return { def, instance: inst.name }; }
    const w = d.wordAt(off);
    if (w) {
      const def = this.definitionNear(w[0], d);
      if (def && (!d.path || !Paths.same(def.path, d.path) || def.symbol.line !== (path[0] || {}).line)) return { def, instance: null };
    }
    return null;
  },
  // A module's definition: from the open folder, an open file, or a file next to `doc`.
  definitionNear(name, doc) {
    const isUnit = (s) => (s.kind === 'module' || s.kind === 'entity') && s.name.toLowerCase() === name.toLowerCase();
    const def = this.workspace.definitions(name).find((d) => isUnit(d.symbol));
    if (def) return def;
    for (const o of this.docs) { if (!o.path) continue; const s = o.symbols.find(isUnit); if (s) return { path: o.path, symbol: s }; }
    if (!doc.path) return null;
    const dir = PathUtil.dirname(doc.path);
    const files = Host.fs.list(dir).filter((e) => !e.isDir && ['v', 'sv', 'vh', 'svh', 'vhd', 'vhdl'].includes(Paths.ext(e.name))).map((e) => e.name).sort();
    for (const f of files) {
      const p = PathUtil.join(dir, f);
      const s = this.siblingSymbols(p).find(isUnit);
      if (s) return { path: p, symbol: s };
    }
    return null;
  },
  siblingCache: new Map(),
  siblingSymbols(p) {
    const st = Host.fs.stat(p);
    const c = this.siblingCache.get(p);
    if (c && st && c[0] === st.mtime) return c[1];
    const text = Host.fs.readText(p);
    if (text == null) return [];
    const syms = SymbolScanner.scan(text, HDLLanguage.detect(p));
    this.siblingCache.set(p, [st ? st.mtime : 0, syms]);
    return syms;
  },
  descend() {
    const d = this.active;
    if (!d) return;
    const t = this.descendTarget();
    if (!t) { showToast('Put the caret on a module instance to descend into it'); return; }
    if (!d.path) { showToast('Save the file first'); return; }
    const m = this.moduleAtCaret(d);
    const label = m ? m.name : d.name;
    const frame = { place: { kind: 'file', path: d.path, offset: this.caretOffset(d) }, label: t.instance ? `${label} (${t.instance})` : label, child: t.def.path };
    Shell.descend(frame, t.def.path, t.def.symbol.line + 1, t.def.symbol.name);
  },
  ascendTarget() {
    const d = this.active;
    if (!d || !d.path) return null;
    const m = this.moduleAtCaret(d);
    return Shell.parent(d.path, m ? m.name : null) || this.instantiatingFile(m ? m.name : null, d.path);
  },
  instantiatingFile(module, child) {
    if (!module) return null;
    for (const path of [...this.workspace.index.keys()].sort()) {
      if (Paths.same(path, child)) continue;
      for (const s of this.workspace.index.get(path).symbols) {
        if (s.kind !== 'module' && s.kind !== 'architecture') continue;
        const inst = s.children.find((c) => c.kind === 'instance' && (c.target || '').toLowerCase() === module.toLowerCase());
        if (inst) return { place: { kind: 'file', path, offset: inst.offset }, label: s.name, child };
      }
    }
    return null;
  },
  ascend() {
    const d = this.active;
    if (!d) return;
    const f = this.ascendTarget();
    const m = this.moduleAtCaret(d);
    if (!f) { showToast(`Nothing above “${m ? m.name : d.name}” — no test or file uses it`); return; }
    if (d.isDirty && d.path) this.save(d);
    if (Shell.ascend(d.path || '', m ? m.name : null)) return;
    if (!Shell.go(f)) showToast(`“${f.label}” is no longer open`);
  },
  generateTestbenchInTester() {
    const doc = this.active;
    if (!doc) return;
    if (!doc.path) { showToast('Save the file first'); return; }
    if (!HDLLanguage.isVerilogFamily(doc.language)) { showToast('HDL Tester works with Verilog and SystemVerilog files'); return; }
    const r = this.moduleForTemplates();
    if (!r) { showToast('No module found in this file'); return; }
    const m = r[0];
    if (!symPorts(m).length) { showToast(`“${m.name}” has no ports — it already looks like a testbench. Run it with ${MOD}+R`); return; }
    const path = doc.symbols.some((s) => s.name === m.name && s.kind === m.kind) ? doc.path : ((this.workspace.definitions(m.name)[0] || {}).path || doc.path);
    for (const d of this.docs) if (d.isDirty && d.path && Paths.same(d.path, path)) this.save(d);
    if (Shell.generateTestbench) Shell.generateTestbench(path, m.name);
  },
  generateTestbenchInTesterFile(p) {
    const d = this.docs.find((x) => x.path && Paths.same(x.path, p));
    if (d && d.isDirty) this.save(d);
    const text = Host.fs.readText(p);
    if (text == null) return;
    const m = SymbolScanner.scan(text, HDLLanguage.detect(p)).find((s) => s.kind === 'module' && symPorts(s).length);
    if (!m) { showToast(`No module with ports in ${PathUtil.basename(p)}`); return; }
    if (Shell.generateTestbench) Shell.generateTestbench(PathUtil.resolve(p), m.name);
  },

  // ---------------------------------------------------------------- Commands (palette)

  commands() {
    const ed = this.editor;
    const act = (id) => () => { if (ed && this.active) { ed.focus(); ed.trigger('palette', id, null); } };
    const c = [];
    const add = (id, title, shortcut, action) => c.push({ id, title, shortcut: shortcut || '', action });
    add('file.new', 'File: New Untitled File', 'Ctrl+N', () => this.newFile());
    add('file.newTemplate', 'File: New File from Template…', 'Ctrl+Alt+N', () => this.openPalette('newFile'));
    add('file.open', 'File: Open…', 'Ctrl+O', () => this.showOpenPanel());
    add('file.openFolder', 'File: Open Folder…', 'Ctrl+Alt+O', () => this.showOpenFolderPanel());
    add('file.save', 'File: Save', 'Ctrl+S', () => { if (this.active) this.save(this.active); });
    add('file.saveAs', 'File: Save As…', 'Ctrl+Shift+S', () => { if (this.active) this.save(this.active, true); });
    add('file.saveAll', 'File: Save All', 'Ctrl+Alt+S', () => this.saveAll());
    add('file.revert', 'File: Revert File', '', () => { if (this.active) this.revert(this.active); });
    add('file.close', 'View: Close Editor', 'Ctrl+W', () => this.closeActive());
    add('file.closeAll', 'View: Close All Editors', '', () => this.closeAll());
    add('file.closeFolder', 'File: Close Folder', '', () => this.closeFolder());
    add('file.examples', 'Help: Open Example Project', '', () => this.openExamples());
    add('go.file', 'Go to File…', 'Ctrl+P', () => this.openPalette('files', ''));
    add('go.symbol', 'Go to Symbol in File…', 'Ctrl+Shift+O', () => this.openPalette('symbols'));
    add('go.module', 'Go to Module in Workspace…', 'Ctrl+T', () => this.openPalette('modules'));
    add('go.line', 'Go to Line…', 'Ctrl+G', () => this.openPalette('line'));
    add('go.definition', 'Go to Definition', 'F12', () => this.goToDefinitionAtCaret());
    add('go.back', 'Go Back', 'Alt+Left', () => this.goBack());
    add('go.forward', 'Go Forward', 'Alt+Right', () => this.goForward());
    add('edit.comment', 'Toggle Line Comment', 'Ctrl+/', act('editor.action.commentLine'));
    add('edit.indent', 'Indent Lines', 'Ctrl+]', act('editor.action.indentLines'));
    add('edit.outdent', 'Outdent Lines', 'Ctrl+[', act('editor.action.outdentLines'));
    add('edit.reindent', 'Reindent Lines (Verilog)', 'Ctrl+Alt+I', () => this.reindentCommand(false));
    add('edit.reindentAll', 'Reindent Whole File (Verilog)', '', () => this.reindentCommand(true));
    add('edit.moveUp', 'Move Line Up', 'Alt+Up', act('editor.action.moveLinesUpAction'));
    add('edit.moveDown', 'Move Line Down', 'Alt+Down', act('editor.action.moveLinesDownAction'));
    add('edit.copyUp', 'Copy Line Up', 'Shift+Alt+Up', act('editor.action.copyLinesUpAction'));
    add('edit.copyDown', 'Copy Line Down', 'Shift+Alt+Down', act('editor.action.copyLinesDownAction'));
    add('edit.deleteLine', 'Delete Line', 'Ctrl+Shift+K', act('editor.action.deleteLines'));
    add('edit.selectLine', 'Expand Selection to Line', 'Ctrl+L', act('expandLineSelection'));
    add('edit.bracket', 'Go to Matching Bracket / begin–end', 'Ctrl+Shift+\\', () => { if (this.active) this.jumpToMatchingBracket(this.active); });
    add('edit.trim', 'Trim Trailing Whitespace', '', () => { if (this.active) this.trimTrailingWhitespace(this.active); });
    add('edit.toSpaces', 'Convert Indentation to Spaces', '', () => { if (this.active) this.convertIndentation(this.active, true); });
    add('edit.toTabs', 'Convert Indentation to Tabs', '', () => { if (this.active) this.convertIndentation(this.active, false); });
    add('edit.find', 'Find', 'Ctrl+F', act('actions.find'));
    add('edit.replace', 'Replace', 'Ctrl+H', act('editor.action.startFindReplaceAction'));
    add('search.files', 'Search: Find in Files', 'Ctrl+Shift+F', () => { this.sidebarMode = 'search'; this.render('all'); });
    add('search.replace', 'Search: Replace in Files', 'Ctrl+Shift+H', () => { this.sidebarMode = 'search'; this.search.showReplace = true; this.render('all'); });
    add('hdl.snippet', 'HDL: Insert Snippet…', 'Ctrl+Shift+J', () => this.openPalette('snippet'));
    add('hdl.instance', 'HDL: Insert Module Instance…', 'Ctrl+Shift+I', () => this.openPalette('instance'));
    add('hdl.copyInst', 'HDL: Copy Instantiation Template', 'Ctrl+Shift+Alt+I', () => this.copyInstantiation());
    add('hdl.testbench', 'HDL: Generate Testbench File (Template)', 'Ctrl+Shift+G', () => this.generateTestbench());
    add('hdl.lint', 'HDL: Check File (Lint)', 'Ctrl+Shift+B', () => this.lintActive());
    add('hdl.run', 'HDL: Run Simulation', 'Ctrl+R', () => this.runActive());
    add('hdl.stop', 'HDL: Stop Simulation', 'Ctrl+.', () => this.stopRun());
    add('hdl.wave', 'HDL: Open Waveform in HDL Viewer', 'Ctrl+Shift+Y', () => this.openLastWaveform());
    add('hdl.tester', 'HDL: Generate Testbench in HDL Tester', 'Ctrl+Alt+T', () => this.generateTestbenchInTester());
    add('hdl.descend', 'HDL: Descend into Module', 'Ctrl+Alt+Down', () => this.descend());
    add('hdl.ascend', 'HDL: Ascend to Testbench / Parent', 'Ctrl+Alt+Up', () => this.ascend());
    add('view.tester', 'View: Switch to HDL Tester', 'Ctrl+2', () => Shell.show('tester'));
    add('hdl.language', 'Change Language Mode…', '', () => this.openPalette('language'));
    add('view.sidebar', 'View: Toggle Sidebar', 'Ctrl+B', () => this.toggleSidebar());
    add('view.panel', 'View: Toggle Panel', 'Ctrl+J', () => this.togglePanel());
    add('view.explorer', 'View: Show Explorer', 'Ctrl+Shift+E', () => { this.sidebarMode = 'explorer'; this.render('all'); });
    add('view.outline', 'View: Show Outline', '', () => { this.sidebarMode = 'outline'; this.render('all'); });
    add('view.hierarchy', 'View: Show Design Hierarchy', '', () => { this.sidebarMode = 'hierarchy'; this.render('all'); });
    add('view.snippets', 'View: Show Snippets', '', () => { this.sidebarMode = 'snippets'; this.render('all'); });
    add('view.problems', 'View: Show Problems', 'Ctrl+Shift+M', () => this.togglePanel('problems'));
    add('view.output', 'View: Show Output', 'Ctrl+Shift+U', () => this.togglePanel('output'));
    add('view.wrap', 'View: Toggle Word Wrap', 'Alt+Z', () => Prefs.set('editor.wordWrap', !Prefs.get('editor.wordWrap')));
    add('view.zoomIn', 'View: Zoom In', 'Ctrl+=', () => this.zoom(1));
    add('view.zoomOut', 'View: Zoom Out', 'Ctrl+-', () => this.zoom(-1));
    add('view.zoomReset', 'View: Reset Zoom', 'Ctrl+0', () => this.zoom(0));
    add('view.theme', 'Preferences: Color Theme', 'Ctrl+K Ctrl+T', () => this.openPalette('theme'));
    add('view.settings', 'Preferences: Open Settings', 'Ctrl+,', () => App.openSettings());
    return c;
  },
  reindentCommand(all) {
    if (!this.active || !this.reindent(this.active, all)) showToast('Reindent works on Verilog and SystemVerilog files');
  },
});
