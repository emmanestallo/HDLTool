'use strict';
/* global Lexer */
// Outline of a file built from its tokens. Port of Symbols.swift.
// Symbol: { kind, name, detail, line, endLine, offset, children, dir, range, dataType, value, target }

const SymbolKinds = {
  icon(k) {
    return {
      module: 'symbol-class', entity: 'symbol-class', architecture: 'layers', package: 'package',
      interface: 'symbol-interface', program: 'symbol-class', klass: 'symbol-class', component: 'extensions',
      port: 'arrow-swap', param: 'symbol-constant', constant: 'symbol-constant', signal: 'symbol-field',
      instance: 'symbol-module', process: 'sync', function: 'symbol-method', task: 'checklist',
      type: 'symbol-type-parameter', block: 'symbol-namespace',
    }[k] || 'symbol-misc';
  },
  isContainer(k) { return ['module', 'entity', 'architecture', 'package', 'interface', 'program', 'klass'].includes(k); },
  label(k) { return k === 'klass' ? 'class' : k; },
};

function mkSym(kind, name, fields) {
  return Object.assign({ kind, name, detail: '', line: 0, endLine: 0, offset: 0, children: [], dir: null, range: null, dataType: null, value: null, target: null }, fields);
}
const symPorts = (s) => s.children.filter((c) => c.kind === 'port');
const symParams = (s) => s.children.filter((c) => c.kind === 'param' && c.dir !== 'local');
function flattenSymbols(list) { const out = []; (function f(l) { for (const s of l) { out.push(s); f(s.children); } })(list); return out; }
function symbolPathAt(list, line) {
  const s = list.find((x) => x.line <= line && line <= x.endLine &&
    (SymbolKinds.isContainer(x.kind) || ['process', 'function', 'task', 'instance'].includes(x.kind)));
  return s ? [s, ...symbolPathAt(s.children, line)] : [];
}
const symbolId = (s) => `${s.kind}:${s.name}:${s.line}:${s.offset}`;

const SymbolScanner = (() => {
  const containerEnds = {
    module: 'endmodule', macromodule: 'endmodule', interface: 'endinterface', program: 'endprogram',
    package: 'endpackage', class: 'endclass', checker: 'endchecker', primitive: 'endprimitive',
  };
  const containerEndValues = new Set(Object.values(containerEnds));
  const netTypes = new Set([
    'wire', 'reg', 'logic', 'bit', 'byte', 'int', 'integer', 'shortint', 'longint', 'real', 'realtime',
    'shortreal', 'time', 'string', 'tri', 'tri0', 'tri1', 'triand', 'trior', 'trireg', 'wand', 'wor',
    'supply0', 'supply1', 'uwire', 'genvar', 'event', 'chandle', 'var',
  ]);
  const hasEnd = (w) => Object.prototype.hasOwnProperty.call(containerEnds, w);

  function scan(text, language, tokens) {
    if (language === 'plain') return [];
    const toks = (tokens || Lexer.lex(text, language)).filter((t) => t.kind !== 'comment' && t.kind !== 'attribute');
    const S = new Scanner(text, toks, language === 'vhdl');
    return S.vhdl ? S.scanVHDL() : S.scanVerilog();
  }

  class Scanner {
    constructor(u, toks, vhdl) { this.u = u; this.toks = toks; this.vhdl = vhdl; this.i = 0; }
    text(t) { return this.u.slice(t.start, t.end); }
    word(k) {
      if (k < 0 || k >= this.toks.length) return '';
      const t = this.toks[k];
      if (t.kind === 'op' || t.kind === 'string' || t.kind === 'number') return '';
      return this.vhdl ? this.text(t).toLowerCase() : this.text(t);
    }
    isOp(k, ch) { return k >= 0 && k < this.toks.length && this.toks[k].kind === 'op' && this.u[this.toks[k].start] === ch; }
    isName(k) {
      if (k < 0 || k >= this.toks.length) return false;
      const kd = this.toks[k].kind;
      return kd === 'ident' || kd === 'typeName' || kd === 'funcName';
    }
    source(a, b) {
      const toks = this.toks;
      if (a >= toks.length || a > b || a < 0) return '';
      const s = toks[a].start, e = toks[Math.min(b, toks.length - 1)].end;
      return this.u.slice(s, e).split(/[ \n\t\r]+/).filter(Boolean).join(' ');
    }
    matching(k) {
      const toks = this.toks, u = this.u;
      if (k >= toks.length) return toks.length;
      const open = u[toks[k].start];
      const close = open === '(' ? ')' : (open === '[' ? ']' : '}');
      let depth = 0;
      for (let j = k; j < toks.length; j++) {
        if (toks[j].kind === 'op') {
          const c = u[toks[j].start];
          if (c === open) depth++;
          else if (c === close) { depth--; if (depth === 0) return j; }
        }
      }
      return toks.length - 1;
    }
    findTopLevel(from, chars, limit) {
      const toks = this.toks, u = this.u;
      let depth = 0;
      const end = limit == null ? toks.length : limit;
      for (let j = from; j < end; j++) {
        if (toks[j].kind === 'op') {
          const c = u[toks[j].start];
          if (depth === 0 && chars.includes(c)) return j;
          if (c === '(' || c === '[' || c === '{') depth++;
          if (c === ')' || c === ']' || c === '}') depth = Math.max(0, depth - 1);
        }
      }
      return end;
    }

    // ---------- Verilog
    scanVerilog() {
      const out = [];
      while (this.i < this.toks.length) {
        const w = this.word(this.i);
        if (hasEnd(w) && !(w === 'class' && this.word(this.i - 1) === 'typedef') && !(w === 'interface' && this.word(this.i - 1) === 'virtual')) {
          const s = this.parseContainer(w, containerEnds[w]);
          if (s) out.push(s);
        } else this.i++;
      }
      return out;
    }
    kindFor(w) { return { interface: 'interface', program: 'program', package: 'package', class: 'klass' }[w] || 'module'; }

    parseContainer(w, endWord) {
      const toks = this.toks;
      const startLine = toks[this.i].line;
      this.i++;
      while (['static', 'automatic', 'virtual'].includes(this.word(this.i))) this.i++;
      if (!this.isName(this.i)) return null;
      const sym = mkSym(this.kindFor(w), this.text(toks[this.i]), { line: startLine, endLine: startLine, offset: toks[this.i].start });
      this.i++;
      let ports = [], params = [];
      while (this.i < toks.length && !this.isOp(this.i, ';')) {
        if (this.isOp(this.i, '#') && this.isOp(this.i + 1, '(')) {
          const close = this.matching(this.i + 1);
          params = params.concat(this.parseParamList(this.i + 2, close));
          this.i = close + 1;
        } else if (this.isOp(this.i, '(')) {
          const close = this.matching(this.i);
          ports = ports.concat(this.parsePortList(this.i + 1, close));
          this.i = close + 1;
        } else if (this.word(this.i) === endWord) break;
        else this.i++;
      }
      if (this.isOp(this.i, ';')) this.i++;

      let body = [];
      let depth = 0;
      while (this.i < toks.length) {
        const i = this.i;
        const w2 = this.word(i);
        if (w2 === endWord && depth === 0) {
          sym.endLine = toks[i].line;
          this.i++;
          if (this.isOp(this.i, ':') && this.isName(this.i + 1)) this.i += 2;
          break;
        }
        if (toks[i].kind === 'op') {
          const c = this.u[toks[i].start];
          if (c === '(' || c === '[' || c === '{') depth++;
          else if (c === ')' || c === ']' || c === '}') depth = Math.max(0, depth - 1);
          this.i++;
          continue;
        }
        if (depth > 0) { this.i++; continue; }
        if (hasEnd(w2) && !(w2 === 'class' && this.word(i - 1) === 'typedef') && !(w2 === 'interface' && this.word(i - 1) === 'virtual')) {
          const s = this.parseContainer(w2, containerEnds[w2]);
          if (s) body.push(s);
          continue;
        }
        switch (w2) {
          case 'input': case 'output': case 'inout': case 'ref': {
            const end = this.findTopLevel(i, [';']);
            for (const d of this.parseDecl(i, end, w2)) {
              const k = ports.findIndex((p) => p.name === d.name);
              if (k >= 0) Object.assign(ports[k], { dir: d.dir, range: d.range, dataType: d.dataType, detail: d.detail, line: d.line, endLine: d.endLine, offset: d.offset });
              else ports.push(d);
            }
            this.i = end + 1;
            break;
          }
          case 'parameter': case 'localparam': {
            const end = this.findTopLevel(i, [';']);
            params = params.concat(this.parseParamList(i, end).map((p) => {
              if (w2 === 'localparam') { p.dir = 'local'; p.detail = 'localparam' + (p.value != null ? ` = ${p.value}` : ''); }
              return p;
            }));
            this.i = end + 1;
            break;
          }
          case 'typedef': {
            const end = this.findTopLevel(i, [';']);
            let k = end - 1;
            while (k > i && !this.isName(k)) k--;
            if (k > i) {
              body.push(mkSym('type', this.text(toks[k]), { detail: this.word(i + 1), line: toks[i].line, endLine: toks[end < toks.length ? end : k].line, offset: toks[k].start }));
            }
            this.i = end + 1;
            break;
          }
          case 'function': case 'task': body.push(this.parseRoutine(w2)); break;
          case 'always': case 'always_ff': case 'always_comb': case 'always_latch': case 'initial': case 'final':
            body.push(this.parseProcess(w2)); break;
          case 'assign': case 'defparam': case 'import': case 'export': case 'bind': case 'alias':
            this.i = this.findTopLevel(i, [';']) + 1; break;
          case 'constraint': case 'covergroup': case 'property': case 'sequence': case 'clocking': case 'specify': case 'config': {
            const ends = { covergroup: 'endgroup', property: 'endproperty', sequence: 'endsequence', clocking: 'endclocking', specify: 'endspecify', config: 'endconfig' };
            if (w2 === 'constraint') {
              while (this.i < toks.length && !this.isOp(this.i, '{')) this.i++;
              this.i = this.matching(this.i) + 1;
            } else {
              const e = ends[w2];
              while (this.i < toks.length && this.word(this.i) !== e && this.word(this.i) !== endWord) this.i++;
              if (this.word(this.i) === e) this.i++;
            }
            break;
          }
          default:
            if (netTypes.has(w2) || w2 === 'signed' || w2 === 'unsigned') {
              if (this.word(i - 1) === 'typedef' || this.isOp(i - 1, '(')) { this.i++; break; }
              const end = this.findTopLevel(i, [';']);
              body = body.concat(this.parseDecl(i, end, null));
              this.i = end + 1;
            } else if ((toks[i].kind === 'ident' || toks[i].kind === 'typeName') && !this.isOp(i - 1, '.') && !(i > 0 && this.isOp(i - 1, ':') && this.isOp(i - 2, ':'))) {
              const inst = this.tryInstance();
              if (inst) body = body.concat(inst);
              else if (this.isName(i + 1) && (this.isOp(i + 2, ';') || this.isOp(i + 2, ',') || this.isOp(i + 2, '=') ||
                  (this.isOp(i + 2, '[') && !this.isOp(this.findTopLevel(i + 2, [';', '(']), '(')))) {
                const end = this.findTopLevel(i, [';']);
                body = body.concat(this.parseDecl(i, end, null));
                this.i = end + 1;
              } else this.i++;
            } else this.i++;
        }
      }
      if (sym.endLine < sym.line) sym.endLine = toks.length ? toks[toks.length - 1].line : sym.line;
      sym.children = [...ports, ...params, ...body];
      return sym;
    }

    tryInstance() {
      const toks = this.toks;
      const modTok = this.i;
      let k = this.i + 1;
      let paramText = null;
      if (this.isOp(k, '#')) {
        if (this.isOp(k + 1, '(')) {
          const close = this.matching(k + 1);
          paramText = this.source(k + 2, close - 1);
          k = close + 1;
        } else k += 2;
      }
      if (!this.isName(k)) return null;
      let j = k + 1;
      if (this.isOp(j, '[')) j = this.matching(j) + 1;
      if (!this.isOp(j, '(')) return null;
      const out = [];
      const module = this.text(toks[modTok]);
      for (;;) {
        if (!this.isName(k)) break;
        let j2 = k + 1;
        if (this.isOp(j2, '[')) j2 = this.matching(j2) + 1;
        if (!this.isOp(j2, '(')) break;
        const close = this.matching(j2);
        const s = mkSym('instance', this.text(toks[k]), { detail: module, line: toks[modTok].line, endLine: toks[close].line, offset: toks[k].start, target: module, value: paramText });
        let c = j2 + 1;
        while (c < close) {
          if (this.isOp(c, '.') && this.isName(c + 1)) {
            const p = mkSym('port', this.text(toks[c + 1]), { line: toks[c + 1].line, endLine: toks[c + 1].line, offset: toks[c + 1].start });
            if (this.isOp(c + 2, '(')) {
              const pc = this.matching(c + 2);
              p.detail = this.source(c + 3, pc - 1);
              c = pc;
            }
            s.children.push(p);
          }
          c++;
        }
        out.push(s);
        k = close + 1;
        if (this.isOp(k, ',')) { k++; continue; }
        break;
      }
      if (!out.length) return null;
      this.i = this.findTopLevel(k, [';']) + 1;
      return out;
    }

    parseDecl(a, b, dirWord) {
      const toks = this.toks;
      const out = [];
      let k = a, dir = dirWord, types = [], range = '';
      if (dirWord != null) k++;
      while (k < b) {
        if (this.isOp(k, '[')) { const c = this.matching(k); range += this.source(k, c); k = c + 1; continue; }
        if (this.isOp(k, '=')) { k = this.findTopLevel(k, [','], b); continue; }
        if (this.isOp(k, ',')) { k++; continue; }
        const w = this.word(k);
        if (['input', 'output', 'inout', 'ref'].includes(w)) { dir = w; types = []; range = ''; k++; continue; }
        if (netTypes.has(w) || ['signed', 'unsigned', 'const', 'static', 'automatic', 'var'].includes(w)) { types.push(w); k++; continue; }
        if (this.isName(k)) {
          if (this.isName(k + 1) || (this.isOp(k + 1, ':') && this.isOp(k + 2, ':')) || this.isOp(k + 1, '.')) {
            if (this.isOp(k + 1, ':')) { types.push(this.source(k, k + 3)); k += 4; continue; }
            if (this.isOp(k + 1, '.') && this.isName(k + 2)) { types.push(this.source(k, k + 2)); k += 3; continue; }
            types.push(this.text(toks[k])); k++; continue;
          }
          const name = this.text(toks[k]);
          let unpacked = '', e = k + 1;
          while (this.isOp(e, '[')) { const c = this.matching(e); unpacked += this.source(e, c); e = c + 1; }
          const typeStr = types.join(' ');
          let detail = [dir || '', typeStr, range].filter(Boolean).join(' ');
          if (unpacked) detail += ' ' + unpacked;
          out.push(mkSym(dir == null ? 'signal' : 'port', name, {
            detail, line: toks[k].line, endLine: toks[k].line, offset: toks[k].start,
            dir: dir || null, range: range || null, dataType: typeStr || null,
          }));
          k = e;
          continue;
        }
        k++;
      }
      return out;
    }

    parseParamList(a, b) {
      const toks = this.toks;
      const out = [];
      let k = a, local = false;
      while (k < b) {
        const itemEnd = this.findTopLevel(k, [','], b);
        const eq = this.findTopLevel(k, ['='], itemEnd);
        let n = (eq < itemEnd ? eq : itemEnd) - 1;
        while (n >= k && this.isOp(n, ']')) {
          let depth = 0;
          while (n >= k) {
            if (this.isOp(n, ']')) depth++;
            else if (this.isOp(n, '[')) { depth--; if (depth === 0) break; }
            n--;
          }
          n--;
        }
        if (this.word(k) === 'localparam') local = true; else if (this.word(k) === 'parameter') local = false;
        if (n >= k && this.isName(n)) {
          const p = mkSym('param', this.text(toks[n]), { line: toks[n].line, endLine: toks[n].line, offset: toks[n].start });
          if (eq < itemEnd) { p.value = this.source(eq + 1, itemEnd - 1); p.detail = '= ' + p.value; }
          let r = '', t = k;
          while (t < n) { if (this.isOp(t, '[')) { const c = this.matching(t); r += this.source(t, c); t = c + 1; } else t++; }
          p.range = r || null;
          if (local) { p.dir = 'local'; p.detail = 'localparam ' + p.detail; }
          out.push(p);
        }
        k = itemEnd + 1;
      }
      return out;
    }

    parsePortList(a, b) {
      const out = [];
      let k = a, dir = null, types = '', range = '';
      while (k < b) {
        const itemEnd = this.findTopLevel(k, [','], b);
        const decl = this.parseDecl(k, itemEnd, null);
        let hasOwnType = false;
        for (let t = k; t < itemEnd; t++) {
          const w = this.word(t);
          if (['input', 'output', 'inout', 'ref'].includes(w)) { dir = w; hasOwnType = true; }
          if (netTypes.has(w) || this.isOp(t, '[') || (this.isName(t) && this.isName(t + 1)) || (this.isName(t) && this.isOp(t + 1, '.'))) hasOwnType = true;
          if (this.isOp(t, '[')) t = this.matching(t);
        }
        const p = decl[decl.length - 1];
        if (p) {
          if (hasOwnType) { types = p.dataType || ''; range = p.range || ''; }
          else { p.dataType = types || null; p.range = range || null; }
          p.kind = 'port';
          p.dir = dir;
          p.detail = [dir || '', p.dataType || '', p.range || ''].filter(Boolean).join(' ');
          out.push(p);
        }
        k = itemEnd + 1;
      }
      return out;
    }

    parseRoutine(w) {
      const toks = this.toks;
      const start = toks[this.i];
      const endWord = w === 'function' ? 'endfunction' : 'endtask';
      let back = this.i - 1, proto = false;
      while (back >= 0 && !this.isOp(back, ';') && toks[this.i].line - toks[back].line < 2) {
        if (['extern', 'pure', 'import', 'export'].includes(this.word(back))) proto = true;
        back--;
      }
      const headerEnd = this.findTopLevel(this.i, [';']);
      let nameIdx = this.i + 1, k = this.i + 1;
      while (k < headerEnd) {
        if (this.isOp(k, '(')) break;
        if (this.isName(k)) nameIdx = k;
        if (this.isOp(k, '[')) k = this.matching(k);
        k++;
      }
      const name = nameIdx < toks.length ? this.text(toks[nameIdx]) : w;
      const s = mkSym(w === 'function' ? 'function' : 'task', name, { line: start.line, endLine: start.line, offset: nameIdx < toks.length ? toks[nameIdx].start : start.start });
      if (nameIdx < toks.length && this.isOp(nameIdx + 1, '(')) {
        const c = this.matching(nameIdx + 1);
        s.detail = '(' + this.source(nameIdx + 2, c - 1) + ')';
      }
      if (proto) { this.i = headerEnd + 1; return s; }
      k = headerEnd;
      while (k < toks.length && this.word(k) !== endWord && !containerEndValues.has(this.word(k))) k++;
      s.endLine = k < toks.length ? toks[k].line : (toks.length ? toks[toks.length - 1].line : s.line);
      this.i = (k < toks.length && this.word(k) === endWord) ? k + 1 : k;
      if (this.isOp(this.i, ':') && this.isName(this.i + 1)) this.i += 2;
      return s;
    }

    parseProcess(w) {
      const toks = this.toks;
      const start = toks[this.i];
      let k = this.i + 1, detail = w;
      if (this.isOp(k, '@')) {
        if (this.isOp(k + 1, '(')) {
          const c = this.matching(k + 1);
          detail += ' @(' + this.source(k + 2, c - 1) + ')';
          k = c + 1;
        } else {
          detail += ' @' + (k + 1 < toks.length ? this.text(toks[k + 1]) : '');
          k += 2;
        }
      }
      let name = detail, endLine = start.line;
      if (this.word(k) === 'begin') {
        if (this.isOp(k + 1, ':') && this.isName(k + 2)) name = this.text(toks[k + 2]);
        let depth = 0, j = k;
        while (j < toks.length) {
          const wj = this.word(j);
          if (['begin', 'fork', 'case', 'casez', 'casex', 'randcase'].includes(wj)) depth++;
          else if (['end', 'join', 'join_any', 'join_none', 'endcase'].includes(wj)) { depth--; if (depth === 0) break; }
          else if (containerEndValues.has(wj)) { j--; break; }
          j++;
        }
        j = Math.min(j, toks.length - 1);
        endLine = toks[j].line;
        this.i = j + 1;
      } else {
        const e = this.findTopLevel(k, [';']);
        endLine = e < toks.length ? toks[e].line : start.line;
        this.i = e + 1;
      }
      return mkSym('process', name, { detail: name === detail ? '' : detail, line: start.line, endLine, offset: start.start, dataType: w });
    }

    // ---------- VHDL
    scanVHDL() {
      const out = [];
      const toks = this.toks;
      while (this.i < toks.length) {
        const w = this.word(this.i);
        if (w === 'entity' && this.isName(this.i + 1) && this.word(this.i + 2) === 'is') out.push(this.parseEntity());
        else if (w === 'architecture' && this.isName(this.i + 1) && this.word(this.i + 2) === 'of') out.push(this.parseArchitecture());
        else if (w === 'package') out.push(this.parsePackage());
        else this.i++;
      }
      for (let k = 0; k < out.length; k++) {
        if (out[k].endLine < out[k].line) {
          out[k].endLine = k + 1 < out.length ? Math.max(out[k].line, out[k + 1].line - 1) : (toks.length ? toks[toks.length - 1].line : out[k].line);
        }
      }
      return out;
    }

    isDesignUnitStart(k) {
      const w = this.word(k);
      if (w === 'entity' && this.isName(k + 1) && this.word(k + 2) === 'is') return true;
      if (w === 'architecture' && this.isName(k + 1) && this.word(k + 2) === 'of') return true;
      if (w === 'package' && (this.word(k + 1) === 'body' || this.word(k + 2) === 'is') && !this.isOp(k - 1, ':')) return true;
      if (w === 'configuration' && this.word(k + 2) === 'of') return true;
      if ((w === 'library' || w === 'context') && (k === 0 || this.isOp(k - 1, ';'))) return true;
      return false;
    }

    parseEntity() {
      const toks = this.toks;
      const start = toks[this.i];
      const s = mkSym('entity', this.text(toks[this.i + 1]), { line: start.line, endLine: -1, offset: toks[this.i + 1].start });
      this.i += 3;
      while (this.i < toks.length) {
        const w = this.word(this.i);
        if ((w === 'generic' || w === 'port') && this.isOp(this.i + 1, '(')) {
          const close = this.matching(this.i + 1);
          s.children = s.children.concat(this.parseVHDLInterface(this.i + 2, close, w === 'port'));
          this.i = close + 1;
          continue;
        }
        if (w === 'end') { s.endLine = toks[this.i].line; this.i = this.findTopLevel(this.i, [';']) + 1; break; }
        if (this.isDesignUnitStart(this.i)) break;
        this.i++;
      }
      return s;
    }

    parseVHDLInterface(a, b, port) {
      const toks = this.toks;
      const out = [];
      let k = a;
      while (k < b) {
        const itemEnd = this.findTopLevel(k, [';'], b);
        const colon = this.findTopLevel(k, [':'], itemEnd);
        if (colon < itemEnd) {
          const names = [];
          for (let t = k; t < colon; t++) if (this.isName(t)) names.push(t);
          let typeStart = colon + 1, dir = null;
          if (['in', 'out', 'inout', 'buffer', 'linkage'].includes(this.word(typeStart))) { dir = this.word(typeStart); typeStart++; }
          let assign = itemEnd;
          for (let q = typeStart; q < itemEnd; q++) if (this.isOp(q, ':') && this.isOp(q + 1, '=')) { assign = q; break; }
          const typeText = this.source(typeStart, assign - 1);
          const value = assign < itemEnd ? this.source(assign + 2, itemEnd - 1) : null;
          for (const nk of names) {
            const s = mkSym(port ? 'port' : 'param', this.text(toks[nk]), { line: toks[nk].line, endLine: toks[nk].line, offset: toks[nk].start });
            s.dir = port ? (dir || 'in') : null;
            s.dataType = typeText;
            s.value = value;
            s.detail = port ? `${s.dir} ${typeText}` : typeText + (value != null ? ` := ${value}` : '');
            out.push(s);
          }
        }
        k = itemEnd + 1;
      }
      return out;
    }

    parseArchitecture() {
      const toks = this.toks;
      const start = toks[this.i];
      const arch = this.text(toks[this.i + 1]);
      const ent = this.isName(this.i + 3) ? this.text(toks[this.i + 3]) : '?';
      const s = mkSym('architecture', arch, { detail: `of ${ent}`, line: start.line, endLine: -1, offset: toks[this.i + 1].start, target: ent });
      this.i += 4;
      const box = { v: s.endLine };
      s.children = this.parseVHDLBody(box);
      s.endLine = box.v;
      return s;
    }

    parsePackage() {
      const toks = this.toks;
      const start = toks[this.i];
      const isBody = this.word(this.i + 1) === 'body';
      const nameIdx = isBody ? this.i + 2 : this.i + 1;
      const name = this.isName(nameIdx) ? this.text(toks[nameIdx]) : 'package';
      const s = mkSym('package', name, { detail: isBody ? 'body' : '', line: start.line, endLine: -1, offset: nameIdx < toks.length ? toks[nameIdx].start : start.start });
      this.i = nameIdx + 1;
      const box = { v: s.endLine };
      s.children = this.parseVHDLBody(box);
      s.endLine = box.v;
      return s;
    }

    parseVHDLBody(lastEnd) {
      const toks = this.toks;
      const out = [];
      while (this.i < toks.length) {
        if (this.isDesignUnitStart(this.i)) break;
        const i = this.i;
        const w = this.word(i);
        switch (w) {
          case 'end': lastEnd.v = toks[i].line; this.i++; break;
          case 'signal': case 'constant': case 'shared': case 'variable': case 'file': {
            if (w === 'variable' || w === 'file' || w === 'shared') { this.i = this.findTopLevel(i, [';']) + 1; break; }
            const end = this.findTopLevel(i, [';']);
            const colon = this.findTopLevel(i, [':'], end);
            if (colon < end) {
              let assign = end;
              for (let q = colon + 1; q < end; q++) if (this.isOp(q, ':') && this.isOp(q + 1, '=')) { assign = q; break; }
              const typeText = this.source(colon + 1, assign - 1);
              const value = assign < end ? this.source(assign + 2, end - 1) : null;
              for (let nk = i + 1; nk < colon; nk++) {
                if (!this.isName(nk)) continue;
                out.push(mkSym(w === 'signal' ? 'signal' : 'constant', this.text(toks[nk]), {
                  detail: typeText + (value != null ? ` := ${value}` : ''), line: toks[nk].line, endLine: toks[nk].line, offset: toks[nk].start, dataType: typeText, value,
                }));
              }
            }
            this.i = end + 1;
            break;
          }
          case 'type': case 'subtype':
            if (this.isName(i + 1)) {
              const end = this.findTopLevel(i, [';']);
              out.push(mkSym('type', this.text(toks[i + 1]), { detail: this.source(i + 2, Math.min(end - 1, i + 6)), line: toks[i].line, endLine: end < toks.length ? toks[end].line : toks[i].line, offset: toks[i + 1].start }));
              if (this.word(i + 3) === 'record' || this.word(i + 3) === 'protected') {
                let k = i + 3;
                while (k < toks.length && !(this.word(k) === 'end' && (this.word(k + 1) === 'record' || this.word(k + 1) === 'protected'))) k++;
                this.i = this.findTopLevel(k, [';']) + 1;
              } else this.i = end + 1;
            } else this.i++;
            break;
          case 'component': {
            if (!this.isName(i + 1)) { this.i++; break; }
            const c = mkSym('component', this.text(toks[i + 1]), { line: toks[i].line, endLine: toks[i].line, offset: toks[i + 1].start });
            let k = i + 2;
            while (k < toks.length && !(this.word(k) === 'end' && this.word(k + 1) === 'component')) {
              if ((this.word(k) === 'port' || this.word(k) === 'generic') && this.isOp(k + 1, '(')) {
                const close = this.matching(k + 1);
                c.children = c.children.concat(this.parseVHDLInterface(k + 2, close, this.word(k) === 'port'));
                k = close;
              }
              k++;
            }
            c.endLine = k < toks.length ? toks[k].line : c.line;
            out.push(c);
            this.i = this.findTopLevel(k, [';']) + 1;
            break;
          }
          case 'function': case 'procedure': case 'impure': case 'pure': {
            let k = i;
            if (w === 'impure' || w === 'pure') k++;
            if (!this.isName(k + 1)) { this.i++; break; }
            const f = mkSym('function', this.text(toks[k + 1]), { detail: this.word(k), line: toks[i].line, endLine: toks[i].line, offset: toks[k + 1].start });
            let j = k + 2;
            if (this.isOp(j, '(')) { const c = this.matching(j); f.detail = this.word(k) + '(' + this.source(j + 1, c - 1) + ')'; j = c + 1; }
            while (j < toks.length && !this.isOp(j, ';') && this.word(j) !== 'is') j++;
            if (this.word(j) === 'is') {
              let depth = 0, e = j + 1;
              while (e < toks.length) {
                const we = this.word(e);
                if (we === 'begin') depth++;
                if (we === 'end') {
                  const n1 = this.word(e + 1);
                  if (n1 === 'function' || n1 === 'procedure' || n1 === f.name.toLowerCase() || (this.isOp(e + 1, ';') && depth <= 1)) break;
                  if (!['if', 'loop', 'case', 'record'].includes(n1)) depth = Math.max(0, depth - 1);
                }
                if (this.isDesignUnitStart(e)) { e--; break; }
                e++;
              }
              f.endLine = e < toks.length ? toks[e].line : f.line;
              this.i = this.findTopLevel(e, [';']) + 1;
            } else this.i = j + 1;
            out.push(f);
            break;
          }
          case 'process': out.push(this.parseVHDLProcess(null, i)); break;
          default: {
            if (this.isName(i) && this.isOp(i + 1, ':') && !this.isOp(i + 2, '=')) {
              const label = this.text(toks[i]);
              const w2 = this.word(i + 2);
              if (w2 === 'process' || (w2 === 'postponed' && this.word(i + 3) === 'process')) {
                out.push(this.parseVHDLProcess(label, w2 === 'process' ? i + 2 : i + 3));
                break;
              }
              if (w2 === 'entity') {
                let k = i + 3, target = '';
                while (k < toks.length && !this.isOp(k, ';') && this.word(k) !== 'port' && this.word(k) !== 'generic') {
                  if (this.isName(k)) target = this.text(toks[k]);
                  if (this.isOp(k, '(')) break;
                  k++;
                }
                out.push(this.vhdlInstance(label, i, target));
                break;
              }
              if (w2 === 'component' && this.isName(i + 3)) { out.push(this.vhdlInstance(label, i, this.text(toks[i + 3]))); break; }
              if (this.isName(i + 2) && (this.word(i + 3) === 'port' || this.word(i + 3) === 'generic')) { out.push(this.vhdlInstance(label, i, this.text(toks[i + 2]))); break; }
              if (w2 === 'for' || w2 === 'if' || w2 === 'case' || w2 === 'block') { this.i += 3; break; }
            }
            this.i++;
          }
        }
      }
      return out;
    }

    vhdlInstance(label, labelIdx, target) {
      const toks = this.toks;
      const s = mkSym('instance', label, { detail: target, line: toks[labelIdx].line, endLine: toks[labelIdx].line, offset: toks[labelIdx].start, target });
      let k = labelIdx + 2;
      const end = this.findTopLevel(k, [';']);
      while (k < end) {
        if (this.word(k) === 'map' && this.isOp(k + 1, '(')) {
          const close = this.matching(k + 1);
          if (this.word(k - 1) === 'port') {
            let c = k + 2;
            while (c < close) {
              if (this.isName(c) && this.isOp(c + 1, '=') && this.isOp(c + 2, '>')) {
                const itemEnd = this.findTopLevel(c, [','], close);
                s.children.push(mkSym('port', this.text(toks[c]), { detail: this.source(c + 3, itemEnd - 1), line: toks[c].line, endLine: toks[c].line, offset: toks[c].start }));
                c = itemEnd;
              }
              c++;
            }
          }
          k = close;
        }
        k++;
      }
      s.endLine = end < toks.length ? toks[end].line : s.line;
      this.i = end + 1;
      return s;
    }

    parseVHDLProcess(label, k) {
      const toks = this.toks;
      let j = k + 1, sens = '';
      if (this.isOp(j, '(')) { const c = this.matching(j); sens = this.source(j + 1, c - 1); j = c + 1; }
      const detail = 'process' + (sens ? ` (${sens})` : '');
      const startIdx = label != null ? k - 2 : k;
      const s = mkSym('process', label != null ? label : detail, { detail: label != null ? detail : '', line: toks[startIdx].line, endLine: toks[k].line, offset: toks[startIdx].start, dataType: 'process' });
      while (j < toks.length && !(this.word(j) === 'end' && (this.word(j + 1) === 'process' || (this.word(j + 1) === 'postponed' && this.word(j + 2) === 'process')))) {
        if (this.isDesignUnitStart(j)) break;
        j++;
      }
      s.endLine = j < toks.length ? toks[j].line : s.line;
      this.i = this.findTopLevel(j, [';']) + 1;
      return s;
    }
  }

  return { scan, netTypes };
})();

if (typeof module !== 'undefined') module.exports = { SymbolScanner, SymbolKinds, mkSym, symPorts, symParams, flattenSymbols, symbolPathAt, symbolId };
