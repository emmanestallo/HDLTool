'use strict';
/* global monaco, Host, PathUtil, Paths, Prefs, IS_WIN, Dialogs, showToast, copyText, HDLLanguage, Lexer, Structure, TextUtil, SymbolScanner,
   symbolPathAt, flattenSymbols, symPorts, Templates, NumberInfo, Workspace, SearchEngine, Tools, Linter, execLines, shellQuote, Viewer,
   HDLEditor, Typing, MONACO_LANG, newUUID, Shell, store */
// HDL Coder: documents and app logic. Port of CoderKit AppModel.swift, Document.swift, Hierarchy.swift.

class EditorDocument {
  constructor({ path = null, text = '', untitledName = 'Untitled', savedText = null }) {
    this.id = newUUID();
    this.path = path ? PathUtil.resolve(path) : null;
    this.untitledName = untitledName;
    this.language = HDLLanguage.detect(this.path || untitledName);
    this.initialText = text;
    this.savedText = savedText != null ? savedText : text;
    this.isDirty = text !== this.savedText;
    this.diagnostics = [];
    this.caret = { line: 1, column: 1, selected: 0, selectedLines: 0, totalLines: 1, numberHint: null, symbolPath: [] };
    const detected = EditorDocument.detectIndent(text);
    this.useSpaces = detected ? detected.spaces : Prefs.get('editor.insertSpaces');
    this.tabSize = detected && detected.spaces ? detected.size : Prefs.get('editor.tabSize');
    this.changedOnDisk = false;
    this.lineEnding = text.includes('\r\n') ? 'CRLF' : 'LF';
    this.suggestedDirectory = null;
    this.diskMtime = this.path ? (Host.fs.stat(this.path) || {}).mtime : null;
    this.initialSelection = null;
    this.viewState = null;
    this.model = null;
    this._cache = { v: -1 };
    this.symbols = SymbolScanner.scan(text, this.language);
  }

  // Monaco model, created on first use.
  ensureModel() {
    if (this.model) return this.model;
    this.model = monaco.editor.createModel(this.initialText, MONACO_LANG[this.language], monaco.Uri.parse('inmemory://hdl/' + this.id + '/' + encodeURIComponent(this.name)));
    this.model.updateOptions({ tabSize: this.tabSize, indentSize: this.tabSize, insertSpaces: this.useSpaces });
    this.model.setEOL(this.lineEnding === 'CRLF' ? monaco.editor.EndOfLineSequence.CRLF : monaco.editor.EndOfLineSequence.LF);
    this.initialText = '';
    return this.model;
  }
  get hasModel() { return !!this.model; }
  get text() { return this.model ? this.model.getValue() : this.initialText; }
  get key() { return this.path || 'untitled:' + this.id; }
  get name() { return this.path ? PathUtil.basename(this.path) : this.untitledName; }
  get indentUnit() { return this.useSpaces ? ' '.repeat(this.tabSize) : '\t'; }

  setLanguage(l) {
    if (l === this.language) return;
    this.language = l;
    if (this.model) monaco.editor.setModelLanguage(this.model, MONACO_LANG[l]);
    this._cache = { v: -1 };
    this.symbols = SymbolScanner.scan(this.text, l);
  }
  setIndent(spaces, size) {
    this.useSpaces = spaces;
    this.tabSize = size;
    if (this.model) this.model.updateOptions({ tabSize: size, indentSize: size, insertSpaces: spaces });
  }

  replaceAll(text, markSaved) {
    if (this.model) {
      const full = this.model.getFullModelRange();
      this.model.pushEditOperations([], [{ range: full, text }], () => null);
    } else {
      this.initialText = text;
      this.symbols = SymbolScanner.scan(text, this.language);
    }
    if (markSaved) { this.savedText = this.text; this.isDirty = false; }
  }

  // ---- Lexer data, cached per text version
  analysis() {
    const v = this.model ? this.model.getVersionId() : -2;
    if (this._cache.v === v && this._cache.lang === this.language) return this._cache;
    const text = this.text;
    const toks = Lexer.lex(text, this.language);
    this._cache = { v, lang: this.language, text, toks, lineStarts: Structure.lineStarts(text), pairs: null };
    return this._cache;
  }
  tokens() { return this.analysis().toks; }
  pairs() { const a = this.analysis(); if (!a.pairs) a.pairs = Structure.pairs(a.toks, a.text, this.language); return a.pairs; }
  lineIndex(off) {
    const ls = this.analysis().lineStarts;
    let lo = 0, hi = ls.length - 1;
    while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (ls[mid] <= off) lo = mid; else hi = mid - 1; }
    return lo;
  }
  lineText(line) {
    const a = this.analysis();
    if (line < 0 || line >= a.lineStarts.length) return '';
    const s = a.lineStarts[line];
    const e = line + 1 < a.lineStarts.length ? a.lineStarts[line + 1] - 1 : a.text.length;
    return a.text.slice(s, e).replace(/\r$/, '');
  }
  tokenIndexTouching(off) {
    const toks = this.tokens();
    const k = Lexer.indexAt(toks, off);
    if (k < toks.length && toks[k].start <= off && off < toks[k].end) return k;
    if (k > 0 && toks[k - 1].end === off) return k - 1;
    if (k < toks.length && toks[k].start === off) return k;
    return null;
  }
  isInCommentOrString(off) {
    const toks = this.tokens(), text = this.text;
    const k = Lexer.indexAt(toks, Math.max(0, off - 1));
    if (k >= toks.length) return false;
    const t = toks[k];
    if (t.kind !== 'comment' && t.kind !== 'string') return false;
    if (t.start < off && off < t.end) return true;
    if (off === t.end && t.kind === 'comment') { const s = Lexer.string(text, t); return s.startsWith('//') || s.startsWith('--') || !s.endsWith('*/'); }
    if (off === t.end && t.kind === 'string' && t.length > 0 && (t.length === 1 || text.charCodeAt(t.end - 1) !== 34)) return true;
    return false;
  }
  // Identifier (or `macro / $task / keyword) at an offset: [word, start, end] or null.
  wordAt(off) {
    const k = this.tokenIndexTouching(off);
    if (k == null) return null;
    const t = this.tokens()[k];
    if (!['ident', 'typeName', 'funcName', 'directive', 'system', 'type', 'keyword', 'control'].includes(t.kind)) return null;
    return [Lexer.string(this.text, t), t.start, t.end];
  }
  identifiers(caret) {
    const words = new Map();
    const text = this.text;
    for (const t of this.tokens()) {
      if (!['ident', 'typeName', 'funcName'].includes(t.kind) || t.end === caret) continue;
      words.set(Lexer.string(text, t), null);
    }
    for (const s of flattenSymbols(this.symbols)) words.set(s.name, s.kind);
    return words;
  }

  static detectIndent(text) {
    let tabs = 0, spaces = 0, prev = 0, n = 0;
    const widths = new Map();
    for (const line of text.split('\n')) {
      if (!line) continue;
      if (++n > 2000) break;
      if (line[0] === '\t') { tabs++; continue; }
      if (line[0] === ' ') {
        const k = /^ */.exec(line)[0].length;
        if (line.slice(k).startsWith('*')) continue;
        spaces++;
        const d = Math.abs(k - prev);
        if (d >= 2 && d <= 8) widths.set(d, (widths.get(d) || 0) + 1);
        prev = k;
      } else prev = 0;
    }
    if (!tabs && !spaces) return null;
    if (tabs > spaces) return { spaces: false, size: 4 };
    let best = 4, bestN = -1;
    for (const [w, c] of widths) if (c > bestN || (c === bestN && w < best)) { best = w; bestN = c; }
    return { spaces: true, size: [2, 3, 4, 8].includes(best) ? best : 4 };
  }
}

// ---------------------------------------------------------------- App model

const Coder = {
  workspace: new Workspace(),
  docs: [],
  activeID: null,
  sidebarMode: 'explorer',
  showPanel: false,
  panelTab: 'problems',
  problemsByOwner: new Map(),
  linting: new Set(),
  lastLintTool: null,
  output: [],
  runStatus: { kind: 'idle' },
  procId: null,
  lastVCD: null,
  lastRunSeconds: null,
  paletteMode: null,
  paletteText: '',
  recentFolders: store.get('recentFolders', []),
  recentFiles: store.get('recentFiles', []),
  search: { options: { query: '', caseSensitive: false, wholeWord: false, regex: false, include: '' }, replace: '', showReplace: false, results: [], running: false, collapsed: new Set(), searched: false },
  sessionEnabled: true,
  navBack: [], navForward: [],
  untitledCounter: 0,
  lintTimers: new Map(), lintGen: new Map(),
  editor: null,
  render: () => {},   // set by the UI

  get active() { return this.docs.find((d) => d.id === this.activeID) || null; },
  get languageStandard() { return Prefs.get('languageStandard'); },
  get indentUnitSetting() { return Prefs.get('editor.insertSpaces') ? ' '.repeat(Prefs.get('editor.tabSize')) : '\t'; },

  start() {
    this.workspace.onChange = () => this.render('sidebar', 'palette');
    this.registerWithShell();
    if (this.sessionEnabled) this.restoreSession();
    setInterval(() => this.onTimer(), 1500);
  },

  // ---------------------------------------------------------------- Documents

  activate(doc) {
    this.activeID = doc.id;
    if (doc.path) this.workspace.reveal(doc.path);
    this.render('all');
  },
  newFile({ kind = 'empty', name = null, text = null, language = null } = {}) {
    this.untitledCounter++;
    const n = name || `Untitled-${this.untitledCounter}`;
    const k = Templates.kinds.find((x) => x.id === kind);
    const ext = language === 'vhdl' ? 'vhd' : (language === 'systemVerilog' ? 'sv' : k.ext);
    const fileName = n.includes('.') ? n : n + '.' + ext;
    const body = text != null ? text : Templates.newFile(kind, kind === 'empty' ? '' : (n.includes('.') ? n.replace(/\.[^.]*$/, '') : n), this.indentUnitSetting);
    const doc = new EditorDocument({ text: body, untitledName: fileName, savedText: '' });
    if (language) doc.setLanguage(language);
    doc.isDirty = !!body;
    this.replaceEmptyUntitled();
    this.docs.push(doc);
    this.activate(doc);
    this.scheduleLint(doc, 300);
    return doc;
  },
  replaceEmptyUntitled() {
    if (this.docs.length === 1) {
      const only = this.docs[0];
      if (!only.path && !only.text && !only.isDirty) this.dropDoc(only);
    }
  },
  open(paths) {
    for (const p of paths) {
      const st = Host.fs.stat(p);
      if (!st) continue;
      if (st.isDir) this.openFolder(p); else this.openFile(p);
    }
  },
  openFile(p, { line = null, column = null, length = 0, recordHistory = true } = {}) {
    const path = PathUtil.resolve(p);
    const ext = Paths.ext(path);
    if (['vcd', 'fst', 'lxt', 'ghw'].includes(ext)) { Viewer.open(path); return null; }
    if (ext === 'hdltest') { if (Shell.openInTester) Shell.openInTester([path]); Shell.show('tester'); return null; }
    if (recordHistory) this.recordNav();
    const existing = this.docs.find((d) => d.path && Paths.same(d.path, path));
    if (existing) {
      this.activate(existing);
      if (line != null) this.reveal(existing, line, column, length);
      return existing;
    }
    if (!Host.fs.exists(path)) { Dialogs.alert(`Could not open “${PathUtil.basename(path)}”`, 'The file could not be read.'); return null; }
    if (Host.fs.isBinary(path)) { Host.openPath(path); return null; }
    const text = Host.fs.readText(path);
    if (text == null) { Dialogs.alert(`Could not open “${PathUtil.basename(path)}”`, 'The file could not be read.'); return null; }
    const doc = new EditorDocument({ path, text });
    this.replaceEmptyUntitled();
    this.docs.push(doc);
    this.activate(doc);
    this.addRecentFile(path);
    if (!(this.workspace.root && Paths.isUnder(path, this.workspace.root)) && !this.workspace.extraFiles.includes(path) && doc.language !== 'plain') {
      this.workspace.extraFiles.push(path);
      this.workspace.scan();
    }
    if (line != null) this.reveal(doc, line, column, length);
    this.scheduleLint(doc, 200);
    return doc;
  },
  openFolder(p) {
    this.workspace.setRoot(p);
    this.addRecentFolder(PathUtil.resolve(p));
    this.sidebarMode = 'explorer';
    this.render('all');
  },
  closeFolder() { this.workspace.setRoot(null); this.render('all'); },
  showOpenPanel() {
    const paths = Dialogs.openFiles({ title: 'Open', properties: ['openFile', 'multiSelections'],
      filters: [{ name: 'HDL files', extensions: [...HDLLanguage.hdlExtensions, 'hdltest'] }, { name: 'All files', extensions: ['*'] }] });
    if (paths.length) this.open(paths);
  },
  showOpenFolderPanel() {
    const paths = Dialogs.openFiles({ title: 'Choose a project folder', properties: ['openDirectory'] });
    if (paths.length) this.openFolder(paths[0]);
  },
  dropDoc(doc) {
    const i = this.docs.indexOf(doc);
    if (i < 0) return;
    this.docs.splice(i, 1);
    if (doc.model) doc.model.dispose();
    this.problemsByOwner.delete(doc.key);
    if (this.activeID === doc.id) this.activeID = this.docs.length ? this.docs[Math.min(i, this.docs.length - 1)].id : null;
  },
  close(doc) {
    if (doc.isDirty && !(doc.path == null && !doc.text)) {
      this.activeID = doc.id;
      this.render('all');
      const r = Dialogs.saveChanges(doc.name);
      if (r === 'cancel') return false;
      if (r === 'save' && !this.save(doc)) return false;
    }
    this.dropDoc(doc);
    this.refreshDiagnostics();
    if (doc.path) this.workspace.dropLive(doc.path);
    this.render('all');
    return true;
  },
  closeActive() { if (this.active) this.close(this.active); },
  closeOthers(keep) { for (const d of [...this.docs]) if (d.id !== keep.id && !this.close(d)) return; },
  closeAll() { for (const d of [...this.docs]) if (!this.close(d)) return false; return true; },

  // ---------------------------------------------------------------- Saving

  save(doc, saveAs = false) {
    let path = doc.path;
    if (saveAs || !path) {
      let name = doc.name;
      if (!doc.path) { const m = doc.symbols.find((s) => ['module', 'entity', 'architecture', 'package', 'interface', 'program', 'klass'].includes(s.kind)); if (m) name = m.name + PathUtil.extname(doc.untitledName); }
      const dir = doc.path ? PathUtil.dirname(doc.path) : (doc.suggestedDirectory || this.workspace.root || Host.launch.documents);
      const r = Dialogs.saveFile({ title: 'Save As', defaultPath: PathUtil.join(dir, name),
        filters: [{ name: 'HDL files', extensions: ['v', 'sv', 'vhd', 'vh', 'svh', 'vhdl'] }, { name: 'All files', extensions: ['*'] }] });
      if (!r) return false;
      path = r;
    }
    if (doc.model) {
      if (Prefs.get('trimTrailingWhitespace')) this.trimTrailingWhitespace(doc);
      if (Prefs.get('insertFinalNewline')) this.ensureFinalNewline(doc);
    }
    const text = doc.text;
    const err = Host.fs.writeText(path, text);
    if (err) { Dialogs.alert(`Could not save “${PathUtil.basename(path)}”`, err); return false; }
    const oldKey = doc.key;
    const resolved = PathUtil.resolve(path);
    if (!doc.path || !Paths.same(doc.path, resolved)) {
      doc.path = resolved;
      const lang = HDLLanguage.detect(resolved);
      if (lang !== doc.language) doc.setLanguage(lang);
      this.problemsByOwner.delete(oldKey);
    }
    doc.savedText = text;
    doc.isDirty = false;
    doc.changedOnDisk = false;
    doc.diskMtime = (Host.fs.stat(resolved) || {}).mtime;
    this.addRecentFile(resolved);
    this.workspace.updateLive(resolved, doc.language, doc.symbols);
    if (this.workspace.root && Paths.isUnder(resolved, this.workspace.root)) this.workspace.refreshListing();
    this.scheduleLint(doc, 0);
    this.render('all');
    return true;
  },
  saveAll() { for (const d of this.docs) if (d.isDirty && !this.save(d)) return; },
  revert(doc) {
    if (!doc.path) return;
    const text = Host.fs.readText(doc.path);
    if (text == null) return;
    doc.replaceAll(text, true);
    doc.diskMtime = (Host.fs.stat(doc.path) || {}).mtime;
    doc.changedOnDisk = false;
    this.scheduleLint(doc, 0);
    this.render('all');
  },

  // ---------------------------------------------------------------- Editor events

  textChanged(doc) {
    if (!doc.isDirty) { doc.isDirty = true; this.render('tabs', 'sidebar', 'title'); }
    clearTimeout(doc._dirtyTimer);
    doc._dirtyTimer = setTimeout(() => {
      const clean = doc.text === doc.savedText;
      if (doc.isDirty === clean) { doc.isDirty = !clean; this.render('tabs', 'sidebar', 'title'); }
    }, 350);
    clearTimeout(doc._symTimer);
    doc._symTimer = setTimeout(() => {
      const syms = SymbolScanner.scan(doc.text, doc.language, doc.tokens());
      if (JSON.stringify(syms) !== JSON.stringify(doc.symbols)) {
        doc.symbols = syms;
        if (doc.path) this.workspace.updateLive(doc.path, doc.language, syms);
        this.render('sidebar', 'title');
      }
      this.updateCaret(doc);
    }, 250);
    if (Prefs.get('lintWhileTyping')) this.scheduleLint(doc, 900);
  },

  updateCaret(doc) {
    const ed = this.editor;
    if (!ed || !doc.model || ed.getModel() !== doc.model) return;
    const sel = ed.getSelection();
    if (!sel) return;
    const model = doc.model;
    const off = model.getOffsetAt(sel.getStartPosition());
    const line = sel.startLineNumber - 1;
    const lineText = model.getLineContent(sel.startLineNumber);
    let col = 0;
    for (let i = 0; i < sel.startColumn - 1; i++) { if (lineText[i] === '\t') col += doc.tabSize - (col % doc.tabSize); else col++; }
    const len = model.getOffsetAt(sel.getEndPosition()) - off;
    const info = {
      line: line + 1, column: col + 1, selected: len, selectedLines: len > 0 ? sel.endLineNumber - sel.startLineNumber + 1 : 0,
      totalLines: model.getLineCount(), numberHint: null, symbolPath: symbolPathAt(doc.symbols, line).map((s) => s.name),
    };
    const k = doc.tokenIndexTouching(off);
    if (k != null && doc.tokens()[k].kind === 'number') info.numberHint = NumberInfo.describe(Lexer.string(doc.text, doc.tokens()[k]));
    if (JSON.stringify(info) !== JSON.stringify(doc.caret)) { doc.caret = info; this.render('status', 'breadcrumbs', 'title'); }
  },

  // ---------------------------------------------------------------- Lint

  get linterKind() { return Prefs.get('linter'); },
  scheduleLint(doc, delay) {
    if (doc.language === 'plain' || this.linterKind === 'off') return;
    clearTimeout(this.lintTimers.get(doc.id));
    this.lintTimers.set(doc.id, setTimeout(() => { if (this.docs.includes(doc)) this.runLint(doc); }, delay));
  },
  async runLint(doc) {
    if (!Tools.checked) Tools.detect();
    const gen = (this.lintGen.get(doc.id) || 0) + 1;
    this.lintGen.set(doc.id, gen);
    let fileName = doc.path ? PathUtil.basename(doc.path) : doc.untitledName;
    if (!PathUtil.extname(fileName)) fileName += doc.language === 'vhdl' ? '.vhd' : (doc.language === 'systemVerilog' ? '.sv' : '.v');
    const job = {
      key: doc.key, fileName, text: doc.text, originalPath: doc.path, language: doc.language,
      deps: doc.language === 'vhdl' ? [] : this.dependencyFiles(doc), includeDirs: this.includeDirs(doc),
      iverilog: Tools.iverilog, verilator: Tools.verilator, ghdl: Tools.ghdl, kind: this.linterKind, standard: this.languageStandard,
    };
    const key = doc.key;
    this.linting.add(key);
    this.render('status');
    const result = await Linter.run(job);
    this.linting.delete(key);
    if (this.lintGen.get(doc.id) !== gen || !this.docs.includes(doc) || doc.key !== key) { this.render('status'); return; }
    this.lastLintTool = result ? result.tool : null;
    this.problemsByOwner.set(key, result ? result.diagnostics : []);
    this.refreshDiagnostics();
  },
  lintActive() { if (this.active) { this.runLint(this.active); this.panelTab = 'problems'; this.showPanel = true; this.render('all'); } },
  get allProblems() {
    const seen = new Set(), out = [];
    for (const list of this.problemsByOwner.values()) {
      for (const d of list) { const k = `${d.file}|${d.line}|${d.message}`; if (!seen.has(k)) { seen.add(k); out.push(d); } }
    }
    const sev = { error: 0, warning: 1, info: 2 };
    return out.sort((a, b) => (a.file !== b.file ? (a.file < b.file ? -1 : 1) : a.line !== b.line ? a.line - b.line : sev[a.severity] - sev[b.severity]));
  },
  diagnosticsFor(key) {
    const own = this.problemsByOwner.get(key);
    const same = (f) => f === key || (!key.startsWith('untitled:') && Paths.same(f, key));
    if (own) return own.filter((d) => same(d.file));
    return this.allProblems.filter((d) => same(d.file));
  },
  refreshDiagnostics() {
    for (const d of this.docs) d.diagnostics = this.diagnosticsFor(d.key);
    if (this.applyDiagnostics) this.applyDiagnostics();
    this.render('all');
  },

  // ---------------------------------------------------------------- Dependencies

  dependencyFiles(doc) {
    const own = doc.path;
    const text = doc.text;
    const included = new Set(Coder.includes(text).map((n) => PathUtil.basename(n)));
    const ownNames = new Set(doc.symbols.map((s) => s.name.toLowerCase()));
    const docDir = doc.path ? PathUtil.dirname(doc.path) : null;
    const result = [];
    const visited = new Set();
    const queue = flattenSymbols(doc.symbols).filter((s) => s.kind === 'instance' && s.target).map((s) => s.target);
    const pick = (name) => {
      const defs = this.workspace.definitions(name).filter((d) => !own || !Paths.same(d.path, own));
      const d = defs.find((x) => docDir && Paths.same(PathUtil.dirname(x.path), docDir)) || defs[0];
      return d ? d.path : null;
    };
    while (queue.length) {
      const m = queue.shift();
      const key = m.toLowerCase();
      if (visited.has(key) || ownNames.has(key)) continue;
      visited.add(key);
      const path = pick(m);
      if (!path || included.has(PathUtil.basename(path))) continue;
      if (!result.includes(path)) result.push(path);
      const f = this.workspace.index.get(path);
      for (const s of (f ? f.symbols : [])) queue.push(...s.children.filter((c) => c.kind === 'instance' && c.target).map((c) => c.target));
    }
    const packages = [];
    if (HDLLanguage.isVerilogFamily(doc.language)) {
      const texts = [text, ...result.map((p) => Host.fs.readText(p) || '')];
      for (const t of texts) {
        const re = /\b([A-Za-z_][A-Za-z0-9_]*)::/g;
        let m;
        while ((m = re.exec(t))) {
          if (ownNames.has(m[1].toLowerCase())) continue;
          const def = this.workspace.definitions(m[1]).find((d) => d.symbol.kind === 'package' && (!own || !Paths.same(d.path, own)));
          if (def && !packages.includes(def.path) && !included.has(PathUtil.basename(def.path))) packages.push(def.path);
        }
      }
    }
    const rest = result.filter((p) => !packages.includes(p));
    if (doc.language === 'vhdl') rest.reverse();
    return [...packages, ...rest];
  },
  includeDirs(doc) {
    const dirs = [];
    const add = (d) => { if (d && !dirs.includes(d)) dirs.push(d); };
    add(doc.path ? PathUtil.dirname(doc.path) : null);
    add(this.workspace.root);
    for (const f of this.dependencyFiles(doc)) add(PathUtil.dirname(f));
    for (const p of this.workspace.index.keys()) if (p.endsWith('.vh') || p.endsWith('.svh')) add(PathUtil.dirname(p));
    return dirs;
  },
  includes(text) { const out = []; const re = /`include\s+"([^"]+)"/g; let m; while ((m = re.exec(text))) out.push(m[1]); return out; },
  dumpFiles(texts) { const out = []; for (const t of texts) { const re = /\$dumpfile\s*\(\s*"([^"]+)"/g; let m; while ((m = re.exec(t))) out.push(m[1]); } return out; },

  // ---------------------------------------------------------------- Run

  runActive() {
    const doc = this.active;
    if (!doc) return;
    if (this.runStatus.kind === 'compiling' || this.runStatus.kind === 'simulating') { this.stopRun(); return; }
    if (!doc.path) { if (!this.save(doc)) return; }
    else if (Prefs.get('saveBeforeRun')) { for (const d of this.docs) if (d.isDirty && d.path) this.save(d); }
    this.simulate(doc);
  },
  get isRunning() { return this.runStatus.kind === 'compiling' || this.runStatus.kind === 'simulating'; },
  stopRun() {
    if (!this.isRunning) return;
    this.runStatus = { kind: 'stopped' };
    if (this.procId != null) Host.proc.kill(this.procId);
    this.appendOutput('warning', 'Stopped.');
    this.render('all');
  },
  async exec(exe, args, cwd) {
    const r = execLines(exe, args, cwd, (l) => this.appendOutput('stdout', l, cwd));
    this.procId = r.id;
    const code = await r.promise;
    this.procId = null;
    return code;
  },
  async simulate(doc) {
    if (this.isRunning) return;
    if (!doc.path) { this.appendOutput('error', 'Save the file before running it.'); return; }
    const started = Date.now();
    this.output = [];
    this.lastVCD = null;
    this.runStatus = { kind: 'compiling' };
    this.panelTab = 'output';
    this.showPanel = true;
    this.render('all');
    if (!Tools.checked) Tools.detect();
    const cwd = PathUtil.dirname(doc.path);
    const outDir = PathUtil.join(cwd, 'sim_out');
    Host.fs.mkdir(outDir);
    const fail = (why) => { this.runStatus = { kind: 'failed', why }; this.render('all'); };
    if (doc.language === 'vhdl') { await this.runGHDL(doc, cwd, outDir, started); return; }
    if (!Tools.iverilog || !Tools.vvp) {
      this.appendOutput('error', 'Icarus Verilog was not found. ' + Tools.installHint());
      this.appendOutput('info', `Or set its location in Settings (${MOD}+,).`);
      fail('Icarus Verilog not found');
      return;
    }
    const modules = doc.symbols.filter((s) => s.kind === 'module' || s.kind === 'program');
    if (!modules.length) { this.appendOutput('error', `No module found in ${doc.name}.`); fail('No module'); return; }
    const instantiated = new Set(modules.flatMap((m) => m.children.filter((c) => c.kind === 'instance' && c.target).map((c) => c.target)));
    const roots = modules.filter((m) => !instantiated.has(m.name));
    const top = roots.find((m) => !symPorts(m).length) || roots[0] || modules[0];
    if (symPorts(top).length) {
      this.appendOutput('warning', `“${top.name}” has ports, so it is not a testbench. Running it anyway — its inputs will float. Use “Generate Testbench” (${MOD}+Shift+G) to make one.`);
    }
    const deps = this.dependencyFiles(doc);
    const vvpPath = PathUtil.join(outDir, top.name + '.vvp');
    const args = [this.languageStandard, '-o', vvpPath, '-s', top.name];
    for (const d of this.includeDirs(doc)) args.push('-I', d);
    args.push(doc.path, ...deps);
    this.appendOutput('command', '$ iverilog ' + args.map(shellQuote).join(' '));
    const compile = await this.exec(Tools.iverilog, args, cwd);
    if (this.runStatus.kind === 'stopped') return;
    if (compile !== 0) { this.appendOutput('error', `Compile failed (iverilog exited with ${compile}).`); fail('Compile failed'); return; }
    this.runStatus = { kind: 'simulating' };
    this.render('status', 'title', 'panel');
    this.appendOutput('command', '$ vvp -n ' + shellQuote('sim_out/' + PathUtil.basename(vvpPath)));
    const sim = await this.exec(Tools.vvp, ['-n', vvpPath], cwd);
    if (this.runStatus.kind === 'stopped') return;
    this.lastRunSeconds = (Date.now() - started) / 1000;
    if (sim !== 0) { this.appendOutput('error', `Simulation failed (vvp exited with ${sim}).`); fail('Simulation failed'); return; }
    this.finishRun([doc.text, ...deps.map((p) => Host.fs.readText(p) || '')], cwd, started);
  },
  finishRun(texts, cwd, started) {
    let vcd = null;
    for (const name of this.dumpFiles(texts)) {
      const p = PathUtil.isAbsolute(name) ? name : PathUtil.join(cwd, name);
      if (Host.fs.exists(p)) { vcd = p; break; }
    }
    if (!vcd) {
      for (const dir of [cwd, PathUtil.join(cwd, 'sim_out')]) {
        const fresh = Host.fs.list(dir).filter((e) => !e.isDir && /\.(vcd|fst)$/i.test(e.name)).map((e) => PathUtil.join(dir, e.name))
          .filter((p) => ((Host.fs.stat(p) || {}).mtime || 0) >= started - 1000);
        if (fresh.length) { vcd = fresh[0]; break; }
      }
    }
    if (vcd) {
      this.lastVCD = vcd;
      this.appendOutput('success', `✓ Waveform written to ${vcd}`);
      if (Prefs.get('openWaveformsInViewer') && this.openWaveforms !== false) Viewer.open(vcd);
    } else {
      this.appendOutput('info', 'No waveform was written. Add $dumpfile/$dumpvars to the testbench (snippet “dump”) to get one.');
    }
    this.appendOutput('success', `Simulation finished in ${(this.lastRunSeconds || 0).toFixed(2)} s`);
    this.runStatus = { kind: 'passed' };
    this.render('all');
  },
  async runGHDL(doc, cwd, outDir, started) {
    const fail = (why) => { this.runStatus = { kind: 'failed', why }; this.render('all'); };
    if (!Tools.ghdl) { this.appendOutput('error', 'GHDL was not found. Install it to simulate VHDL (for example from github.com/ghdl/ghdl/releases).'); fail('GHDL not found'); return; }
    const entities = doc.symbols.filter((s) => s.kind === 'entity');
    const top = entities.find((e) => !symPorts(e).length) || entities[0];
    if (!top) { this.appendOutput('error', `No entity found in ${doc.name}.`); fail('No entity'); return; }
    const deps = this.dependencyFiles(doc);
    const work = ['--std=08', '-fsynopsys', `--workdir=${outDir}`];
    const analyze = [...work, ...deps, doc.path];
    this.appendOutput('command', '$ ghdl -a ' + analyze.map(shellQuote).join(' '));
    let st = await this.exec(Tools.ghdl, ['-a', ...analyze], cwd);
    if (st !== 0 || this.runStatus.kind === 'stopped') { if (this.runStatus.kind !== 'stopped') fail('Analysis failed'); return; }
    this.appendOutput('command', `$ ghdl -e ${top.name}`);
    st = await this.exec(Tools.ghdl, ['-e', ...work, '-o', PathUtil.join(outDir, top.name.toLowerCase() + (IS_WIN ? '.exe' : '')), top.name], cwd);
    if (st !== 0 || this.runStatus.kind === 'stopped') { if (this.runStatus.kind !== 'stopped') fail('Elaboration failed'); return; }
    this.runStatus = { kind: 'simulating' };
    this.render('status');
    const vcd = PathUtil.join(outDir, top.name.toLowerCase() + '.vcd');
    this.appendOutput('command', `$ ghdl -r ${top.name} --vcd=sim_out/${PathUtil.basename(vcd)}`);
    st = await this.exec(Tools.ghdl, ['-r', ...work, top.name, `--vcd=${vcd}`, '--stop-time=1ms'], cwd);
    if (this.runStatus.kind === 'stopped') return;
    this.lastRunSeconds = (Date.now() - started) / 1000;
    if (st !== 0) { this.appendOutput('error', `Simulation failed (ghdl exited with ${st}).`); fail('Simulation failed'); return; }
    this.finishRun([], outDir, started);
  },
  appendOutput(kind, text, cwd) {
    let k = kind, link = null;
    if (kind === 'stdout' || kind === 'error' || kind === 'warning') {
      if (kind === 'stdout') { const l = text.toLowerCase(); if (l.includes('error') || l.includes('fatal')) k = 'error'; else if (l.includes('warning')) k = 'warning'; }
      link = this.parseLink(text, cwd);
    }
    this.output.push({ kind: k, text, link });
    if (this.output.length > 6000) this.output.splice(0, this.output.length - 6000);
    this.render('panel');
  },
  parseLink(text, cwd) {
    const m = /((?:[A-Za-z]:)?[^\s:'"]+\.(?:v|sv|vh|svh|vhd|vhdl)):(\d+)/.exec(text);
    if (!m) return null;
    let p = m[1];
    if (!PathUtil.isAbsolute(p) && cwd) p = PathUtil.resolve(cwd, p);
    if (!Host.fs.exists(p)) return null;
    return { path: p, line: parseInt(m[2], 10) || 1 };
  },
  openLastWaveform() { if (this.lastVCD) Viewer.open(this.lastVCD); else showToast(`No waveform yet — run a testbench first (${MOD}+R)`); },

  // ---------------------------------------------------------------- Navigation

  caretOffset(doc) {
    const ed = this.editor;
    if (!ed || !doc || !doc.model || ed.getModel() !== doc.model) return 0;
    return doc.model.getOffsetAt(ed.getPosition());
  },
  currentLocation() { const d = this.active; return d ? { path: d.path, docID: d.id, offset: this.caretOffset(d) } : null; },
  recordNav() {
    const loc = this.currentLocation();
    if (!loc) return;
    const last = this.navBack[this.navBack.length - 1];
    if (!last || last.docID !== loc.docID || last.offset !== loc.offset) this.navBack.push(loc);
    if (this.navBack.length > 100) this.navBack.shift();
    this.navForward = [];
  },
  goLoc(loc) {
    let d = this.docs.find((x) => x.id === loc.docID) || (loc.path && this.docs.find((x) => x.path && Paths.same(x.path, loc.path)));
    if (d) this.activate(d);
    else if (loc.path) d = this.openFile(loc.path, { recordHistory: false });
    if (d) this.select(d, loc.offset, 0);
  },
  goBack() { const loc = this.navBack.pop(); if (!loc) return; const cur = this.currentLocation(); if (cur) this.navForward.push(cur); this.goLoc(loc); },
  goForward() { const loc = this.navForward.pop(); if (!loc) return; const cur = this.currentLocation(); if (cur) this.navBack.push(cur); this.goLoc(loc); },
  // Selects [offset, offset+length) in a document (once its editor is showing).
  select(doc, offset, length) { doc.pendingSelect = { offset, length }; if (this.applyPendingSelect) this.applyPendingSelect(doc); },
  reveal(doc, line, column = null, length = 0) { doc.pendingReveal = { line, column, length }; if (this.applyPendingSelect) this.applyPendingSelect(doc); },
  goTo(path, line, column = null, length = 0) {
    if (path.startsWith('untitled:')) {
      const d = this.docs.find((x) => x.key === path);
      if (d) { this.recordNav(); this.activate(d); this.reveal(d, line, column, length); }
      return;
    }
    this.openFile(path, { line, column, length });
  },
  goToSymbol(s, path) {
    if (path && (!this.active || !this.active.path || !Paths.same(path, this.active.path))) this.openFile(path);
    else this.recordNav();
    const d = (path && this.docs.find((x) => x.path && Paths.same(x.path, path))) || this.active;
    if (!d) return;
    if (s.offset + s.name.length <= d.text.length) this.select(d, s.offset, s.name.length);
    else this.reveal(d, s.line + 1);
  },
  goToDefinition(word, doc, offset) {
    const vhdl = doc.language === 'vhdl';
    const same = (a, b) => (vhdl ? a.toLowerCase() === b.toLowerCase() : a === b);
    if (word.startsWith('`')) {
      const name = word.slice(1).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const re = new RegExp('`define\\s+' + name + '\\b');
      const candidates = [[doc.key, doc.text]];
      for (const p of this.workspace.index.keys()) if (!doc.path || !Paths.same(p, doc.path)) candidates.push([p, Host.fs.readText(p) || '']);
      for (const [p, t] of candidates) {
        const m = re.exec(t);
        if (m) { this.goTo(p, t.slice(0, m.index).split('\n').length); return; }
      }
      showToast(`No \`define found for ${word.slice(1)}`);
      return;
    }
    const line = doc.lineIndex(offset);
    const path = symbolPathAt(doc.symbols, line);
    const w = doc.wordAt(offset);
    if (offset > 0 && w && w[1] > 0) {
      let p = w[1] - 1;
      const text = doc.text;
      while (p > 0 && (text[p] === ' ' || text[p] === '\t')) p--;
      if (text[p] === '.') {
        const inst = [...path].reverse().find((s) => s.kind === 'instance');
        const def = inst && inst.target && this.workspace.definitions(inst.target)[0];
        const port = def && def.symbol.children.find((c) => (c.kind === 'port' || c.kind === 'param') && same(c.name, word));
        if (port) { this.goToSymbol(port, def.path); return; }
      }
    }
    const lineText = doc.lineText(line);
    const inc = /`include\s*"([^"]+)"/.exec(lineText);
    if (inc) {
      for (const dir of this.includeDirs(doc)) { const p = PathUtil.join(dir, inc[1]); if (Host.fs.exists(p)) { this.openFile(p); return; } }
    }
    if (path.length) {
      const container = path[0];
      let scope = container.children;
      if (container.kind === 'architecture' && container.target) {
        const e = doc.symbols.find((s) => s.kind === 'entity' && same(s.name, container.target)) || (this.workspace.definitions(container.target)[0] || {}).symbol;
        if (e) scope = scope.concat(e.children);
      }
      const s = scope.find((x) => same(x.name, word) && x.kind !== 'instance' && x.offset !== (w ? w[1] : -1)) || scope.find((x) => same(x.name, word));
      if (s) { this.goToSymbol(s, doc.path); return; }
    }
    const defs = this.workspace.definitions(word);
    const def = defs.find((d) => doc.path && Paths.same(d.path, doc.path)) || defs[0];
    if (def) { this.goToSymbol(def.symbol, def.path); return; }
    const s = flattenSymbols(doc.symbols).find((x) => same(x.name, word) && x.kind !== 'instance');
    if (s) { this.goToSymbol(s, doc.path); return; }
    showToast(`No definition found for “${word}”`);
  },
  goToDefinitionAtCaret() {
    const d = this.active;
    if (!d) return;
    const off = this.caretOffset(d);
    const w = d.wordAt(off);
    if (w) this.goToDefinition(w[0], d, off);
  },
  selectedOrCaretWord() {
    const d = this.active, ed = this.editor;
    if (!d || !ed) return null;
    const sel = ed.getSelection();
    const text = d.model.getValueInRange(sel);
    if (text && text.length < 200) return text;
    const w = d.wordAt(this.caretOffset(d));
    return w ? w[0] : null;
  },
  findReferences(word) {
    Object.assign(this.search.options, { query: word, wholeWord: true, regex: false, caseSensitive: this.active ? this.active.language !== 'vhdl' : true });
    this.sidebarMode = 'search';
    this.runSearch();
    this.render('all');
  },

  // ---------------------------------------------------------------- Templates

  moduleForTemplates() {
    const d = this.active;
    if (!d) return null;
    const off = this.caretOffset(d);
    const w = d.wordAt(off);
    if (w) {
      const def = this.workspace.definitions(w[0]).find((x) => ['module', 'entity', 'interface'].includes(x.symbol.kind));
      if (def) { const f = this.workspace.index.get(def.path); return [def.symbol, f ? f.language : d.language]; }
    }
    const line = d.lineIndex(off);
    const p = symbolPathAt(d.symbols, line);
    let m = p.find((s) => s.kind === 'module' || s.kind === 'entity');
    if (!m) {
      const arch = p.find((s) => s.kind === 'architecture');
      if (arch && arch.target) m = d.symbols.find((s) => s.kind === 'entity' && s.name.toLowerCase() === arch.target.toLowerCase());
    }
    if (!m) m = d.symbols.find((s) => s.kind === 'module' || s.kind === 'entity');
    return m ? [m, d.language] : null;
  },
  copyInstantiation() {
    const r = this.moduleForTemplates();
    if (!r) { showToast('No module found'); return; }
    copyText(Templates.instance(r[0], r[1], this.active ? this.active.indentUnit : '    '));
    showToast(`Copied instantiation template for ${r[0].name}`);
  },
  insertInstance(m) {
    const d = this.active;
    if (!d || d.language === 'plain') return;
    this.insertBlock(d, Templates.instance(m, d.language, d.indentUnit));
  },
  generateTestbench() {
    const r = this.moduleForTemplates();
    if (!r) { showToast('No module found in this file'); return; }
    const [m, lang] = r;
    if (!symPorts(m).length && lang !== 'vhdl') { showToast(`“${m.name}” has no ports — it already looks like a testbench`); return; }
    const tb = Templates.testbench(m, lang, this.active ? this.active.indentUnit : '    ');
    const ext = lang === 'vhdl' ? 'vhd' : (lang === 'systemVerilog' ? 'sv' : 'v');
    const src = this.active && this.active.path ? PathUtil.dirname(this.active.path) : null;
    const doc = this.newFile({ kind: 'empty', name: `${tb.name}.${ext}`, text: tb.text, language: lang });
    doc.suggestedDirectory = src;
    showToast(`Generated ${tb.name} — save it to run it`);
  },

  // ---------------------------------------------------------------- Search

  runSearch() {
    const opts = Object.assign({}, this.search.options);
    if (!opts.query) { this.search.results = []; this.search.searched = false; this.render('sidebar', 'activity'); return; }
    if (!SearchEngine.makeRegex(opts)) { this.search.results = []; this.search.searched = true; this.render('sidebar', 'activity'); return; }
    const buffers = new Map();
    for (const d of this.docs) if (d.path) buffers.set(d.path, d.text);
    const files = this.workspace.root ? this.workspace.files : this.docs.filter((d) => d.path).map((d) => d.path);
    this.search.running = true;
    this.render('sidebar');
    clearTimeout(this._searchTimer);
    this._searchTimer = setTimeout(() => {
      if (JSON.stringify(opts) !== JSON.stringify(this.search.options)) return;
      this.search.results = SearchEngine.search(opts, files, buffers);
      this.search.running = false;
      this.search.searched = true;
      this.render('sidebar', 'activity');
    }, 120);
  },
  replaceAll() {
    const re = SearchEngine.makeRegex(this.search.options);
    if (!re || !this.search.results.length) return;
    const count = this.search.results.reduce((a, r) => a + r.matches.length, 0);
    const files = this.search.results.length;
    if (!Dialogs.confirm(`Replace ${count} occurrence${count === 1 ? '' : 's'} in ${files} file${files === 1 ? '' : 's'}?`,
      'Open files are changed in the editor (you can undo there). Other files are changed on disk.', 'Replace')) return;
    const rep = this.search.options.regex ? this.search.replace : this.search.replace.replace(/\$/g, '$$$$');
    for (const r of this.search.results) {
      const d = this.docs.find((x) => x.path && Paths.same(x.path, r.path));
      if (d) { const t = d.text; const n = t.replace(re, rep); if (n !== t) { d.ensureModel(); d.replaceAll(n, false); } }
      else { const t = Host.fs.readText(r.path); if (t != null) Host.fs.writeText(r.path, t.replace(re, rep)); }
    }
    this.runSearch();
  },

  // ---------------------------------------------------------------- Layout

  openPalette(mode = 'files', text = null) {
    const prefix = { commands: '>', symbols: '@', line: ':', modules: '#' }[mode] || '';
    this.paletteMode = mode;
    this.paletteText = text != null ? text : prefix;
    this.render('palette');
  },
  closePalette() { this.paletteMode = null; this.render('palette'); if (this.editor && this.active) this.editor.focus(); },
  toggleSidebar() { this.sidebarMode = this.sidebarMode ? null : 'explorer'; this.render('all'); },
  togglePanel(tab) {
    if (tab) { if (this.showPanel && this.panelTab === tab) this.showPanel = false; else { this.panelTab = tab; this.showPanel = true; } }
    else this.showPanel = !this.showPanel;
    this.render('all');
  },
  zoom(delta) {
    const cur = Prefs.get('editor.fontSize');
    Prefs.set('editor.fontSize', delta === 0 ? 13 : Math.min(36, Math.max(8, cur + delta)));
  },
  setIndentation(spaces, size) { if (this.active) { this.active.setIndent(spaces, size); this.render('status'); } },

  // ---------------------------------------------------------------- Explorer file operations

  async newFileIn(dir) {
    const name = await Dialogs.prompt('New File', `Name of the new file in ${PathUtil.basename(dir)}:`, 'new_module.v', 'Create');
    if (!name) return;
    const p = PathUtil.join(dir, name);
    if (Host.fs.exists(p)) { Dialogs.alert(`“${name}” already exists`); return; }
    const text = Templates.starter(name).replace(/ {4}/g, this.indentUnitSetting);
    const err = Host.fs.writeText(p, text);
    if (err) { Dialogs.alert('Could not create the file', err); return; }
    this.workspace.expanded.add(dir);
    this.workspace.refreshListing();
    this.openFile(p);
  },
  async newFolderIn(dir) {
    const name = await Dialogs.prompt('New Folder', `Name of the new folder in ${PathUtil.basename(dir)}:`, 'rtl', 'Create');
    if (!name) return;
    const err = Host.fs.mkdir(PathUtil.join(dir, name));
    if (err) { Dialogs.alert('Could not create the folder', err); return; }
    this.workspace.expanded.add(dir);
    this.workspace.refreshListing();
  },
  async rename(p) {
    const base = PathUtil.basename(p);
    const name = await Dialogs.prompt('Rename', `New name for “${base}”:`, base, 'Rename');
    if (!name || name === base) return;
    const dest = PathUtil.join(PathUtil.dirname(p), name);
    const err = Host.fs.rename(p, dest);
    if (err) { Dialogs.alert('Could not rename', err); return; }
    for (const d of this.docs) {
      if (d.path && (Paths.same(d.path, p) || Paths.isUnder(d.path, p))) {
        this.problemsByOwner.delete(d.key);
        d.path = dest + d.path.slice(p.length);
        d.diskMtime = (Host.fs.stat(d.path) || {}).mtime;
        this.scheduleLint(d, 100);
      }
    }
    this.workspace.refreshListing();
    this.render('all');
  },
  async moveToTrash(p) {
    if (!Dialogs.confirm(`Move “${PathUtil.basename(p)}” to the Recycle Bin?`, 'You can restore it from the Recycle Bin.', 'Move to Recycle Bin')) return;
    try { await Host.trash(p); } catch (e) { Dialogs.alert('Could not move to the Recycle Bin', String(e.message || e)); return; }
    for (const d of [...this.docs]) {
      if (d.path && (Paths.same(d.path, p) || Paths.isUnder(d.path, p))) { if (!d.isDirty) this.close(d); else d.changedOnDisk = true; }
    }
    this.workspace.refreshListing();
    this.render('all');
  },

  // ---------------------------------------------------------------- Examples

  exampleDir() { const d = Host.launch.examples; return Host.fs.exists(PathUtil.join(d, 'counter.v')) ? d : null; },
  // Copies the bundled examples to Documents\HDL Simulator\Examples (shared by both tabs) and returns that folder.
  installExamples() {
    const src = this.exampleDir();
    if (!src) return null;
    const dest = PathUtil.join(Host.launch.documents, 'HDL Simulator', 'Examples');
    Host.fs.mkdir(dest);
    for (const e of Host.fs.list(src)) {
      if (e.isDir) continue;
      const target = PathUtil.join(dest, e.name);
      if (Host.fs.exists(target)) continue;
      if (e.name.endsWith('.hdltest')) {
        const text = Host.fs.readText(PathUtil.join(src, e.name)) || '';
        const fixed = text.replace(/"__EXAMPLES__([^"]*)"/g, (_m, rest) => JSON.stringify(PathUtil.join(dest, ...rest.split('/').filter(Boolean)) || dest));
        Host.fs.writeText(target, fixed);
      } else Host.fs.copy(PathUtil.join(src, e.name), target);
    }
    return dest;
  },
  openExamples() {
    const dest = this.installExamples();
    if (!dest) return;
    this.openFolder(dest);
    const tb = PathUtil.join(dest, 'tb_counter.v');
    this.openFile(Host.fs.exists(tb) ? tb : PathUtil.join(dest, 'counter.v'));
  },

  // ---------------------------------------------------------------- Recent

  addRecentFile(p) {
    this.recentFiles = [p, ...this.recentFiles.filter((x) => x !== p)].slice(0, 15);
    store.set('recentFiles', this.recentFiles);
  },
  addRecentFolder(p) {
    this.recentFolders = [p, ...this.recentFolders.filter((x) => x !== p)].slice(0, 10);
    store.set('recentFolders', this.recentFolders);
  },
  clearRecent() { this.recentFiles = []; this.recentFolders = []; store.set('recentFiles', []); store.set('recentFolders', []); this.render('all'); },

  // ---------------------------------------------------------------- Timer: files changed on disk, session

  onTimer() {
    this.tick = (this.tick || 0) + 1;
    for (const d of this.docs) {
      if (!d.path) continue;
      const st = Host.fs.stat(d.path);
      if (!st || st.mtime === d.diskMtime) continue;
      if (!d.isDirty) {
        const text = Host.fs.readText(d.path);
        if (text != null && text !== d.text) { d.replaceAll(text, true); this.scheduleLint(d, 100); }
        d.diskMtime = st.mtime;
      } else if (!d.changedOnDisk) { d.changedOnDisk = true; d.diskMtime = st.mtime; this.render('all'); }
    }
    if (this.tick % 2 === 0) this.workspace.poll();
    if (this.sessionEnabled) this.saveSession();
  },
  sessionPath() { return PathUtil.join(Host.launch.userData, 'coder-session.json'); },
  saveSession() {
    const s = {
      root: this.workspace.root, expanded: [...this.workspace.expanded],
      docs: this.docs.map((d) => {
        const keepText = !d.path || d.isDirty;
        return { path: d.path, untitledName: d.untitledName, text: keepText ? d.text : null, saved: !d.path ? null : (d.isDirty ? d.savedText : null),
          language: d.language, selection: d.model ? (this.editor && this.editor.getModel() === d.model ? this.caretOffset(d) : (d.lastOffset || 0)) : (d.initialSelection || 0),
          useSpaces: d.useSpaces, tabSize: d.tabSize };
      }),
      active: this.docs.findIndex((d) => d.id === this.activeID),
      sidebar: this.sidebarMode, showPanel: this.showPanel, panelTab: this.panelTab, extraFiles: this.workspace.extraFiles,
    };
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
    this.workspace.extraFiles = (s.extraFiles || []).filter((p) => Host.fs.exists(p));
    if (s.root && Host.fs.exists(s.root)) { this.workspace.setRoot(s.root); this.workspace.expanded = new Set(s.expanded || []); }
    for (const sd of s.docs || []) {
      let doc = null;
      if (sd.path) {
        if (sd.text != null) doc = new EditorDocument({ path: sd.path, text: sd.text, untitledName: sd.untitledName, savedText: sd.saved != null ? sd.saved : (Host.fs.readText(sd.path) || '') });
        else { const t = Host.fs.readText(sd.path); if (t != null) doc = new EditorDocument({ path: sd.path, text: t }); }
      } else if (sd.text != null) {
        doc = new EditorDocument({ text: sd.text, untitledName: sd.untitledName, savedText: '' });
        const m = /-(\d+)\./.exec(sd.untitledName || '');
        if (m) this.untitledCounter = Math.max(this.untitledCounter, +m[1]);
      }
      if (!doc) continue;
      if (HDLLanguage.all.includes(sd.language)) doc.setLanguage(sd.language);
      doc.useSpaces = sd.useSpaces;
      doc.tabSize = sd.tabSize;
      doc.initialSelection = sd.selection || 0;
      this.docs.push(doc);
      this.scheduleLint(doc, 500);
    }
    this.activeID = (this.docs[s.active] || this.docs[0] || {}).id || null;
    this.sidebarMode = s.sidebar === undefined ? 'explorer' : s.sidebar;
    this.showPanel = !!s.showPanel;
    this.panelTab = s.panelTab || 'problems';
  },

  // ---------------------------------------------------------------- Editing helpers (on the active Monaco model)

  edit(doc, range, text, selectOffset) {
    const model = doc.ensureModel();
    const a = model.getPositionAt(range[0]), b = model.getPositionAt(range[1]);
    const ed = this.editor && this.editor.getModel() === model ? this.editor : null;
    if (ed) {
      ed.pushUndoStop();
      ed.executeEdits('hdl', [{ range: new monaco.Range(a.lineNumber, a.column, b.lineNumber, b.column), text }]);
      ed.pushUndoStop();
    } else model.pushEditOperations([], [{ range: new monaco.Range(a.lineNumber, a.column, b.lineNumber, b.column), text }], () => null);
    if (selectOffset != null) this.select(doc, selectOffset[0], selectOffset[1]);
  },
  insertBlock(doc, text) {
    const ed = this.editor;
    if (!ed || !doc.model || ed.getModel() !== doc.model) return;
    const off = this.caretOffset(doc);
    const full = doc.text;
    const lineStart = full.lastIndexOf('\n', off - 1) + 1;
    const base = TextUtil.leadingWhitespace(full.slice(lineStart));
    const indented = text.split('\n').map((l, i) => (i === 0 || !l ? l : base + l)).join('\n');
    const sel = ed.getSelection();
    const a = doc.model.getOffsetAt(sel.getStartPosition()), b = doc.model.getOffsetAt(sel.getEndPosition());
    this.edit(doc, [a, b], indented, null);
    const after = a + indented.length;
    const m = /<#[^#\n]*#>/.exec(indented);
    if (m) this.select(doc, a + m.index, m[0].length); else this.select(doc, after, 0);
    ed.focus();
  },
  insertSnippet(doc, s) {
    const ed = this.editor;
    if (!ed || !doc.model || ed.getModel() !== doc.model) return;
    const off = this.caretOffset(doc);
    const full = doc.text;
    const base = TextUtil.leadingWhitespace(full.slice(full.lastIndexOf('\n', off - 1) + 1));
    const body = Snippets.toMonaco(Snippets.expand(s, base, doc.indentUnit));
    ed.focus();
    ed.getContribution('snippetController2').insert(body);
  },
  reindent(doc, all) {
    if (!doc || !HDLLanguage.isVerilogFamily(doc.language)) return false;
    const model = doc.ensureModel();
    const text = doc.text;
    const levels = Structure.indentLevels(text, doc.tokens(), doc.language);
    const ed = this.editor && this.editor.getModel() === model ? this.editor : null;
    const sel = ed ? ed.getSelection() : null;
    let first = 0, last = model.getLineCount() - 1;
    if (!all && sel && !sel.isEmpty()) { first = sel.startLineNumber - 1; last = sel.endLineNumber - 1 - (sel.endColumn === 1 && sel.endLineNumber > sel.startLineNumber ? 1 : 0); }
    const edits = [];
    for (let li = first; li <= last; li++) {
      const lvl = levels[li];
      if (lvl == null) continue;
      const line = model.getLineContent(li + 1);
      const lead = /^[ \t]*/.exec(line)[0];
      const body = line.slice(lead.length);
      const want = body ? doc.indentUnit.repeat(lvl) : '';
      if (lead !== want) edits.push({ range: new monaco.Range(li + 1, 1, li + 1, lead.length + 1), text: want });
    }
    if (!edits.length) return true;
    if (ed) { ed.pushUndoStop(); ed.executeEdits('reindent', edits); ed.pushUndoStop(); }
    else model.pushEditOperations([], edits, () => null);
    return true;
  },
  trimTrailingWhitespace(doc) {
    const model = doc.ensureModel();
    const edits = [];
    for (let i = 1; i <= model.getLineCount(); i++) {
      const l = model.getLineContent(i);
      const t = l.replace(/[ \t]+$/, '');
      if (t.length !== l.length) edits.push({ range: new monaco.Range(i, t.length + 1, i, l.length + 1), text: '' });
    }
    if (!edits.length) return;
    const ed = this.editor && this.editor.getModel() === model ? this.editor : null;
    // Don't strip the line being typed on (the caret line keeps its spaces until the caret leaves).
    if (ed) ed.executeEdits('trim', edits); else model.pushEditOperations([], edits, () => null);
  },
  ensureFinalNewline(doc) {
    const model = doc.ensureModel();
    const n = model.getLineCount();
    if (model.getLineContent(n) === '' || (n === 1 && !model.getValue())) return;
    const col = model.getLineMaxColumn(n);
    model.pushEditOperations([], [{ range: new monaco.Range(n, col, n, col), text: model.getEOL() }], () => null);
  },
  convertIndentation(doc, toSpaces) {
    const model = doc.ensureModel();
    const edits = [];
    for (let i = 1; i <= model.getLineCount(); i++) {
      const l = model.getLineContent(i);
      const lead = /^[ \t]*/.exec(l)[0];
      const want = TextUtil.makeIndent(TextUtil.indentWidth(lead, doc.tabSize), doc.tabSize, toSpaces);
      if (lead !== want) edits.push({ range: new monaco.Range(i, 1, i, lead.length + 1), text: want });
    }
    doc.setIndent(toSpaces, doc.tabSize);
    if (edits.length) model.pushEditOperations([], edits, () => null);
    this.render('status');
  },
  jumpToMatchingBracket(doc) {
    const off = this.caretOffset(doc);
    for (const probe of [off, off - 1]) {
      if (probe < 0) continue;
      const k = doc.tokenIndexTouching(probe);
      const m = k != null ? doc.pairs().get(k) : null;
      if (m != null) { this.select(doc, doc.tokens()[m].start, 0); return; }
    }
  },
};

const MOD_KEY = () => MOD;

if (typeof module !== 'undefined') module.exports = { EditorDocument, Coder };
