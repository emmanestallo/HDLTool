'use strict';
// HDL Tester: Verilog port/parameter parser, constant expressions and value literals.
// Port of TesterKit/Model/Verilog.swift and Values.swift.

// ---------------------------------------------------------------- Ports

const PortInfoUtil = {
  baseWidth(p) {
    const words = new Set((p.dataType || '').split(' '));
    if (words.has('longint') || words.has('time')) return 64;
    if (words.has('integer') || words.has('int')) return 32;
    if (words.has('shortint')) return 16;
    if (words.has('byte')) return 8;
    return 1;
  },
  isIntegerType(p) {
    const words = new Set((p.dataType || '').split(' '));
    return ['integer', 'int', 'shortint', 'longint', 'byte'].some((w) => words.has(w));
  },
};
const mkPort = (name, dir, f = {}) => Object.assign({ name, dir, ranges: [], isSigned: false, dataType: '' }, f);

// ---------------------------------------------------------------- Preprocessor

class Preprocessor {
  constructor(defines = {}, readFile = null) {
    this.defines = Object.assign({}, defines);
    this.functionMacros = new Set();
    this.includeDepth = 0;
    this.readFile = readFile; // (path) => string | null
  }

  static stripComments(b) {
    let out = '';
    let i = 0, inStr = false;
    const n = b.length;
    while (i < n) {
      const c = b[i];
      if (inStr) {
        out += c;
        if (c === '\\' && i + 1 < n) { out += b[i + 1]; i += 2; continue; }
        if (c === '"' || c === '\n') inStr = false;
        i++; continue;
      }
      if (c === '"') { inStr = true; out += c; i++; continue; }
      if (c === '/' && b[i + 1] === '/') { while (i < n && b[i] !== '\n') i++; continue; }
      if (c === '/' && b[i + 1] === '*') {
        i += 2;
        while (i < n && !(b[i] === '*' && b[i + 1] === '/')) { if (b[i] === '\n') out += '\n'; i++; }
        i += 2;
        out += ' ';
        continue;
      }
      out += c; i++;
    }
    return out;
  }

  firstWord(s) { const m = /^[\p{L}\p{N}_$]*/u.exec(s); return m ? m[0] : ''; }

  process(text, fileDir) {
    const lines = Preprocessor.stripComments(text).split('\n');
    const out = [];
    const stack = [];
    const active = () => stack.every((s) => s.active);
    let i = 0;
    while (i < lines.length) {
      const line = lines[i];
      const trimmed = line.trim();
      if (trimmed.startsWith('`')) {
        const word = /^\S*/.exec(trimmed)[0];
        const rest = trimmed.slice(word.length).trim();
        let handled = true;
        switch (word) {
          case '`define': {
            let body = rest, extra = 0;
            while (body.endsWith('\\') && i + extra + 1 < lines.length) {
              body = body.slice(0, -1);
              extra++;
              body += ' ' + lines[i + extra].trim();
            }
            if (active()) this.define(body);
            for (let k = 0; k <= extra; k++) out.push('');
            i += 1 + extra;
            continue;
          }
          case '`undef': if (active()) delete this.defines[this.firstWord(rest)]; break;
          case '`ifdef': case '`ifndef': {
            let cond = this.defines[this.firstWord(rest)] !== undefined;
            if (word === '`ifndef') cond = !cond;
            stack.push({ active: cond, taken: cond });
            break;
          }
          case '`elsif': {
            const last = stack.pop();
            if (last) {
              if (last.taken) last.active = false;
              else { const cond = this.defines[this.firstWord(rest)] !== undefined; last.active = cond; last.taken = cond; }
              stack.push(last);
            }
            break;
          }
          case '`else': {
            const last = stack.pop();
            if (last) { last.active = !last.taken; last.taken = true; stack.push(last); }
            break;
          }
          case '`endif': stack.pop(); break;
          case '`include': if (active() && fileDir) this.include(rest, fileDir); break;
          case '`timescale': case '`default_nettype': case '`resetall': case '`celldefine': case '`endcelldefine':
          case '`pragma': case '`line': case '`begin_keywords': case '`end_keywords': case '`unconnected_drive':
          case '`nounconnected_drive': case '`undefineall':
            break;
          default: handled = false;
        }
        if (handled) { out.push(''); i++; continue; }
      }
      out.push(active() ? this.substitute(line) : '');
      i++;
    }
    return out.join('\n');
  }

  define(body) {
    const name = this.firstWord(body);
    if (!name) return;
    const after = body.slice(name.length);
    if (after[0] === '(') { this.functionMacros.add(name); return; }
    this.defines[name] = after.trim();
  }

  include(spec, dir) {
    if (this.includeDepth >= 8 || !this.readFile) return;
    const name = spec.replace(/^["<> ]+|["<> ]+$/g, '');
    const p = PathUtil.join(dir, name);
    const text = this.readFile(p);
    if (text == null) return;
    this.includeDepth++;
    this.process(text, PathUtil.dirname(p));
    this.includeDepth--;
  }

  substitute(line) {
    if (!line.includes('`')) return line;
    let s = line;
    for (let pass = 0; pass < 8; pass++) {
      if (!s.includes('`')) break;
      let result = '', changed = false, idx = 0;
      while (idx < s.length) {
        if (s[idx] === '`') {
          let j = idx + 1;
          while (j < s.length && /[\p{L}\p{N}_]/u.test(s[j])) j++;
          const name = s.slice(idx + 1, j);
          if (Object.prototype.hasOwnProperty.call(this.defines, name)) { result += this.defines[name]; changed = true; }
          else result += s.slice(idx, j);
          idx = j;
        } else { result += s[idx]; idx++; }
      }
      s = result;
      if (!changed) break;
    }
    return s;
  }
}

// ---------------------------------------------------------------- Lexer

const VerilogLexer = (() => {
  const threeSym = new Set(['<<<', '>>>', '===', '!==', '<<=', '>>=', '==?', '!=?']);
  const twoSym = new Set(['**', '<<', '>>', '==', '!=', '<=', '>=', '&&', '||', '::', '+:', '-:',
    '~&', '~|', '~^', '^~', '->', '++', '--', '+=', '-=', "'{", '|=', '&=', '^=']);
  const isIdStart = (c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 95;
  const isIdChar = (c) => isIdStart(c) || (c >= 48 && c <= 57) || c === 36;
  const isDigit = (c) => c >= 48 && c <= 57;
  const isBaseChar = (c) => [98, 111, 100, 104, 66, 79, 68, 72, 115, 83].includes(c);
  const isValueDigit = (c) => isDigit(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) || c === 120 || c === 88 || c === 122 || c === 90 || c === 63 || c === 95;

  function lex(b) {
    const toks = [];
    let i = 0, line = 1;
    const n = b.length;
    const cc = (k) => b.charCodeAt(k);
    const push = (kind, s, e) => toks.push({ kind, text: b.slice(s, e), start: s, end: e, line });
    while (i < n) {
      const c = cc(i);
      if (c === 10) { line++; i++; continue; }
      if (c === 32 || c === 9 || c === 13 || c === 12) { i++; continue; }
      const s = i;
      if (isIdStart(c)) { while (i < n && isIdChar(cc(i))) i++; push('ident', s, i); continue; }
      if (c === 92) { i++; while (i < n && ![32, 9, 10, 13].includes(cc(i))) i++; push('ident', s, i); continue; }
      if (c === 36) { i++; while (i < n && isIdChar(cc(i))) i++; push('system', s, i); continue; }
      if (c === 96) { i++; while (i < n && isIdChar(cc(i))) i++; push('macro', s, i); continue; }
      if (c === 34) {
        i++;
        while (i < n && cc(i) !== 34 && cc(i) !== 10) { if (cc(i) === 92) i++; i++; }
        i = Math.min(i + 1, n);
        push('string', s, i); continue;
      }
      if (isDigit(c) || (c === 39 && i + 1 < n && isBaseChar(cc(i + 1)))) {
        let sized = c === 39;
        if (isDigit(c)) {
          while (i < n && (isDigit(cc(i)) || cc(i) === 95)) i++;
          if (i + 1 < n && cc(i) === 46 && isDigit(cc(i + 1))) { i++; while (i < n && (isDigit(cc(i)) || cc(i) === 95)) i++; }
          if (i < n && (cc(i) === 101 || cc(i) === 69) && i + 1 < n && (isDigit(cc(i + 1)) || ((cc(i + 1) === 45 || cc(i + 1) === 43) && i + 2 < n && isDigit(cc(i + 2))))) {
            i += 2; while (i < n && isDigit(cc(i))) i++;
          }
          let j = i;
          while (j < n && (cc(j) === 32 || cc(j) === 9)) j++;
          if (j + 1 < n && cc(j) === 39 && isBaseChar(cc(j + 1))) { i = j; sized = true; }
        }
        if (sized) {
          i++;
          if (i < n && (cc(i) === 115 || cc(i) === 83)) i++;
          if (i < n) i++;
          while (i < n && (cc(i) === 32 || cc(i) === 9)) i++;
          while (i < n && isValueDigit(cc(i))) i++;
        }
        push('number', s, i); continue;
      }
      if (c === 39 && i + 1 < n && [48, 49, 120, 88, 122, 90].includes(cc(i + 1))) { i += 2; push('number', s, i); continue; }
      if (i + 3 <= n && threeSym.has(b.slice(i, i + 3))) i += 3;
      else if (i + 2 <= n && twoSym.has(b.slice(i, i + 2))) i += 2;
      else i++;
      push('symbol', s, i);
    }
    return toks;
  }
  return { lex };
})();

// ---------------------------------------------------------------- Parser

const VerilogParser = (() => {
  const directionWords = new Set(['input', 'output', 'inout']);
  const typeWords = new Set([
    'wire', 'reg', 'logic', 'bit', 'var', 'tri', 'tri0', 'tri1', 'triand', 'trior', 'trireg', 'wand', 'wor',
    'uwire', 'supply0', 'supply1', 'integer', 'int', 'byte', 'shortint', 'longint', 'time', 'real',
    'realtime', 'shortreal', 'signed', 'unsigned', 'string', 'const', 'interconnect',
  ]);
  const keywords = new Set([
    'always', 'always_comb', 'always_ff', 'always_latch', 'and', 'assert', 'assign', 'assume', 'automatic',
    'begin', 'bit', 'buf', 'bufif0', 'bufif1', 'byte', 'case', 'casex', 'casez', 'cmos', 'const', 'cover',
    'deassign', 'default', 'defparam', 'disable', 'do', 'edge', 'else', 'end', 'endcase', 'endfunction',
    'endgenerate', 'endmodule', 'endtask', 'enum', 'event', 'final', 'for', 'force', 'forever', 'fork',
    'function', 'generate', 'genvar', 'highz0', 'highz1', 'if', 'iff', 'import', 'initial', 'inout', 'input',
    'int', 'integer', 'join', 'join_any', 'join_none', 'large', 'localparam', 'logic', 'longint',
    'macromodule', 'medium', 'module', 'nand', 'negedge', 'nmos', 'nor', 'not', 'notif0', 'notif1', 'or',
    'output', 'parameter', 'pmos', 'posedge', 'primitive', 'pull0', 'pull1', 'pulldown', 'pullup', 'rcmos',
    'real', 'realtime', 'reg', 'release', 'repeat', 'return', 'rnmos', 'rpmos', 'rtran', 'rtranif0',
    'rtranif1', 'scalared', 'shortint', 'signed', 'small', 'specify', 'specparam', 'static', 'strong0',
    'strong1', 'struct', 'supply0', 'supply1', 'table', 'task', 'time', 'tran', 'tranif0', 'tranif1', 'tri',
    'tri0', 'tri1', 'triand', 'trior', 'trireg', 'typedef', 'union', 'unique', 'unique0', 'priority',
    'unsigned', 'vectored', 'wait', 'wand', 'weak0', 'weak1', 'while', 'wire', 'wor', 'xnor', 'xor', 'var',
    'void', 'break', 'continue', 'uwire', 'string', 'class', 'package', 'interface', 'program', 'property',
    'sequence', 'endproperty', 'endsequence', 'covergroup', 'endgroup', 'modport', 'clocking',
    'endclocking', 'let', 'constraint', 'virtual', 'extern', 'export', 'ref', 'type',
  ]);

  // readFile: (path) => string|null, used for `include.
  function parse(raw, file, readFile) {
    const pre = new Preprocessor({}, readFile);
    const processed = pre.process(raw, PathUtil.dirname(file));
    const p = new P(VerilogLexer.lex(processed), processed, file);
    return p.run();
  }

  class P {
    constructor(toks, text, file) { this.toks = toks; this.text = text; this.file = file; }
    tx(i) { return i >= 0 && i < this.toks.length ? this.toks[i].text : ''; }
    run() {
      const modules = [], errors = [];
      let i = 0;
      while (i < this.toks.length) {
        const t = this.toks[i];
        if (t.kind === 'ident' && (t.text === 'module' || t.text === 'macromodule')) {
          const r = this.parseModule(i);
          if (r) { modules.push(r[0]); i = r[1]; continue; }
          errors.push(`Line ${t.line}: could not read the module header`);
        }
        i++;
      }
      return { modules, errors };
    }
    matching(i) {
      let depth = 0;
      for (let k = i; k < this.toks.length; k++) {
        const t = this.toks[k].text;
        if (t === '(' || t === '[' || t === '{' || t === "'{") depth++;
        else if (t === ')' || t === ']' || t === '}') { depth--; if (depth === 0) return k; }
      }
      return this.toks.length - 1;
    }
    splitItems(a, b, sep = ',') {
      const items = [];
      let depth = 0, s = a;
      for (let k = a; k < b; k++) {
        const t = this.toks[k].text;
        if (t === '(' || t === '[' || t === '{' || t === "'{") depth++;
        else if (t === ')' || t === ']' || t === '}') depth--;
        else if (t === sep && depth === 0) { if (k > s) items.push([s, k]); s = k + 1; }
      }
      if (b > s) items.push([s, b]);
      return items;
    }
    source(a, b) {
      if (!(a < b) || b > this.toks.length) return '';
      return this.text.slice(this.toks[a].start, this.toks[b - 1].end).split(/[ \n\t\r]+/).filter(Boolean).join(' ');
    }
    parseRange(open) {
      const close = this.matching(open);
      const parts = this.splitItems(open + 1, close, ':');
      if (parts.length === 2) return [{ msb: this.source(parts[0][0], parts[0][1]), lsb: this.source(parts[1][0], parts[1][1]) }, close + 1];
      if (parts.length === 1) return [{ msb: `(${this.source(parts[0][0], parts[0][1])})-1`, lsb: '0' }, close + 1];
      return [null, close + 1];
    }
    nameIndex(a, b) {
      let depth = 0, last = null;
      for (let k = a; k < b; k++) {
        const t = this.toks[k];
        if (t.text === '(' || t.text === '[' || t.text === '{') depth++;
        else if (t.text === ')' || t.text === ']' || t.text === '}') depth--;
        else if (t.text === '=' && depth === 0) return last;
        else if (depth === 0 && t.kind === 'ident' && !directionWords.has(t.text) && !typeWords.has(t.text) &&
          !(k + 1 < b && (this.toks[k + 1].text === '.' || this.toks[k + 1].text === '::'))) last = k;
      }
      return last;
    }
    parseModule(start) {
      const toks = this.toks;
      let i = start + 1;
      if (this.tx(i) === 'automatic' || this.tx(i) === 'static') i++;
      if (!(i < toks.length && toks[i].kind === 'ident')) return null;
      const name = toks[i].text, line = toks[i].line;
      i++;
      const warnings = [];
      while (this.tx(i) === 'import') { while (i < toks.length && this.tx(i) !== ';') i++; i++; }
      let params = [], headerParams = false;
      if (this.tx(i) === '#' && this.tx(i + 1) === '(') {
        const close = this.matching(i + 1);
        params = this.parseParamItems(i + 2, close, false);
        headerParams = true;
        i = close + 1;
      }
      let ports = [], nonAnsiNames = [], ansi = true;
      if (this.tx(i) === '(') {
        const close = this.matching(i);
        [ports, nonAnsiNames, ansi] = this.parsePortList(i + 1, close);
        i = close + 1;
      }
      if (this.tx(i) === ';') i++;
      let end = i;
      while (end < toks.length && this.tx(end) !== 'endmodule') end++;
      const nonAnsiPorts = new Map(), netDecls = new Map(), instantiates = [];
      let k = i, stmtStart = true;
      while (k < end) {
        const t = toks[k];
        if (t.text === 'function' || t.text === 'task') {
          const closer = t.text === 'function' ? 'endfunction' : 'endtask';
          while (k < end && this.tx(k) !== closer) k++;
          k++; stmtStart = true; continue;
        }
        if (stmtStart && t.kind === 'ident') {
          if (directionWords.has(t.text)) {
            let semi = k;
            while (semi < end && this.tx(semi) !== ';') semi++;
            if (!ansi) for (const p of this.parseDeclaration(k, semi, t.text)) nonAnsiPorts.set(p.name, p);
            k = semi + 1; stmtStart = true; continue;
          }
          if (t.text === 'parameter' || t.text === 'localparam') {
            let semi = k;
            while (semi < end && this.tx(semi) !== ';') semi++;
            const local = t.text === 'localparam' || headerParams;
            for (const p of this.parseParamItems(k, semi, local)) if (!params.some((q) => q.name === p.name)) params.push(p);
            k = semi + 1; stmtStart = true; continue;
          }
          if (!ansi && typeWords.has(t.text)) {
            let semi = k;
            while (semi < end && this.tx(semi) !== ';') semi++;
            for (const p of this.parseDeclaration(k, semi, null)) netDecls.set(p.name, { ranges: p.ranges, type: p.dataType, signed: p.isSigned });
            k = semi + 1; stmtStart = true; continue;
          }
          if (!keywords.has(t.text) && k + 1 < end) {
            const n1 = toks[k + 1];
            if (n1.text === '#' || (n1.kind === 'ident' && this.tx(k + 2) === '(') || (n1.kind === 'ident' && this.tx(k + 2) === '[')) {
              if (!instantiates.includes(t.text)) instantiates.push(t.text);
            }
          }
        }
        stmtStart = [';', 'begin', 'end', 'generate', 'endgenerate', 'else', ')', 'endcase', 'endfunction', 'endtask'].includes(t.text) ||
          (k >= 2 && this.tx(k - 1) === ':' && ['begin', 'end', 'fork'].includes(this.tx(k - 2)));
        k++;
      }
      if (!ansi) {
        for (const n of nonAnsiNames) {
          const p = nonAnsiPorts.get(n);
          if (p) {
            const decl = netDecls.get(n);
            if (decl) {
              if (!p.ranges.length) p.ranges = decl.ranges;
              if (decl.type) p.dataType = p.dataType ? p.dataType + ' ' + decl.type : decl.type;
              p.isSigned = p.isSigned || decl.signed;
            }
            ports.push(p);
          } else {
            ports.push(mkPort(n, 'inout', { unsupported: 'no input/output declaration found' }));
            warnings.push(`Port ${n} has no direction`);
          }
        }
      }
      for (const p of ports) if (p.unsupported != null) warnings.push(`Port ${p.name}: ${p.unsupported}`);
      return [{ name, ports, params, instantiates, file: this.file, line, warnings }, end + 1];
    }
    parseParamItems(a, b, defaultLocal) {
      const out = [];
      let local = defaultLocal;
      for (const [s, e] of this.splitItems(a, b)) {
        let j = s;
        if (this.tx(j) === 'parameter') { local = defaultLocal; j++; } else if (this.tx(j) === 'localparam') { local = true; j++; }
        if (this.tx(j) === 'type') continue;
        let eq = null, depth = 0;
        for (let q = j; q < e; q++) {
          const t = this.tx(q);
          if (t === '(' || t === '[' || t === '{') depth++;
          else if (t === ')' || t === ']' || t === '}') depth--;
          else if (t === '=' && depth === 0 && eq == null) eq = q;
        }
        const ni = this.nameIndex(j, eq != null ? eq : e);
        if (ni == null) continue;
        out.push({ name: this.toks[ni].text, value: eq != null ? this.source(eq + 1, e) : '', isLocal: local });
      }
      return out;
    }
    readType(a, b) {
      const type = [], ranges = [], user = [];
      let signed = false, k = a;
      while (k < b) {
        const t = this.tx(k);
        if (directionWords.has(t)) k++;
        else if (t === 'signed') { signed = true; k++; }
        else if (t === 'unsigned') k++;
        else if (typeWords.has(t)) { type.push(t); k++; }
        else if (t === '[') { const [r, next] = this.parseRange(k); if (r) ranges.push(r); k = next; }
        else { user.push(t); k++; }
      }
      return { type: type.join(' '), signed, ranges, user: user.length ? user.join('') : null };
    }
    parsePortList(a, b) {
      const toks = this.toks;
      const items = this.splitItems(a, b);
      if (!items.length) return [[], [], true];
      const looksAnsi = items.some(([s, e]) => {
        const t = toks[s].text;
        if (directionWords.has(t) || typeWords.has(t)) return true;
        return e - s >= 2 && toks[s].kind === 'ident' && (toks[s + 1].kind === 'ident' || toks[s + 1].text === '.' || toks[s + 1].text === '::');
      });
      if (!looksAnsi) {
        const names = [];
        for (const [s, e] of items) {
          if (this.tx(s) === '.' && s + 1 < e) { names.push(this.tx(s + 1)); continue; }
          for (let q = s; q < e; q++) if (toks[q].kind === 'ident') { names.push(toks[q].text); break; }
        }
        return [[], names, false];
      }
      const ports = [];
      let prev = null;
      for (const [s, e] of items) {
        const ni = this.nameIndex(s, e);
        if (ni == null) continue;
        const name = toks[ni].text;
        const hasDir = directionWords.has(this.tx(s));
        const { type, signed, ranges, user } = this.readType(s, ni);
        let p;
        if (!hasDir && !type && !ranges.length && user == null && !signed && prev) {
          p = Object.assign({}, prev, { name });
        } else {
          const dir = hasDir ? this.tx(s) : (prev ? prev.dir : 'inout');
          p = mkPort(name, dir, { ranges, isSigned: signed, dataType: type });
          if (user != null) {
            p.dataType = user;
            p.unsupported = (user.includes('.') || !hasDir) ? `interface port (${user})` : `user-defined type ${user}`;
          }
          if (type.includes('real') || type.includes('string')) p.unsupported = `${type} ports are not supported`;
          if (!hasDir && !prev && user == null) p.unsupported = 'no direction';
        }
        if (this.tx(ni + 1) === '[') p.unsupported = 'unpacked array port';
        ports.push(p);
        prev = p;
      }
      return [ports, [], true];
    }
    parseDeclaration(a, b, dir) {
      const items = this.splitItems(a, b);
      if (!items.length) return [];
      const ni = this.nameIndex(items[0][0], items[0][1]);
      if (ni == null) return [];
      const { type, signed, ranges, user } = this.readType(items[0][0], ni);
      const out = [];
      items.forEach(([s, e], idx) => {
        const n = idx === 0 ? ni : (this.nameIndex(s, e) ?? s);
        if (!(n < this.toks.length && this.toks[n].kind === 'ident')) return;
        const p = mkPort(this.toks[n].text, dir || 'inout', { ranges: ranges.map((r) => Object.assign({}, r)), isSigned: signed, dataType: type });
        if (user != null) p.unsupported = `user-defined type ${user}`;
        if (this.tx(n + 1) === '[') p.unsupported = 'unpacked array port';
        out.push(p);
      });
      return out;
    }
  }

  return { parse, keywords, typeWords, directionWords };
})();

// ---------------------------------------------------------------- Constant expressions (64-bit, like Swift Int)

const ExprEval = (() => {
  const binary = {
    '||': 2, '&&': 3, '|': 4, '^': 5, '~^': 5, '^~': 5, '&': 6,
    '==': 7, '!=': 7, '===': 7, '!==': 7, '<': 8, '<=': 8, '>': 8, '>=': 8,
    '<<': 9, '>>': 9, '<<<': 9, '>>>': 9, '+': 10, '-': 10, '*': 11, '/': 11, '%': 11, '**': 12,
  };
  const W = (v) => BigInt.asIntN(64, v);
  const B = (c) => (c ? 1n : 0n);

  function apply(op, a, b) {
    switch (op) {
      case '+': return W(a + b);
      case '-': return W(a - b);
      case '*': return W(a * b);
      case '/': return b === 0n ? null : W(a / b);
      case '%': return b === 0n ? null : W(a % b);
      case '**': { if (b < 0n || b >= 63n) return null; let r = 1n; for (let k = 0n; k < b; k++) r = W(r * a); return r; }
      case '<<': case '<<<': return b >= 0n && b < 63n ? W(a << b) : null;
      case '>>': case '>>>': return b >= 0n && b < 63n ? a >> b : null;
      case '&': return a & b;
      case '|': return a | b;
      case '^': return a ^ b;
      case '~^': case '^~': return ~(a ^ b);
      case '==': case '===': return B(a === b);
      case '!=': case '!==': return B(a !== b);
      case '<': return B(a < b);
      case '<=': return B(a <= b);
      case '>': return B(a > b);
      case '>=': return B(a >= b);
      case '&&': return B(a !== 0n && b !== 0n);
      case '||': return B(a !== 0n || b !== 0n);
      default: return null;
    }
  }

  // env: { name: Number }. Returns a Number or null.
  function evaluate(text, env) {
    const toks = VerilogLexer.lex(text);
    if (!toks.length) return null;
    let i = 0;
    const peek = () => (i < toks.length ? toks[i].text : '');
    function expr(minPrec) {
      let lhs = unary();
      if (lhs == null) return null;
      for (;;) {
        const op = peek();
        if (op === '?' && minPrec <= 1) {
          i++;
          const a = expr(0);
          if (a == null || peek() !== ':') return null;
          i++;
          const b = expr(1);
          if (b == null) return null;
          lhs = lhs !== 0n ? a : b;
          continue;
        }
        const prec = binary[op];
        if (prec == null || prec < minPrec) break;
        i++;
        const rhs = expr(op === '**' ? prec : prec + 1);
        if (rhs == null) return null;
        const v = apply(op, lhs, rhs);
        if (v == null) return null;
        lhs = v;
      }
      return lhs;
    }
    function unary() {
      switch (peek()) {
        case '-': { i++; const v = unary(); return v == null ? null : W(-v); }
        case '+': i++; return unary();
        case '!': { i++; const v = unary(); return v == null ? null : B(v === 0n); }
        case '~': { i++; const v = unary(); return v == null ? null : ~v; }
        default: return primary();
      }
    }
    function primary() {
      if (i >= toks.length) return null;
      const t = toks[i];
      if (t.kind === 'number') {
        i++;
        const lit = LogicLiteral.parse(t.text);
        const v = lit ? LogicLiteral.intValue(lit) : null;
        return v == null ? null : v;
      }
      if (t.kind === 'ident') {
        i++;
        return Object.prototype.hasOwnProperty.call(env, t.text) ? BigInt(env[t.text]) : null;
      }
      if (t.kind === 'system') {
        i++;
        if (peek() !== '(') return null;
        i++;
        const a = expr(0);
        if (a == null || peek() !== ')') return null;
        i++;
        if (t.text === '$clog2') {
          if (a <= 1n) return 0n;
          let r = 0n, v = a - 1n;
          while (v > 0n) { r++; v >>= 1n; }
          return r;
        }
        if (t.text === '$signed' || t.text === '$unsigned') return a;
        return null;
      }
      if (t.kind === 'symbol' && t.text === '(') {
        i++;
        const v = expr(0);
        if (v == null || peek() !== ')') return null;
        i++;
        return v;
      }
      return null;
    }
    const v = expr(0);
    if (v == null || i !== toks.length) return null;
    return Number(v);
  }
  return { eval: evaluate };
})();

// ---------------------------------------------------------------- Value literals

// Bits are '0' '1' 'x' 'z' characters in arrays, most significant first.
const LogicLiteral = {
  // { base: 'b'|'o'|'d'|'h', digits, negative, size }
  parse(raw) {
    let s = raw.trim().replace(/_/g, '').replace(/ /g, '');
    if (!s) return null;
    let negative = false;
    if (s.startsWith('-')) { negative = true; s = s.slice(1); }
    const lower = s.toLowerCase();
    if (lower === 'x' || lower === 'z' || lower === '?') return { base: 'b', digits: lower === '?' ? 'z' : lower, negative: false, size: null };
    const q = lower.indexOf("'");
    if (q >= 0) {
      const sizeText = lower.slice(0, q);
      let rest = lower.slice(q + 1);
      if (rest[0] === 's') rest = rest.slice(1);
      const b = rest[0];
      if (!b || !'bodh'.includes(b)) return null;
      const digits = rest.slice(1).replace(/\?/g, 'z');
      if (!digits || !LogicLiteral.valid(digits, b)) return null;
      let size = null;
      if (sizeText) {
        if (!/^\d+$/.test(sizeText)) return null;
        const n = parseInt(sizeText, 10);
        if (!(n > 0)) return null;
        size = n;
      }
      return { base: b, digits, negative, size };
    }
    for (const [pre, b] of [['0x', 'h'], ['0b', 'b'], ['0o', 'o']]) {
      if (lower.startsWith(pre) && lower.length > 2) {
        const d = lower.slice(2);
        return LogicLiteral.valid(d, b) ? { base: b, digits: d, negative, size: null } : null;
      }
    }
    if (/^[0-9]+$/.test(lower)) return { base: 'd', digits: lower, negative, size: null };
    return null;
  },
  valid(d, base) {
    const allowed = base === 'b' ? '01xz' : base === 'o' ? '01234567xz' : base === 'd' ? '0123456789' : '0123456789abcdefxz';
    if (base === 'd' && (d === 'x' || d === 'z')) return true;
    return [...d].every((c) => allowed.includes(c));
  },
  // BigInt (fits in signed 64 bits) or null.
  intValue(l) {
    if (l.digits.includes('x') || l.digits.includes('z')) return null;
    const radix = l.base === 'b' ? 2 : l.base === 'o' ? 8 : l.base === 'h' ? 16 : 10;
    let v = 0n;
    for (const c of l.digits) v = v * BigInt(radix) + BigInt(parseInt(c, 16));
    if (v > 0x7FFFFFFFFFFFFFFFn) return null;
    return l.negative ? -v : v;
  },
  verilog(l, width) {
    const w = width != null ? String(width) : '';
    let base = l.base, digits = l.digits;
    if (width === 1 && base === 'd' && /^\d+$/.test(digits) && BigInt(digits) <= 1n) { base = 'b'; digits = String(BigInt(digits)); }
    const body = `${w}'${base}${digits}`;
    return l.negative ? `-${body}` : body;
  },
  bits(l, width) {
    if (!(width > 0)) return null;
    let bits = [];
    if (l.base === 'b' || l.base === 'o' || l.base === 'h') {
      const per = l.base === 'b' ? 1 : (l.base === 'o' ? 3 : 4);
      for (const ch of l.digits) {
        if (ch === 'x' || ch === 'z') { for (let k = 0; k < per; k++) bits.push(ch); }
        else {
          const v = parseInt(ch, 16);
          if (isNaN(v)) return null;
          for (let k = per - 1; k >= 0; k--) bits.push((v >> k) & 1 ? '1' : '0');
        }
      }
    } else {
      if (l.digits === 'x' || l.digits === 'z') return new Array(width).fill(l.digits);
      if (!/^\d+$/.test(l.digits)) return null;
      const v = BigInt(l.digits);
      if (v >= (1n << 64n)) return null;
      for (let k = 63; k >= 0; k--) bits.push((v >> BigInt(k)) & 1n ? '1' : '0');
    }
    if (bits.length < width) {
      const fill = (bits[0] === 'x' || bits[0] === 'z') ? bits[0] : '0';
      bits = new Array(width - bits.length).fill(fill).concat(bits);
    } else if (bits.length > width) bits = bits.slice(bits.length - width);
    if (l.negative) bits = LogicLiteral.negate(bits);
    return bits;
  },
  negate(b) {
    if (b.includes('x') || b.includes('z')) return new Array(b.length).fill('x');
    const out = b.map((c) => (c === '1' ? '0' : '1'));
    for (let i = out.length - 1; i >= 0; i--) { if (out[i] === '0') { out[i] = '1'; break; } out[i] = '0'; }
    return out;
  },
};

const BitsFormat = {
  hex(bits) {
    if (bits.every((b) => b === 'x')) return 'x';
    if (bits.every((b) => b === 'z')) return 'z';
    let out = '', end = bits.length;
    while (end > 0) {
      const start = Math.max(0, end - 4);
      const nib = bits.slice(start, end);
      if (nib.includes('x')) out = 'x' + out;
      else if (nib.includes('z')) out = 'z' + out;
      else { let v = 0; for (const b of nib) v = v * 2 + (b === '1' ? 1 : 0); out = v.toString(16).toUpperCase() + out; }
      end = start;
    }
    return out;
  },
  // BigInt or null
  uint(bits) {
    if (bits.length > 64 || bits.includes('x') || bits.includes('z')) return null;
    let v = 0n;
    for (const b of bits) v = (v << 1n) | (b === '1' ? 1n : 0n);
    return v;
  },
  bits(v, width) {
    const out = [];
    for (let k = width - 1; k >= 0; k--) out.push(k < 64 && ((v >> BigInt(k)) & 1n) ? '1' : '0');
    return out;
  },
};

// ---------------------------------------------------------------- Time & formatting

const TimeUnits = {
  all: ['fs', 'ps', 'ns', 'us', 'ms', 's'],
  exponent(u) { return { fs: -15, ps: -12, ns: -9, us: -6, ms: -3, s: 0 }[u]; },
  seconds(u) { return Math.pow(10, TimeUnits.exponent(u)); },
};

const Fmt = {
  num(d) {
    if (d === Math.round(d) && Math.abs(d) < 1e15) return String(Math.trunc(d));
    let s = d.toFixed(6);
    s = s.replace(/0+$/, '');
    if (s.endsWith('.')) s = s.slice(0, -1);
    return s;
  },
  frequency(period, unit) {
    const secs = period * TimeUnits.seconds(unit);
    if (!(secs > 0)) return '';
    const f = 1 / secs;
    for (const [scale, name] of [[1e12, 'THz'], [1e9, 'GHz'], [1e6, 'MHz'], [1e3, 'kHz'], [1, 'Hz']]) {
      if (f >= scale) return Fmt.num(Math.round(f / scale * 1000) / 1000) + ' ' + name;
    }
    return Fmt.num(f) + ' Hz';
  },
  identifier(s) {
    let out = [...s].map((c) => (/[A-Za-z0-9_]/.test(c) ? c : '_')).join('');
    if (!out) return 'tb';
    if (/[0-9]/.test(out[0])) out = '_' + out;
    return out;
  },
  isIdentifier(s) {
    if (!s || !/[A-Za-z_]/.test(s[0])) return false;
    return /^[A-Za-z0-9_$]+$/.test(s) && !VerilogParser.keywords.has(s);
  },
};

if (typeof module !== 'undefined') module.exports = { PortInfoUtil, mkPort, Preprocessor, VerilogLexer, VerilogParser, ExprEval, LogicLiteral, BitsFormat, TimeUnits, Fmt };
