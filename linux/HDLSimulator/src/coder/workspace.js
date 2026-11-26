'use strict';
/* global Host, PathUtil, Paths, HDLLanguage, SymbolScanner */
// The open folder: file tree, file list and a symbol index of all HDL files. Port of Workspace.swift.

class Workspace {
  constructor() {
    this.root = null;
    this.expanded = new Set();
    this.files = [];          // all files (for Go to File)
    this.index = new Map();   // path -> { mtime, language, symbols } (mtime Infinity = live from an open editor)
    this.indexing = false;
    this.extraFiles = [];
    this.listingCache = new Map();
    this.listingDates = new Map();
    this.moduleTable = new Map();
    this.lastFullScan = 0;
    this.scanning = false;
    this.onChange = null;     // called after the index or listing changes
  }
  static hiddenNames = new Set(['.git', '.DS_Store', '.build', '.swiftpm', '.svn', '.hg', 'Thumbs.db', 'desktop.ini']);
  static skipIndexDirs = ['node_modules', 'sim_out', '.build', 'build', 'DerivedData', 'obj_dir', 'work'];

  get name() { return this.root ? PathUtil.basename(this.root) : 'No Folder Opened'; }
  changed() { if (this.onChange) this.onChange(); }

  setRoot(p) {
    this.root = p ? PathUtil.resolve(p) : null;
    this.listingCache.clear();
    this.listingDates.clear();
    this.expanded = new Set();
    this.files = [];
    for (const k of [...this.index.keys()]) if (!this.extraFiles.includes(k)) this.index.delete(k);
    this.rebuildModuleTable();
    this.lastFullScan = 0;
    this.changed();
    this.scan();
  }

  children(dir) {
    if (this.listingCache.has(dir)) return this.listingCache.get(dir);
    const items = Workspace.list(dir);
    this.listingCache.set(dir, items);
    const st = Host.fs.stat(dir);
    this.listingDates.set(dir, st ? st.mtime : null);
    return items;
  }
  static list(dir) {
    const out = Host.fs.list(dir).filter((e) => !Workspace.hiddenNames.has(e.name) && !e.name.startsWith('._'))
      .map((e) => ({ path: PathUtil.join(dir, e.name), name: e.name, isDir: e.isDir }));
    const coll = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
    return out.sort((a, b) => (a.isDir !== b.isDir ? (a.isDir ? -1 : 1) : coll.compare(a.name, b.name)));
  }
  refreshListing() {
    this.listingCache.clear();
    this.listingDates.clear();
    this.changed();
    this.scan(true);
  }
  poll() {
    let changed = false;
    for (const [dir, date] of this.listingDates) {
      const st = Host.fs.stat(dir);
      if ((st ? st.mtime : null) !== date) { this.listingCache.delete(dir); this.listingDates.delete(dir); changed = true; }
    }
    if (changed) this.changed();
    this.scan(changed || Date.now() - this.lastFullScan > 15000);
  }
  toggle(p) { if (this.expanded.has(p)) this.expanded.delete(p); else this.expanded.add(p); }
  reveal(p) {
    if (!this.root) return;
    let dir = PathUtil.dirname(p);
    while (Paths.isUnder(dir, this.root)) { this.expanded.add(dir); const up = PathUtil.dirname(dir); if (up === dir) break; dir = up; }
  }
  relativePath(p) {
    if (this.root && Paths.same(p, this.root)) return '';
    if (!this.root || !Paths.isUnder(p, this.root)) return Paths.tilde(p);
    return p.slice(this.root.length + 1);
  }

  // Rebuilds the file list (when needed) and re-indexes changed HDL files, in small slices so the UI stays responsive.
  scan(force = false) {
    if (this.scanning) return;
    this.scanning = true;
    this.indexing = true;
    const needList = force || !this.files.length;
    if (needList) this.lastFullScan = Date.now();
    const all = needList ? (this.root ? Host.fs.walk(this.root, Workspace.skipIndexDirs, 8000) : []) : this.files;
    const hdl = all.filter((p) => HDLLanguage.hdlExtensions.has(Paths.ext(p)));
    for (const e of this.extraFiles) if (!hdl.includes(e)) hdl.push(e);
    const next = new Map();
    let i = 0;
    const step = () => {
      const until = performance.now() + 12;
      while (i < hdl.length && performance.now() < until) {
        const p = hdl[i++];
        const st = Host.fs.stat(p);
        if (!st) continue;
        const prev = this.index.get(p);
        if (prev && prev.mtime === st.mtime) { next.set(p, prev); continue; }
        if (st.size >= 4000000) continue;
        const text = Host.fs.readText(p);
        if (text == null) continue;
        const lang = HDLLanguage.detect(p);
        next.set(p, { mtime: st.mtime, language: lang, symbols: SymbolScanner.scan(text, lang) });
      }
      if (i < hdl.length) { setTimeout(step, 0); return; }
      if (needList) this.files = all;
      for (const [k, v] of this.index) if (v.mtime === Infinity) next.set(k, v);
      let changed = next.size !== this.index.size;
      if (!changed) for (const [k, v] of next) { const o = this.index.get(k); if (!o || o.mtime !== v.mtime) { changed = true; break; } }
      if (changed) { this.index = next; this.rebuildModuleTable(); }
      this.indexing = false;
      this.scanning = false;
      if (changed || needList) this.changed();
    };
    step();
  }

  updateLive(path, language, symbols) {
    this.index.set(path, { mtime: Infinity, language, symbols });
    this.rebuildModuleTable();
  }
  dropLive(path) {
    const e = this.index.get(path);
    if (e && e.mtime === Infinity) { this.index.delete(path); this.scan(); }
  }

  rebuildModuleTable() {
    const t = new Map();
    for (const [path, f] of this.index) {
      for (const s of f.symbols) {
        if (['module', 'interface', 'program', 'entity', 'package', 'klass'].includes(s.kind)) {
          const k = s.name.toLowerCase();
          if (!t.has(k)) t.set(k, []);
          t.get(k).push({ path, symbol: s });
        }
      }
    }
    this.moduleTable = t;
  }
  definitions(name) { return this.moduleTable.get(name.toLowerCase()) || []; }
  get allModules() {
    const coll = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
    return [...this.moduleTable.values()].flat().filter((d) => d.symbol.kind !== 'package' && d.symbol.kind !== 'klass')
      .sort((a, b) => coll.compare(a.symbol.name, b.symbol.name));
  }
  instances(module) {
    const out = [];
    for (const [, f] of this.index) {
      for (const s of f.symbols) {
        if (['module', 'interface', 'program'].includes(s.kind) && s.name === module) out.push(...s.children.filter((c) => c.kind === 'instance'));
        else if (s.kind === 'architecture' && (s.target || '').toLowerCase() === module.toLowerCase()) out.push(...s.children.filter((c) => c.kind === 'instance'));
      }
    }
    return out;
  }
  instanceFile(module) {
    for (const [path, f] of this.index) {
      for (const s of f.symbols) {
        if ((s.kind === 'module' && s.name === module) || (s.kind === 'architecture' && (s.target || '').toLowerCase() === module.toLowerCase())) return path;
      }
    }
    return null;
  }
  // Design hierarchy: top modules (not instantiated anywhere) and their instances.
  hierarchy() {
    const defs = this.allModules.filter((d) => ['module', 'entity', 'program'].includes(d.symbol.kind));
    const instantiated = new Set();
    for (const [, f] of this.index) for (const s of f.symbols) for (const c of s.children) if (c.kind === 'instance' && c.target) instantiated.add(c.target.toLowerCase());
    const seenTop = new Set();
    const tops = [];
    for (const d of defs) {
      const k = d.symbol.name.toLowerCase();
      if (instantiated.has(k) || seenTop.has(k)) continue;
      seenTop.add(k);
      tops.push(this.node(d.symbol.name, null, d.path, d.symbol.line, '', []));
    }
    return tops.sort((a, b) => (a.children.length !== b.children.length ? b.children.length - a.children.length : (a.module < b.module ? -1 : a.module > b.module ? 1 : 0)));
  }
  node(module, instance, file, line, idPrefix, stack) {
    const id = idPrefix + '/' + (instance || module);
    const def = this.definitions(module)[0];
    const n = { id, instance, module, file: instance == null ? (def ? def.path : file) : file, line, children: [], missing: !def, recursive: false };
    if (stack.includes(module.toLowerCase()) || stack.length > 40) { n.recursive = true; return n; }
    const instFile = this.instanceFile(module);
    for (const inst of this.instances(module)) {
      if (!inst.target) continue;
      n.children.push(this.node(inst.target, inst.name, instFile, inst.line, id, [...stack, module.toLowerCase()]));
    }
    return n;
  }
}

// ---------------------------------------------------------------- Find in files

const SearchEngine = {
  textExtensions: new Set([
    'v', 'vh', 'sv', 'svh', 'vhd', 'vhdl', 'vlog', 'txt', 'md', 'tcl', 'xdc', 'sdc', 'ucf', 'pcf', 'lpf', 'qsf',
    'f', 'do', 'py', 'mem', 'hex', 'coe', 'mif', 'json', 'yaml', 'yml', 'sh', 'mk', 'cfg', 'ini', 'toml', 'c', 'h',
    'cpp', 'hpp', 'cc', 'lst', 'ys', 'sby', 'core', 'xml', 'csv', 'bat', 'ps1',
  ]),
  isText(p) {
    const e = Paths.ext(p);
    return SearchEngine.textExtensions.has(e) || (!e && ['Makefile', 'makefile', 'README', 'LICENSE'].includes(PathUtil.basename(p)));
  },
  makeRegex(o) {
    if (!o.query) return null;
    let pattern = o.regex ? o.query : o.query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    if (o.wholeWord) pattern = '\\b' + pattern + '\\b';
    try { return new RegExp(pattern, o.caseSensitive ? 'g' : 'gi'); } catch { return null; }
  },
  matchGlob(glob, path) {
    const esc = glob.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*/g, '\u0000').replace(/\*/g, '[^/\\\\]*').replace(/\?/g, '.').replace(/\u0000/g, '.*');
    if (glob.includes('/')) return new RegExp(esc + '$', 'i').test(path.split('\\').join('/'));
    return new RegExp('^' + esc + '$', 'i').test(PathUtil.basename(path));
  },
  search(opts, files, buffers) {
    const re = SearchEngine.makeRegex(opts);
    if (!re) return [];
    const globs = opts.include.split(',').map((s) => s.trim()).filter(Boolean);
    const out = [];
    let total = 0;
    const paths = files.filter((p) => SearchEngine.isText(p));
    for (const p of buffers.keys()) if (!paths.includes(p) && !p.startsWith('untitled:')) paths.push(p);
    for (const path of paths) {
      if (globs.length && !globs.some((g) => SearchEngine.matchGlob(g, path))) continue;
      let text = buffers.get(path);
      if (text == null) {
        const st = Host.fs.stat(path);
        if (!st || st.size >= 4000000 || Host.fs.isBinary(path)) continue;
        text = Host.fs.readText(path);
        if (text == null) continue;
      }
      re.lastIndex = 0;
      const result = { path, matches: [] };
      let lineNo = 0, lineStart = 0, scanned = 0, m, count = 0;
      while ((m = re.exec(text)) && count < 1000) {
        if (m[0].length === 0) { re.lastIndex++; continue; }
        while (scanned < m.index) { if (text.charCodeAt(scanned) === 10) { lineNo++; lineStart = scanned + 1; } scanned++; }
        let lineEnd = text.indexOf('\n', m.index);
        if (lineEnd < 0) lineEnd = text.length;
        let lineText = text.slice(lineStart, lineEnd).replace(/\r$/, '');
        let start = m.index - lineStart;
        const lead = /^[ \t]*/.exec(lineText)[0].length;
        if (lead > 0) { lineText = lineText.slice(lead); start -= lead; }
        const len = Math.min(m[0].length, Math.max(0, lineText.length - start));
        result.matches.push({ line: lineNo, preview: lineText, start: Math.max(0, start), length: len, offset: m.index, matchLength: m[0].length });
        count++;
      }
      if (!result.matches.length) continue;
      total += result.matches.length;
      out.push(result);
      if (total > 5000) break;
    }
    return out.sort((a, b) => (a.path < b.path ? -1 : 1));
  },
};

if (typeof module !== 'undefined') module.exports = { Workspace, SearchEngine };
