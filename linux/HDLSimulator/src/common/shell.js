'use strict';
/* global Paths, store */
// State shared by the Coder and the Tester: which tab is showing and the descend/ascend stack.
// Port of HDLShell/Shell.swift. Each tab registers its handlers at start.

const Shell = {
  tab: 'coder',
  stack: [],              // NavFrame: { place: { kind: 'test', id, instance } | { kind: 'file', path, offset }, label, child }
  openInCoder: null,      // (path, line, module)
  revealInCoder: null,    // (path, offset)
  showTest: null,         // (testId, instanceId) => bool
  testbench: null,        // (path, module) => NavFrame | null
  generateTestbench: null,// (path, module)
  openInTester: null,     // (paths)
  tabChanged: null,

  show(t) {
    if (this.tab === t) return;
    this.tab = t;
    if (this.tabChanged) this.tabChanged(t);
  },
  frameEq(a, b) {
    if (a.label !== b.label || a.child !== b.child || a.place.kind !== b.place.kind) return false;
    return a.place.kind === 'test' ? a.place.id === b.place.id && a.place.instance === b.place.instance
      : a.place.path === b.place.path && a.place.offset === b.place.offset;
  },
  descend(frame, path, line = null, module = null) {
    this.stack = this.stack.filter((f) => !this.frameEq(f, frame));
    this.stack.push(frame);
    if (this.stack.length > 64) this.stack.splice(0, this.stack.length - 64);
    this.show('coder');
    if (this.openInCoder) this.openInCoder(path, line, module);
  },
  parent(path, module) {
    for (let i = this.stack.length - 1; i >= 0; i--) if (Paths.same(this.stack[i].child, path)) return this.stack[i];
    return this.testbench ? this.testbench(path, module) : null;
  },
  ascend(path, module) {
    const f = this.parent(path, module);
    if (!f) return false;
    const i = this.stack.findIndex((x) => this.frameEq(x, f));
    if (i >= 0) this.stack.splice(i);
    return this.go(f);
  },
  go(f) {
    if (f.place.kind === 'test') {
      if (!(this.showTest && this.showTest(f.place.id, f.place.instance))) return false;
      this.show('tester');
    } else {
      this.show('coder');
      if (this.revealInCoder) this.revealInCoder(f.place.path, f.place.offset);
    }
    return true;
  },
};

if (typeof module !== 'undefined') module.exports = { Shell };
