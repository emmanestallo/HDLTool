'use strict';
// Tokenizer for Verilog, SystemVerilog and VHDL. Port of CoderKit/Model/Lexer.swift.
// Offsets are UTF-16 code units (same as JavaScript string indices).

const HDLLanguage = {
  verilog: 'verilog', systemVerilog: 'systemVerilog', vhdl: 'vhdl', plain: 'plain',
  all: ['verilog', 'systemVerilog', 'vhdl', 'plain'],
  displayName(l) { return { verilog: 'Verilog', systemVerilog: 'SystemVerilog', vhdl: 'VHDL', plain: 'Plain Text' }[l] || l; },
  isVerilogFamily(l) { return l === 'verilog' || l === 'systemVerilog'; },
  lineComment(l) { return l === 'vhdl' ? '--' : (l === 'plain' ? null : '//'); },
  detect(path) {
    if (!path) return 'verilog';
    const m = /\.([^.\\/]+)$/.exec(path);
    const ext = m ? m[1].toLowerCase() : '';
    if (['v', 'vh', 'vlog', 'verilog', 'vg'].includes(ext)) return 'verilog';
    if (['sv', 'svh', 'svi', 'svp'].includes(ext)) return 'systemVerilog';
    if (['vhd', 'vhdl', 'vho', 'vht'].includes(ext)) return 'vhdl';
    return 'plain';
  },
  hdlExtensions: new Set(['v', 'vh', 'sv', 'svh', 'vhd', 'vhdl', 'vlog', 'verilog', 'vg', 'svi', 'vho', 'vht']),
};

const Keywords = {
  verilogControl: new Set([
    'if', 'else', 'case', 'casez', 'casex', 'endcase', 'for', 'while', 'repeat', 'forever', 'do', 'foreach',
    'return', 'break', 'continue', 'default', 'wait', 'disable', 'fork', 'join', 'join_any', 'join_none',
    'unique', 'unique0', 'priority', 'randcase', 'iff', 'inside',
  ]),
  verilogTypes: new Set([
    'wire', 'reg', 'logic', 'bit', 'byte', 'int', 'integer', 'shortint', 'longint', 'real', 'realtime', 'shortreal',
    'time', 'string', 'signed', 'unsigned', 'tri', 'tri0', 'tri1', 'triand', 'trior', 'trireg', 'wand', 'wor',
    'supply0', 'supply1', 'uwire', 'genvar', 'void', 'chandle', 'event', 'enum', 'struct', 'union', 'packed', 'var',
    'parameter', 'localparam', 'defparam', 'specparam', 'const', 'type',
  ]),
  verilogKeywords: new Set([
    'module', 'endmodule', 'macromodule', 'input', 'output', 'inout', 'ref', 'assign', 'deassign', 'force', 'release',
    'always', 'always_ff', 'always_comb', 'always_latch', 'initial', 'final', 'begin', 'end', 'posedge', 'negedge',
    'edge', 'or', 'and', 'nand', 'nor', 'xor', 'xnor', 'not', 'buf', 'bufif0', 'bufif1', 'notif0', 'notif1',
    'function', 'endfunction', 'task', 'endtask', 'automatic', 'static', 'generate', 'endgenerate',
    'primitive', 'endprimitive', 'table', 'endtable', 'specify', 'endspecify', 'config', 'endconfig',
    'library', 'design', 'instance', 'cell', 'use', 'liblist', 'include', 'pullup', 'pulldown', 'scalared', 'vectored',
    'small', 'medium', 'large', 'strong0', 'strong1', 'pull0', 'pull1', 'weak0', 'weak1', 'highz0', 'highz1',
    'interface', 'endinterface', 'modport', 'package', 'endpackage', 'import', 'export', 'typedef', 'class',
    'endclass', 'extends', 'implements', 'virtual', 'pure', 'extern', 'new', 'this', 'super', 'null', 'local',
    'protected', 'rand', 'randc', 'constraint', 'solve', 'before', 'with', 'program', 'endprogram', 'clocking',
    'endclocking', 'covergroup', 'endgroup', 'coverpoint', 'cross', 'bins', 'illegal_bins', 'ignore_bins',
    'property', 'endproperty', 'sequence', 'endsequence', 'assert', 'assume', 'cover', 'expect', 'restrict',
    'checker', 'endchecker', 'let', 'alias', 'bind', 'context', 'timeunit', 'timeprecision', 'nettype',
    'interconnect', 'soft', 'matches', 'tagged', 'within', 'throughout', 'intersect', 'first_match', 'dist',
    'global', 's_always', 's_eventually', 'eventually', 'nexttime', 's_nexttime', 'until', 's_until',
    'until_with', 's_until_with', 'implies', 'accept_on', 'reject_on', 'sync_accept_on', 'sync_reject_on',
    'strong', 'weak', 'untyped', 'forkjoin', 'randomize', 'randsequence', 'wait_order', 'triggered',
    'genvar_unused', 'highz', 'rtran', 'rtranif0', 'rtranif1', 'tran', 'tranif0', 'tranif1', 'cmos', 'rcmos',
    'nmos', 'pmos', 'rnmos', 'rpmos', 'showcancelled', 'noshowcancelled', 'pulsestyle_onevent',
    'pulsestyle_ondetect', 'ifnone', 'endtable_unused',
  ]),
  vhdlControl: new Set([
    'if', 'then', 'else', 'elsif', 'case', 'when', 'loop', 'for', 'while', 'exit', 'next', 'return', 'wait',
    'until', 'others', 'select', 'after', 'report', 'severity', 'assert',
  ]),
  vhdlTypes: new Set([
    'std_logic', 'std_ulogic', 'std_logic_vector', 'std_ulogic_vector', 'bit', 'bit_vector', 'boolean',
    'integer', 'natural', 'positive', 'real', 'time', 'string', 'character', 'signed', 'unsigned', 'line',
    'text', 'severity_level', 'file_open_kind', 'delay_length', 'sfixed', 'ufixed', 'float', 'unresolved_signed',
    'unresolved_unsigned', 'u_signed', 'u_unsigned', 'boolean_vector', 'integer_vector', 'real_vector', 'time_vector',
  ]),
  vhdlKeywords: new Set([
    'abs', 'access', 'alias', 'all', 'and', 'architecture', 'array', 'attribute', 'begin', 'block', 'body',
    'buffer', 'bus', 'component', 'configuration', 'constant', 'disconnect', 'downto', 'end', 'entity', 'file',
    'function', 'generate', 'generic', 'group', 'guarded', 'impure', 'in', 'inertial', 'inout', 'is', 'label',
    'library', 'linkage', 'literal', 'map', 'mod', 'nand', 'new', 'nor', 'not', 'null', 'of', 'on', 'open', 'or',
    'out', 'package', 'port', 'postponed', 'procedure', 'process', 'pure', 'range', 'record', 'register',
    'reject', 'rem', 'return', 'rol', 'ror', 'shared', 'signal', 'sla', 'sll', 'sra', 'srl', 'subtype', 'to',
    'transport', 'type', 'units', 'use', 'variable', 'xnor', 'xor', 'context', 'force', 'release', 'parameter',
    'protected', 'sequence', 'property', 'vunit', 'vmode', 'vprop', 'default', 'fairness', 'strong', 'assume',
    'cover', 'restrict',
  ]),
  systemTasks: [
    '$display', '$write', '$strobe', '$monitor', '$monitoron', '$monitoroff', '$displayb', '$displayh', '$displayo',
    '$finish', '$stop', '$time', '$stime', '$realtime', '$random', '$urandom', '$urandom_range', '$dumpfile',
    '$dumpvars', '$dumpon', '$dumpoff', '$dumpall', '$dumpflush', '$readmemh', '$readmemb', '$writememh',
    '$writememb', '$fopen', '$fclose', '$fdisplay', '$fwrite', '$fscanf', '$sscanf', '$fgets', '$feof',
    '$signed', '$unsigned', '$clog2', '$bits', '$size', '$high', '$low', '$left', '$right', '$increment',
    '$countones', '$onehot', '$onehot0', '$isunknown', '$rose', '$fell', '$stable', '$past', '$changed',
    '$error', '$warning', '$info', '$fatal', '$sformatf', '$sformat', '$itor', '$rtoi', '$realtobits',
    '$bitstoreal', '$timeformat', '$printtimescale', '$value$plusargs', '$test$plusargs', '$cast', '$floor',
    '$ceil', '$sqrt', '$pow', '$ln', '$log10', '$exp', '$sin', '$cos', '$abs', '$shortrealtobits',
  ],
  directives: [
    '`timescale', '`define', '`undef', '`ifdef', '`ifndef', '`elsif', '`else', '`endif', '`include',
    '`default_nettype', '`resetall', '`celldefine', '`endcelldefine', '`line', '`pragma', '`unconnected_drive',
    '`nounconnected_drive', '`begin_keywords', '`end_keywords', '`__FILE__', '`__LINE__',
  ],
};
Keywords.verilogAll = new Set([...Keywords.verilogKeywords, ...Keywords.verilogTypes, ...Keywords.verilogControl]);
Keywords.vhdlAll = new Set([...Keywords.vhdlKeywords, ...Keywords.vhdlControl]);

// Token: { kind, start, length, line, end }
// kinds: keyword control type comment string number system directive attribute ident op placeholder typeName funcName
const Lexer = (() => {
  const isIdStart = (c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 95;
  const isIdChar = (c) => isIdStart(c) || (c >= 48 && c <= 57) || c === 36;
  const isDigit = (c) => c >= 48 && c <= 57;
  const isHexish = (c) => isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102) || c === 95 || c === 120 || c === 88 || c === 122 || c === 90 || c === 63;
  const isSpace = (c) => c === 32 || c === 9 || c === 13 || c === 12;
  const isBase = (c) => c === 98 || c === 66 || c === 111 || c === 79 || c === 100 || c === 68 || c === 104 || c === 72;

  function tok(kind, start, end, line) { return { kind, start, length: end - start, end, line }; }

  function lex(text, language) {
    if (language === 'vhdl') return lexVHDL(text);
    if (language === 'plain') return [];
    return lexVerilog(text);
  }

  const str = (text, t) => text.slice(t.start, t.end);

  function lexVerilog(u) {
    const toks = [];
    const n = u.length;
    let i = 0, line = 0;
    const cc = (k) => u.charCodeAt(k);
    const add = (k, s, e, l) => toks.push(tok(k, s, e, l));
    while (i < n) {
      const c = cc(i);
      if (c === 10) { line++; i++; continue; }
      if (isSpace(c)) { i++; continue; }
      const start = i, startLine = line;
      if (c === 47 && i + 1 < n) {
        if (cc(i + 1) === 47) {
          while (i < n && cc(i) !== 10) i++;
          add('comment', start, i, startLine); continue;
        }
        if (cc(i + 1) === 42) {
          i += 2;
          while (i < n && !(cc(i) === 42 && i + 1 < n && cc(i + 1) === 47)) { if (cc(i) === 10) line++; i++; }
          i = Math.min(n, i + 2);
          add('comment', start, i, startLine); continue;
        }
      }
      // Attribute (* ... *), but not @(*)
      if (c === 40 && i + 1 < n && cc(i + 1) === 42 && !(i + 2 < n && cc(i + 2) === 41)) {
        let j = i + 2, ok = false;
        while (j + 1 < n && cc(j) !== 10) { if (cc(j) === 42 && cc(j + 1) === 41) { ok = true; break; } j++; }
        if (ok && j > i + 2) { i = j + 2; add('attribute', start, i, startLine); continue; }
      }
      // Placeholder <#name#>
      if (c === 60 && i + 1 < n && cc(i + 1) === 35) {
        let j = i + 2;
        while (j + 1 < n && cc(j) !== 10 && !(cc(j) === 35 && cc(j + 1) === 62)) j++;
        if (j + 1 < n && cc(j) === 35 && cc(j + 1) === 62) { i = j + 2; add('placeholder', start, i, startLine); continue; }
      }
      if (c === 34) {
        i++;
        while (i < n && cc(i) !== 34 && cc(i) !== 10) { if (cc(i) === 92) i++; i++; }
        i = Math.min(n, i + 1);
        add('string', start, i, startLine); continue;
      }
      if (c === 96) {
        i++;
        while (i < n && isIdChar(cc(i))) i++;
        add('directive', start, i, startLine); continue;
      }
      if (c === 36 && i + 1 < n && isIdStart(cc(i + 1))) {
        i++;
        while (i < n && isIdChar(cc(i))) i++;
        add('system', start, i, startLine); continue;
      }
      const c1 = i + 1 < n ? cc(i + 1) : -1;
      if (isDigit(c) || (c === 39 && i + 1 < n && (isBase(c1) || c1 === 48 || c1 === 49 || c1 === 120 || c1 === 122 || c1 === 88 || c1 === 90 || c1 === 115 || c1 === 83))) {
        if (isDigit(c)) {
          while (i < n && (isDigit(cc(i)) || cc(i) === 95)) i++;
          if (i + 1 < n && cc(i) === 46 && isDigit(cc(i + 1))) {
            i++;
            while (i < n && (isDigit(cc(i)) || cc(i) === 95)) i++;
          }
          if (i < n && (cc(i) === 101 || cc(i) === 69) && i + 1 < n && (isDigit(cc(i + 1)) || ((cc(i + 1) === 45 || cc(i + 1) === 43) && i + 2 < n && isDigit(cc(i + 2))))) {
            i += 2;
            while (i < n && isDigit(cc(i))) i++;
          }
          if (i + 1 < n && [115, 109, 117, 110, 112, 102].includes(cc(i)) && cc(i + 1) === 115 && !(i + 2 < n && isIdChar(cc(i + 2)))) i += 2;
          else if (i < n && cc(i) === 115 && !(i + 1 < n && isIdChar(cc(i + 1)))) i += 1;
          let j = i;
          while (j < n && (cc(j) === 32 || cc(j) === 9)) j++;
          if (j < n && cc(j) === 39) i = j;
        }
        if (i < n && cc(i) === 39) {
          i++;
          if (i < n && (cc(i) === 115 || cc(i) === 83)) i++;
          if (i < n && isBase(cc(i))) {
            i++;
            while (i < n && (cc(i) === 32 || cc(i) === 9)) i++;
            while (i < n && isHexish(cc(i))) i++;
          } else if (i < n && [48, 49, 120, 88, 122, 90].includes(cc(i))) {
            i++;
          }
        }
        add('number', start, i, startLine); continue;
      }
      if (isIdStart(c)) {
        i++;
        while (i < n && isIdChar(cc(i))) i++;
        const word = u.slice(start, i);
        let kind = 'ident';
        if (Keywords.verilogControl.has(word)) kind = 'control';
        else if (Keywords.verilogTypes.has(word)) kind = 'type';
        else if (Keywords.verilogKeywords.has(word)) kind = 'keyword';
        add(kind, start, i, startLine); continue;
      }
      if (c === 92) {
        i++;
        while (i < n && !isSpace(cc(i)) && cc(i) !== 10) i++;
        add('ident', start, i, startLine); continue;
      }
      i++;
      add('op', start, i, startLine);
    }
    markNames(toks, u, false);
    return toks;
  }

  function lexVHDL(u) {
    const toks = [];
    const n = u.length;
    let i = 0, line = 0;
    const cc = (k) => u.charCodeAt(k);
    const add = (k, s, e, l) => toks.push(tok(k, s, e, l));
    while (i < n) {
      const c = cc(i);
      if (c === 10) { line++; i++; continue; }
      if (isSpace(c)) { i++; continue; }
      const start = i, startLine = line;
      if (c === 45 && i + 1 < n && cc(i + 1) === 45) {
        while (i < n && cc(i) !== 10) i++;
        add('comment', start, i, startLine); continue;
      }
      if (c === 47 && i + 1 < n && cc(i + 1) === 42) {
        i += 2;
        while (i < n && !(cc(i) === 42 && i + 1 < n && cc(i + 1) === 47)) { if (cc(i) === 10) line++; i++; }
        i = Math.min(n, i + 2);
        add('comment', start, i, startLine); continue;
      }
      if (c === 60 && i + 1 < n && cc(i + 1) === 35) {
        let j = i + 2;
        while (j + 1 < n && cc(j) !== 10 && !(cc(j) === 35 && cc(j + 1) === 62)) j++;
        if (j + 1 < n && cc(j) === 35 && cc(j + 1) === 62) { i = j + 2; add('placeholder', start, i, startLine); continue; }
      }
      if (c === 34) {
        i++;
        while (i < n && cc(i) !== 10) {
          if (cc(i) === 34) { if (i + 1 < n && cc(i + 1) === 34) { i += 2; continue; } break; }
          i++;
        }
        i = Math.min(n, i + 1);
        add('string', start, i, startLine); continue;
      }
      if (c === 39) {
        const prev = toks[toks.length - 1];
        const afterName = prev ? ((prev.kind === 'ident' || prev.kind === 'type' || (prev.kind === 'op' && (cc(prev.start) === 41 || cc(prev.start) === 93))) && prev.end === i) : false;
        if (!afterName && i + 2 < n && cc(i + 2) === 39) { i += 3; add('string', start, i, startLine); continue; }
        if (afterName && i + 1 < n && isIdStart(cc(i + 1))) {
          i++;
          while (i < n && isIdChar(cc(i)) && cc(i) !== 36) i++;
          add('system', start, i, startLine); continue;
        }
      }
      if (isDigit(c)) {
        while (i < n && (isDigit(cc(i)) || cc(i) === 95)) i++;
        if (i < n && cc(i) === 35) {
          i++;
          while (i < n && cc(i) !== 35 && cc(i) !== 10 && (isHexish(cc(i)) || cc(i) === 46)) i++;
          if (i < n && cc(i) === 35) i++;
        } else {
          if (i + 1 < n && cc(i) === 46 && isDigit(cc(i + 1))) {
            i++;
            while (i < n && (isDigit(cc(i)) || cc(i) === 95)) i++;
          }
          if (i < n && (cc(i) === 101 || cc(i) === 69) && i + 1 < n && (isDigit(cc(i + 1)) || cc(i + 1) === 45 || cc(i + 1) === 43)) {
            i += 2;
            while (i < n && isDigit(cc(i))) i++;
          }
          if (i + 1 < n && [98, 66, 111, 79, 120, 88, 100, 68].includes(cc(i)) && cc(i + 1) === 34) {
            i += 2;
            while (i < n && cc(i) !== 34 && cc(i) !== 10) i++;
            i = Math.min(n, i + 1);
          }
        }
        add('number', start, i, startLine); continue;
      }
      if (isIdStart(c)) {
        let j = i;
        if (j + 1 < n && [117, 85, 115, 83].includes(cc(j)) && [98, 66, 111, 79, 120, 88].includes(cc(j + 1)) && j + 2 < n && cc(j + 2) === 34) j++;
        if (j + 1 < n && [98, 66, 111, 79, 120, 88, 100, 68].includes(cc(j)) && cc(j + 1) === 34 && (j === i || j === i + 1)) {
          i = j + 2;
          while (i < n && cc(i) !== 34 && cc(i) !== 10) i++;
          i = Math.min(n, i + 1);
          add('number', start, i, startLine); continue;
        }
        i++;
        while (i < n && isIdChar(cc(i)) && cc(i) !== 36) i++;
        const word = u.slice(start, i).toLowerCase();
        let kind = 'ident';
        if (Keywords.vhdlControl.has(word)) kind = 'control';
        else if (Keywords.vhdlTypes.has(word)) kind = 'type';
        else if (Keywords.vhdlKeywords.has(word)) kind = 'keyword';
        else if (word === 'true' || word === 'false') kind = 'number';
        add(kind, start, i, startLine); continue;
      }
      if (c === 92) {
        i++;
        while (i < n && cc(i) !== 92 && cc(i) !== 10) i++;
        i = Math.min(n, i + 1);
        add('ident', start, i, startLine); continue;
      }
      i++;
      add('op', start, i, startLine);
    }
    markNames(toks, u, true);
    return toks;
  }

  function nextSig(toks, from) {
    for (let j = from; j < toks.length; j++) if (toks[j].kind !== 'comment' && toks[j].kind !== 'attribute') return j;
    return -1;
  }

  // Colors declared names: module/entity names, module types of instances, function names.
  function markNames(toks, u, vhdl) {
    const declKeywords = vhdl
      ? new Set(['entity', 'architecture', 'package', 'component', 'configuration', 'body', 'of'])
      : new Set(['module', 'macromodule', 'interface', 'program', 'package', 'class', 'extends', 'primitive', 'checker']);
    const funcKeywords = vhdl ? new Set(['function', 'procedure']) : new Set(['function', 'task']);
    const isOp = (t, ch) => !!t && t.kind === 'op' && u.charCodeAt(t.start) === ch;
    let depth = 0, prev = null, prev2 = null, prev3 = null;
    for (let k = 0; k < toks.length; k++) {
      const t = toks[k];
      if (t.kind === 'comment' || t.kind === 'attribute') continue;
      if (t.kind === 'op') {
        const ch = u.charCodeAt(t.start);
        if (ch === 40) depth++; else if (ch === 41) depth = Math.max(0, depth - 1);
      }
      if (t.kind === 'ident') {
        const next = nextSig(toks, k + 1);
        const nt = next >= 0 ? toks[next] : null;
        if (prev && (prev.kind === 'keyword' || prev.kind === 'type')) {
          const w = vhdl ? str(u, prev).toLowerCase() : str(u, prev);
          if (declKeywords.has(w)) t.kind = 'typeName';
          else if (funcKeywords.has(w)) t.kind = 'funcName';
        } else if (vhdl) {
          if (isOp(prev, 46) && prev3 && prev3.kind === 'keyword' && str(u, prev3).toLowerCase() === 'entity') {
            t.kind = 'typeName';
          } else if (isOp(prev, 58) && nt && nt.kind === 'keyword' && ['port', 'generic'].includes(str(u, nt).toLowerCase())) {
            t.kind = 'typeName';
          }
        } else if (depth === 0 && (!prev || (prev.kind !== 'ident' && prev.kind !== 'typeName')) && !isOp(prev, 46) && nt) {
          if (isOp(nt, 35)) t.kind = 'typeName';
          else if (nt.kind === 'ident') {
            const n2 = nextSig(toks, next + 1);
            if (n2 >= 0 && (isOp(toks[n2], 40) || isOp(toks[n2], 91))) t.kind = 'typeName';
          } else if (isOp(nt, 40)) t.kind = 'funcName';
        } else if (!vhdl && nt && isOp(nt, 40) && !isOp(prev, 46) && (!prev || (prev.kind !== 'ident' && prev.kind !== 'typeName'))) {
          t.kind = 'funcName';
        }
      }
      prev3 = prev2; prev2 = prev; prev = t;
    }
  }

  // Index of the token containing or starting at/after `offset`.
  function indexAt(toks, offset) {
    let lo = 0, hi = toks.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (toks[mid].end <= offset) lo = mid + 1; else hi = mid; }
    return lo;
  }

  return { lex, string: str, nextSig, indexAt, isIdStart, isIdChar, isDigit };
})();

if (typeof module !== 'undefined') module.exports = { HDLLanguage, Keywords, Lexer };
