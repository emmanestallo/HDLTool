'use strict';
/* global Lexer, HDLLanguage */
// Block structure: matching begin/end, brackets, and indentation rules. Port of Structure.swift.

const Structure = (() => {
  const verilogOpeners = {
    begin: ['end'], case: ['endcase'], casez: ['endcase'], casex: ['endcase'], randcase: ['endcase'],
    module: ['endmodule'], macromodule: ['endmodule'], function: ['endfunction'], task: ['endtask'],
    fork: ['join', 'join_any', 'join_none'], generate: ['endgenerate'], class: ['endclass'],
    interface: ['endinterface'], package: ['endpackage'], program: ['endprogram'],
    covergroup: ['endgroup'], property: ['endproperty'], sequence: ['endsequence'],
    clocking: ['endclocking'], specify: ['endspecify'], primitive: ['endprimitive'],
    table: ['endtable'], config: ['endconfig'], checker: ['endchecker'],
  };
  const verilogClosers = new Set(Object.values(verilogOpeners).flat());
  const headerOpeners = new Set([
    'module', 'macromodule', 'function', 'task', 'class', 'interface', 'package', 'program', 'checker',
    'primitive', 'covergroup', 'property', 'sequence', 'clocking', 'config',
  ]);
  const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

  function word(u, t) {
    return (t.kind === 'keyword' || t.kind === 'control' || t.kind === 'type') ? Lexer.string(u, t) : null;
  }

  function isRealOpener(w, sig, k, u) {
    const prev = k > 0 ? (word(u, sig[k - 1]) || '') : '';
    switch (w) {
      case 'fork': return prev !== 'wait' && prev !== 'disable';
      case 'class': return prev !== 'typedef';
      case 'interface': return prev !== 'virtual' && !(k + 1 < sig.length && sig[k + 1].kind === 'keyword' && Lexer.string(u, sig[k + 1]) === 'class');
      case 'property': case 'sequence': return !['assert', 'assume', 'cover', 'expect', 'restrict'].includes(prev);
      case 'function': case 'task': {
        let j = k - 1;
        while (j >= 0 && sig[j].line >= sig[k].line - 1) {
          if (sig[j].kind === 'op' && u.charCodeAt(sig[j].start) === 59) break;
          const pw = word(u, sig[j]);
          if (pw && ['extern', 'pure', 'import', 'export'].includes(pw)) return false;
          if (sig[j].kind === 'string') return false;
          j--;
        }
        return true;
      }
      default: return true;
    }
  }

  // Pairs of matching tokens (indices into tokens), both directions. Returns a Map.
  function pairs(tokens, u, language) {
    const map = new Map();
    const bracketStack = [];
    const blockStack = [];
    const sigIdx = [];
    tokens.forEach((t, i) => { if (t.kind !== 'comment' && t.kind !== 'attribute' && t.kind !== 'string') sigIdx.push(i); });
    const sig = sigIdx.map((i) => tokens[i]);
    const verilog = HDLLanguage.isVerilogFamily(language);
    for (let k = 0; k < sig.length; k++) {
      const t = sig[k], ti = sigIdx[k];
      if (t.kind === 'op') {
        const c = u.charCodeAt(t.start);
        if (c === 40 || c === 91 || c === 123) bracketStack.push([ti, c === 40 ? 41 : (c === 91 ? 93 : 125)]);
        else if (c === 41 || c === 93 || c === 125) {
          let idx = -1;
          for (let q = bracketStack.length - 1; q >= 0; q--) if (bracketStack[q][1] === c) { idx = q; break; }
          if (idx >= 0) { map.set(ti, bracketStack[idx][0]); map.set(bracketStack[idx][0], ti); bracketStack.length = idx; }
        }
        continue;
      }
      if (!verilog) continue;
      const w = word(u, t);
      if (!w) continue;
      if (has(verilogOpeners, w)) {
        if (isRealOpener(w, sig, k, u)) blockStack.push([ti, verilogOpeners[w]]);
      } else if (verilogClosers.has(w)) {
        let idx = -1;
        for (let q = blockStack.length - 1; q >= 0; q--) if (blockStack[q][1].includes(w)) { idx = q; break; }
        if (idx >= 0) { map.set(ti, blockStack[idx][0]); map.set(blockStack[idx][0], ti); blockStack.length = idx; }
      }
    }
    return map;
  }

  function lineStarts(u) {
    const starts = [0];
    for (let i = 0; i < u.length; i++) if (u.charCodeAt(i) === 10) starts.push(i + 1);
    return starts;
  }

  // Indentation level for every line (null = leave unchanged). Verilog/SystemVerilog only.
  function indentLevels(u, tokens, language) {
    const lineCount = lineStarts(u).length;
    const levels = new Array(lineCount).fill(null);
    if (!HDLLanguage.isVerilogFamily(language)) return levels;
    const pairMap = pairs(tokens, u, language);
    let depth = 0, paren = 0, pendingHeader = false, extra = 0, pendingExtra = null;
    const blockExtra = [];
    const ifLevel = new Map();
    const last = (a) => (a.length ? a[a.length - 1] : 0);

    const prot = new Set();
    for (const t of tokens) {
      if ((t.kind === 'comment' || t.kind === 'string') && t.length > 0) {
        let endLine = t.line;
        for (let k = 0; k < t.length; k++) if (u.charCodeAt(t.start + k) === 10) endLine++;
        for (let l = t.line + 1; l <= endLine; l++) prot.add(l);
      }
    }
    const lineTokens = Array.from({ length: lineCount }, () => []);
    tokens.forEach((t, i) => { if (t.line < lineCount) lineTokens[t.line].push(i); });

    for (let line = 0; line < lineCount; line++) {
      const idxs = lineTokens[line].filter((i) => tokens[i].kind !== 'comment' || tokens[i].line === line);
      if (pendingExtra != null) { extra = pendingExtra; pendingExtra = null; }
      if (prot.has(line)) continue;
      if (!idxs.length) { levels[line] = 0; continue; }
      const firstIdx = idxs[0];
      const first = tokens[firstIdx];
      const base = depth + paren;
      const fw = word(u, first) || '';
      const underHead = extra > last(blockExtra);
      let lineLevel = base + extra;
      if (first.kind === 'op' && [41, 93, 125].includes(u.charCodeAt(first.start))) lineLevel -= 1;
      else if (verilogClosers.has(fw) && pairMap.has(firstIdx)) lineLevel = depth - 1 + paren + last(blockExtra);
      else if ((fw === 'begin' || fw === 'fork') && underHead) lineLevel -= 1;
      else if (fw === 'else' && ifLevel.has(depth)) lineLevel = ifLevel.get(depth);
      if (first.kind === 'directive' && ['`ifdef', '`ifndef', '`else', '`elsif', '`endif', '`define', '`include', '`timescale', '`default_nettype', '`undef', '`resetall'].includes(Lexer.string(u, first))) lineLevel = 0;
      lineLevel = Math.max(0, lineLevel);
      levels[line] = lineLevel;
      if (fw === 'if' || (fw === 'else' && idxs.length > 1 && word(u, tokens[idxs[1]]) === 'if')) ifLevel.set(depth, lineLevel);

      let lastSig = null;
      for (const ti of idxs) {
        const t = tokens[ti];
        if (t.kind === 'comment' || t.kind === 'attribute') continue;
        lastSig = ti;
        if (t.kind === 'op') {
          const c = u.charCodeAt(t.start);
          if (c === 40 || c === 91 || c === 123) paren++;
          else if (c === 41 || c === 93 || c === 125) paren = Math.max(0, paren - 1);
          else if (c === 59 && paren === 0) {
            if (pendingHeader) { blockExtra.push(Math.max(0, lineLevel - depth)); depth++; pendingHeader = false; }
            extra = last(blockExtra);
          }
          continue;
        }
        const w = word(u, t);
        if (!w) continue;
        if (has(verilogOpeners, w) && (pairMap.has(ti) || w === 'begin' || w === 'fork' || w.startsWith('case'))) {
          if (headerOpeners.has(w)) pendingHeader = true;
          else {
            const e = Math.max(0, lineLevel - (depth + paren));
            blockExtra.push(e); depth++; extra = e;
          }
        } else if (verilogClosers.has(w) && pairMap.has(ti)) {
          depth = Math.max(0, depth - 1);
          blockExtra.pop();
          extra = last(blockExtra);
        }
      }
      if (lastSig != null && paren === 0) {
        const t = tokens[lastSig];
        const w = word(u, t) || '';
        let head = false;
        if (['else', 'always', 'initial', 'forever', 'always_comb', 'always_latch', 'final', 'do'].includes(w)) head = true;
        else if (t.kind === 'op' && u.charCodeAt(t.start) === 41 && pairMap.has(lastSig) && pairMap.get(lastSig) > 0) {
          let p = pairMap.get(lastSig) - 1;
          while (p >= 0 && tokens[p].kind === 'comment') p--;
          if (p >= 0) {
            const pt = tokens[p];
            const pw = word(u, pt) || (pt.kind === 'op' && u.charCodeAt(pt.start) === 64 ? '@' : '');
            if (['if', 'for', 'while', 'repeat', 'foreach', '@'].includes(pw)) head = true;
          }
        } else if (t.kind === 'op' && u.charCodeAt(t.start) === 42 && lastSig > 0 && tokens[lastSig - 1].kind === 'op' && u.charCodeAt(tokens[lastSig - 1].start) === 64) {
          head = true;
        }
        if (head) pendingExtra = lineLevel - (depth + paren) + 1;
      }
    }
    return levels;
  }

  return { verilogOpeners, verilogClosers, headerOpeners, word, pairs, lineStarts, indentLevels };
})();

// Text helpers.
const TextUtil = {
  leadingWhitespace(s) { const m = /^[ \t]*/.exec(s); return m ? m[0] : ''; },
  indentWidth(s, tabSize) {
    let w = 0;
    for (const c of s) { if (c === '\t') w += tabSize - (w % tabSize); else if (c === ' ') w++; else break; }
    return w;
  },
  makeIndent(width, tabSize, useSpaces) {
    if (width <= 0) return '';
    if (useSpaces) return ' '.repeat(width);
    return '\t'.repeat(Math.floor(width / tabSize)) + ' '.repeat(width % tabSize);
  },
  stripComment(line, language) {
    const marker = HDLLanguage.lineComment(language);
    if (!marker) return line;
    let inString = false;
    for (let i = 0; i < line.length; i++) {
      if (line[i] === '"') inString = !inString;
      if (!inString && i + 1 < line.length && line[i] === marker[0] && line[i + 1] === marker[1]) return line.slice(0, i);
      if (!inString && HDLLanguage.isVerilogFamily(language) && i + 1 < line.length && line[i] === '/' && line[i + 1] === '*') return line.slice(0, i);
    }
    return line;
  },
  lastWord(s) { const m = /[A-Za-z0-9_]*$/.exec(s.trim()); return m ? m[0] : ''; },
  firstWord(s) { const m = /^[A-Za-z0-9_`]*/.exec(s.trim()); return m ? m[0] : ''; },
  increasesIndent(code, language) {
    const t = code.trim();
    if (!t) return false;
    const last = t[t.length - 1];
    if ('([{'.includes(last)) return true;
    if (language === 'vhdl') {
      const lw = TextUtil.lastWord(t).toLowerCase();
      if (['is', 'begin', 'then', 'else', 'loop', 'generate', 'record', 'process', 'protected', 'units'].includes(lw) && !t.endsWith(';')) return true;
      if (t.endsWith('=>') && t.toLowerCase().startsWith('when')) return true;
      const lower = t.toLowerCase();
      if (t.endsWith(')') && (lower.startsWith('process') || lower.includes(': process') || lower.includes(':process'))) return true;
      return false;
    }
    const lw = TextUtil.lastWord(t), fw = TextUtil.firstWord(t);
    if (['begin', 'fork', 'generate', 'specify', 'else', 'do', 'forever', 'initial', 'always', 'always_comb', 'always_latch', 'final', 'table'].includes(lw) && last !== ';') return true;
    if (['case', 'casez', 'casex', 'randcase'].includes(fw) && last === ')') return true;
    if ((fw === 'unique' || fw === 'priority') && t.includes('case') && last === ')') return true;
    if (Structure.headerOpeners.has(fw) && last === ';' && fw !== 'property' && fw !== 'sequence') return true;
    if (['virtual', 'static', 'automatic', 'pure', 'extern'].includes(fw) && last === ';' && (t.includes('class ') || t.includes('function ') || t.includes('task ')) && !t.includes('extern') && !t.includes('pure')) return true;
    if (last === ')' && ['if', 'for', 'while', 'repeat', 'foreach', 'always', 'always_ff', 'always_latch', 'else'].includes(fw)) return true;
    if (last === ')' && t.startsWith('end else if')) return true;
    if (fw === 'always' && t.endsWith('@*')) return true;
    return false;
  },
  isSingleStatementHead(code) {
    const t = code.trim();
    if (!t) return false;
    const last = t[t.length - 1];
    if (last === ';' || t.endsWith('begin')) return false;
    const fw = TextUtil.firstWord(t);
    if (['if', 'for', 'while', 'repeat', 'foreach', 'always', 'always_ff', 'always_latch', 'always_comb', 'initial', 'forever', 'final'].includes(fw)) return true;
    if (fw === 'else' || t.startsWith('end else')) return true;
    return false;
  },
};

if (typeof module !== 'undefined') module.exports = { Structure, TextUtil };
