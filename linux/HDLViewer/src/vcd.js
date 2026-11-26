// VCD parser. Runs inside a Web Worker (see parse-worker.js).
// Value codes for 1-bit signals: 0 → '0', 1 → '1', 2 → 'x', 3 → 'z'.

'use strict';

const BIT_0 = 0, BIT_1 = 1, BIT_X = 2, BIT_Z = 3;

class TraceBuilder {
  constructor(width, type) {
    this.width = Math.max(1, width);
    this.type = type; // 'bit' | 'vec' | 'real' | 'str'
    this.n = 0;
    this.times = new Float64Array(64);
    if (type === 'bit') this.bits = new Uint8Array(64);
    else this.values = [];
  }

  grow() {
    const cap = this.times.length * 2;
    const t = new Float64Array(cap); t.set(this.times); this.times = t;
    if (this.bits) { const b = new Uint8Array(cap); b.set(this.bits); this.bits = b; }
  }

  pushBit(t, v) {
    const n = this.n;
    if (n > 0) {
      if (this.times[n - 1] === t) {
        if (n >= 2 && this.bits[n - 2] === v) this.n--; else this.bits[n - 1] = v;
        return;
      }
      if (this.bits[n - 1] === v) return;
    }
    if (n === this.times.length) this.grow();
    this.times[n] = t; this.bits[n] = v; this.n = n + 1;
  }

  pushValue(t, v) {
    const n = this.n;
    if (n > 0) {
      if (this.times[n - 1] === t) {
        if (n >= 2 && this.values[n - 2] === v) { this.n--; this.values.pop(); } else this.values[n - 1] = v;
        return;
      }
      if (this.values[n - 1] === v) return;
    }
    if (n === this.times.length) this.grow();
    this.times[n] = t; this.values.push(v); this.n = n + 1;
  }

  finish() {
    const out = { width: this.width, type: this.type, n: this.n, times: this.times.slice(0, this.n) };
    if (this.bits) out.bits = this.bits.slice(0, this.n); else out.values = this.values;
    return out;
  }
}

function parseTimescale(text) {
  const t = text.trim().toLowerCase();
  const m = /^([\d.]+)\s*([a-zµ]*)$/.exec(t);
  const mag = m ? parseFloat(m[1]) || 1 : 1;
  const unit = m ? m[2] : 'ns';
  const exps = { s: 0, ms: -3, us: -6, 'µs': -6, ns: -9, ps: -12, fs: -15 };
  return { magnitude: mag, exponent: unit in exps ? exps[unit] : -9 };
}

function parseVCD(buf, onProgress) {
  const n = buf.length;
  let p = 0;

  const isSpace = (c) => c === 32 || c === 10 || c === 13 || c === 9 || c === 12;
  let ts = 0, te = 0; // current token [ts, te)

  function token() {
    while (p < n && isSpace(buf[p])) p++;
    if (p >= n) return false;
    ts = p;
    while (p < n && !isSpace(buf[p])) p++;
    te = p;
    return true;
  }
  function str(a, b) {
    let s = '';
    for (let i = a; i < b; i += 4096) s += String.fromCharCode.apply(null, buf.subarray(i, Math.min(b, i + 4096)));
    return s;
  }
  function isEnd() {
    return te - ts === 4 && buf[ts] === 36 && buf[ts + 1] === 101 && buf[ts + 2] === 110 && buf[ts + 3] === 100;
  }
  function tokensUntilEnd() {
    const out = [];
    while (token()) { if (isEnd()) break; out.push(str(ts, te)); }
    return out;
  }
  function skipUntilEnd() { while (token()) if (isEnd()) break; }

  // Identifier codes up to 6 bytes are packed into a number for fast lookup.
  const shortMap = new Map();
  const longMap = new Map();
  function keyOf(a, b) {
    if (b - a > 6) return null;
    let k = 0;
    for (let i = a; i < b; i++) k = k * 256 + buf[i];
    return k;
  }
  function keyOfString(s) {
    if (s.length > 6) return null;
    let k = 0;
    for (let i = 0; i < s.length; i++) k = k * 256 + (s.charCodeAt(i) & 255);
    return k;
  }
  function traceAt(a, b) {
    const k = keyOf(a, b);
    return k !== null ? shortMap.get(k) : longMap.get(str(a, b));
  }

  // ---- Header ----
  let scopeId = 0;
  const root = { id: 0, name: '', kind: 'root', path: '', children: [], vars: [] };
  const stack = [root];
  const vars = [];
  const builders = [];
  let timescale = { magnitude: 1, exponent: -9 };

  header: while (token()) {
    const kw = str(ts, te);
    switch (kw) {
      case '$scope': {
        const t = tokensUntilEnd();
        const parent = stack[stack.length - 1];
        const name = t[1] || 'unnamed';
        const s = { id: ++scopeId, name, kind: t[0] || 'module',
          path: parent.path ? parent.path + '.' + name : name, children: [], vars: [] };
        parent.children.push(s);
        stack.push(s);
        break;
      }
      case '$upscope':
        skipUntilEnd();
        if (stack.length > 1) stack.pop();
        break;
      case '$var': {
        const t = tokensUntilEnd();
        if (t.length < 4) break;
        const kind = t[0], width = parseInt(t[1], 10) || 1, code = t[2];
        let name = t[3];
        let range = t.length > 4 ? t.slice(4).join('') : '';
        if (!range && !name.startsWith('\\') && name.endsWith(']') && name.includes('[')) {
          const br = name.indexOf('[');
          range = name.slice(br); name = name.slice(0, br);
        }
        const type = (kind === 'real' || kind === 'realtime' || kind === 'shortreal') ? 'real'
          : kind === 'string' ? 'str' : width === 1 ? 'bit' : 'vec';
        const k = keyOfString(code);
        let b = k !== null ? shortMap.get(k) : longMap.get(code);
        if (!b) {
          b = new TraceBuilder(width, type);
          b.index = builders.length;
          builders.push(b);
          if (k !== null) shortMap.set(k, b); else longMap.set(code, b);
        }
        const scope = stack[stack.length - 1];
        const v = { id: vars.length, name, range, kind, width, scopePath: scope.path, trace: b.index };
        v.fullPath = (scope.path ? scope.path + '.' : '') + name + range;
        scope.vars.push(v.id);
        vars.push(v);
        break;
      }
      case '$timescale':
        timescale = parseTimescale(tokensUntilEnd().join(''));
        break;
      case '$enddefinitions':
        skipUntilEnd();
        break header;
      default:
        if (kw.charCodeAt(0) === 36) skipUntilEnd();
    }
  }

  if (vars.length === 0) throw new Error('No signals were found. Is this a VCD file?');

  // ---- Value changes ----
  let time = 0, firstTime = -1, maxTime = 0, lastReport = p;
  const bytes = [];

  while (token()) {
    const c = buf[ts];
    if (c === 35) { // '#'
      let v = 0;
      for (let i = ts + 1; i < te; i++) {
        const d = buf[i] - 48;
        if (d < 0 || d > 9) break;
        v = v * 10 + d;
      }
      time = v;
      if (firstTime < 0) firstTime = v;
      if (v > maxTime) maxTime = v;
      if (onProgress && p - lastReport > 8000000) { onProgress(p / n); lastReport = p; }
      continue;
    }
    if (c === 98 || c === 66) { // 'b'
      const vs = ts + 1, ve = te;
      if (!token()) break;
      const b = traceAt(ts, te);
      if (!b) continue;
      if (b.type === 'bit') {
        b.pushBit(time, bitCode(buf[ve - 1]));
        continue;
      }
      b.pushValue(time, vectorValue(vs, ve, b.width));
      continue;
    }
    if (c === 114 || c === 82 || c === 115 || c === 83) { // 'r' / 's'
      const vs = ts + 1, ve = te;
      if (!token()) break;
      const b = traceAt(ts, te);
      if (b) b.pushValue(time, str(vs, ve));
      continue;
    }
    if (c === 36) { // '$'
      if (te - ts === 8 && str(ts, te) === '$comment') skipUntilEnd();
      continue;
    }
    // scalar: 0 1 x z u w - l h (any case)
    if (te - ts >= 2) {
      const b = traceAt(ts + 1, te);
      if (!b) continue;
      const code = bitCode(c);
      if (b.type === 'bit') b.pushBit(time, code);
      else b.pushValue(time, vectorValue(ts, ts + 1, b.width));
    }
  }

  function bitCode(c) {
    switch (c | 32) {
      case 48: case 108: return BIT_0; // 0 l
      case 49: case 104: return BIT_1; // 1 h
      case 122: return BIT_Z;          // z
      default: return BIT_X;
    }
  }

  function vectorValue(a, b, width) {
    // Fast path: full width, plain binary.
    if (b - a === width) {
      let plain = true;
      for (let i = a; i < b; i++) { const ch = buf[i]; if (ch !== 48 && ch !== 49) { plain = false; break; } }
      if (plain) return str(a, b);
    }
    bytes.length = 0;
    for (let i = a; i < b; i++) {
      const ch = buf[i] | 32;
      if (ch === 48 || ch === 49 || ch === 120 || ch === 122) bytes.push(ch);
      else if (ch === 104) bytes.push(49);
      else if (ch === 108) bytes.push(48);
      else bytes.push(120);
    }
    if (bytes.length === 0) bytes.push(120);
    let s = String.fromCharCode.apply(null, bytes);
    if (s.length < width) {
      const f = s.charCodeAt(0);
      const pad = (f === 120 || f === 122) ? s[0] : '0';
      s = pad.repeat(width - s.length) + s;
    }
    return s;
  }

  if (onProgress) onProgress(1);
  return {
    root, vars, timescale,
    traces: builders.map((b) => b.finish()),
    startTime: firstTime < 0 ? 0 : firstTime,
    endTime: maxTime,
  };
}

if (typeof module !== 'undefined') module.exports = { parseVCD };
