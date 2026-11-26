'use strict';
/* global VerilogParser, PathUtil, Host */
// The Verilog files opened in the Tester; their modules are the available DUTs. Port of Library.swift.

class Library {
  constructor() {
    this.files = [];             // { path, modules, errors, mtime }
    this.collapsedFiles = new Set();
    this.expandedModules = new Set();
  }
  static extensions = new Set(['v', 'sv', 'vh', 'svh', 'verilog', 'vlg']);

  get modules() { return this.files.flatMap((f) => f.modules); }
  module(name, preferFile) {
    const all = this.modules.filter((m) => m.name === name);
    return all.find((m) => preferFile != null && Library.samePath(m.file, preferFile)) || all[0] || null;
  }
  static relativePath(path, dir) {
    return PathUtil.relative(dir, path).split(PathUtil.sep).join('/');
  }
  static samePath(a, b) {
    if (a === b) return true;
    const norm = (p) => { const r = Host.fs.realpath(p) || PathUtil.resolve(p); return Host.platform === 'win32' ? r.toLowerCase() : r; };
    return norm(a) === norm(b);
  }
  static isVerilog(p) { return Library.extensions.has(PathUtil.extname(p).slice(1).toLowerCase()); }

  add(paths) {
    const added = [];
    for (const raw of paths) {
      const p = PathUtil.resolve(raw);
      const st = Host.fs.stat(p);
      if (!st) continue;
      if (st.isDir) { added.push(...this.add(Library.verilogFiles(p))); continue; }
      if (!Library.isVerilog(p)) continue;
      const f = Library.load(p);
      const i = this.files.findIndex((x) => x.path === p);
      if (i >= 0) this.files[i] = f; else this.files.push(f);
      added.push(f);
    }
    return added;
  }
  static verilogFiles(dir) {
    const out = [];
    const walk = (d, level) => {
      for (const e of Host.fs.list(d)) {
        if (e.name.startsWith('.')) continue;
        const p = PathUtil.join(d, e.name);
        if (e.isDir) { if (level < 3) walk(p, level + 1); }
        else if (Library.isVerilog(p)) out.push(p);
        if (out.length > 500) return;
      }
    };
    walk(dir, 0);
    return out.sort();
  }
  static load(path) {
    const text = Host.fs.readText(path);
    const st = Host.fs.stat(path);
    if (text == null) return { path, modules: [], errors: [`Could not read ${PathUtil.basename(path)}`], mtime: st ? st.mtime : null };
    const r = VerilogParser.parse(text, path, (p) => Host.fs.readText(p));
    const errors = r.errors.slice();
    if (!r.modules.length && !errors.length) errors.push('No modules found');
    return { path, modules: r.modules, errors, mtime: st ? st.mtime : null };
  }
  remove(file) { this.files = this.files.filter((f) => f.path !== file.path); }
  reload(file) { const i = this.files.findIndex((f) => f.path === file.path); if (i >= 0) this.files[i] = Library.load(file.path); }
  checkForChanges(settled = false) {
    const changed = [];
    this.files.forEach((f, i) => {
      const st = Host.fs.stat(f.path);
      const d = st ? st.mtime : null;
      if (d !== f.mtime) {
        if (!settled && d != null && Date.now() - d < 300) return;
        this.files[i] = d == null ? { path: f.path, modules: [], errors: ['File not found'], mtime: null } : Library.load(f.path);
        changed.push(this.files[i]);
      }
    });
    return changed;
  }
}

if (typeof module !== 'undefined') module.exports = { Library };
