'use strict';

// ---------- Time ----------

const UNITS = [[0, 's'], [-3, 'ms'], [-6, 'µs'], [-9, 'ns'], [-12, 'ps'], [-15, 'fs']];

function unitName(e) { const u = UNITS.find((u) => u[0] === e); return u ? u[1] : `e${e} s`; }

class TimeScale {
  constructor({ magnitude, exponent }) { this.magnitude = magnitude; this.exponent = exponent; }
  toString() { return `${this.magnitude} ${unitName(this.exponent)}`; }
  fs(t) { return t * this.magnitude * Math.pow(10, this.exponent + 15); }
  seconds(t) { return t * this.magnitude * Math.pow(10, this.exponent); }
  get baseUnit() { return Math.min(0, Math.max(-15, Math.floor(this.exponent / 3) * 3)); }
  bestUnit(t) {
    const f = Math.abs(this.fs(t));
    if (f === 0) return this.baseUnit;
    for (const [e] of UNITS) if (f >= Math.pow(10, e + 15)) return e;
    return -15;
  }
  format(t, unit, decimals) {
    const u = unit ?? this.bestUnit(t);
    const v = this.fs(t) / Math.pow(10, u + 15);
    const s = decimals != null ? v.toFixed(decimals) : trimZeros(v.toFixed(3));
    return `${s} ${unitName(u)}`;
  }
}

function trimZeros(s) {
  if (!s.includes('.')) return s;
  s = s.replace(/0+$/, '');
  return s.endsWith('.') ? s.slice(0, -1) : s;
}

function frequency(periodSeconds) {
  if (!(periodSeconds > 0)) return '';
  const f = 1 / periodSeconds;
  const [v, u] = f >= 1e9 ? [f / 1e9, 'GHz'] : f >= 1e6 ? [f / 1e6, 'MHz'] : f >= 1e3 ? [f / 1e3, 'kHz'] : [f, 'Hz'];
  return `${trimZeros(v.toFixed(3))} ${u}`;
}

function computeTicks(start, tpp, width, ts) {
  const raw = Math.max(110 * tpp, 1e-9);
  const p = Math.pow(10, Math.floor(Math.log10(raw)));
  let step = p * 10;
  for (const m of [1, 2, 5, 10]) if (m * p >= raw) { step = m * p; break; }
  step = Math.max(step, 1);
  const minor = step >= 5 ? step / 5 : step >= 2 ? step / 2 : null;
  const unit = ts.bestUnit(Math.max(Math.abs(start), Math.abs(start + width * tpp)));
  const stepInUnit = ts.fs(step) / Math.pow(10, unit + 15);
  const decimals = stepInUnit >= 1 ? 0 : Math.min(6, Math.ceil(-Math.log10(stepInUnit) - 1e-9));
  return { step, minor, unit, decimals };
}

// ---------- Values ----------

const RADIXES = [
  ['hex', 'Hexadecimal'], ['binary', 'Binary'], ['octal', 'Octal'],
  ['unsigned', 'Unsigned Decimal'], ['signed', 'Signed Decimal'], ['ascii', 'ASCII'],
];
const BIT_CHARS = ['0', '1', 'x', 'z'];
const HEX = '0123456789abcdef';

function isUnknown(v) { return /[xX]/.test(v); }
function isHighZ(v) { return v.length > 0 && /^z+$/.test(v); }

function formatValue(v, trace, radix) {
  if (trace.type === 'real') { const d = parseFloat(v); return isNaN(d) ? v : formatReal(d); }
  if (trace.type === 'str' || trace.type === 'bit') return v;
  switch (radix) {
    case 'binary': return v;
    case 'octal': return group(v, 3);
    case 'unsigned': return decimal(v, false);
    case 'signed': return decimal(v, true);
    case 'ascii': return ascii(v);
    default: return group(v, 4);
  }
}

function formatReal(d) {
  if (d === 0) return '0';
  const a = Math.abs(d);
  if (a >= 1e-4 && a < 1e6) return String(parseFloat(d.toPrecision(6)));
  return d.toExponential(5).replace(/\.?0+e/, 'e');
}

function group(bits, size) {
  let out = '';
  for (let end = bits.length; end > 0; end -= size) {
    const start = Math.max(0, end - size);
    let val = 0, xs = 0, zs = 0;
    for (let i = start; i < end; i++) {
      val <<= 1;
      const c = bits.charCodeAt(i);
      if (c === 49) val |= 1; else if (c === 122) zs++; else if (c !== 48) xs++;
    }
    const cnt = end - start;
    out = (xs === cnt ? 'x' : zs === cnt ? 'z' : xs ? 'X' : zs ? 'Z' : HEX[val]) + out;
  }
  return out;
}

function decimal(bits, signed) {
  if (/[^01]/.test(bits)) return /^z+$/.test(bits) ? 'z' : 'x';
  const n = BigInt('0b' + bits);
  if (signed && bits[0] === '1') return (n - (1n << BigInt(bits.length))).toString();
  return n.toString();
}

function ascii(bits) {
  const pad = (8 - (bits.length % 8)) % 8;
  const b = '0'.repeat(pad) + bits;
  let out = '', started = false;
  for (let i = 0; i < b.length; i += 8) {
    const byte = b.slice(i, i + 8);
    if (/[^01]/.test(byte)) { out += '·'; started = true; continue; }
    const v = parseInt(byte, 2);
    if (v === 0 && !started) continue;
    started = true;
    out += v >= 32 && v < 127 ? String.fromCharCode(v) : '·';
  }
  return `"${out}"`;
}

// ---------- Trace lookups ----------

function lastIndexAtOrBefore(trace, t) {
  let lo = 0, hi = trace.n;
  const times = trace.times;
  while (lo < hi) { const m = (lo + hi) >> 1; if (times[m] <= t) lo = m + 1; else hi = m; }
  return lo - 1; // -1 if none
}

function firstIndexAtOrAfter(trace, t) {
  let lo = 0, hi = trace.n;
  const times = trace.times;
  while (lo < hi) { const m = (lo + hi) >> 1; if (times[m] < t) lo = m + 1; else hi = m; }
  return lo;
}

function rawValue(trace, i) { return trace.bits ? BIT_CHARS[trace.bits[i]] : trace.values[i]; }

function valueAt(trace, t) {
  const i = lastIndexAtOrBefore(trace, t);
  return i < 0 ? null : rawValue(trace, i);
}

// ---------- Analog display (port of the Mac app's Analog enum) ----------

const DISPLAY_MODES = [
  ['digital', 'Digital'],
  ['analogUnsigned', 'Analog Unsigned  (code / 2ᴺ  →  0 … 1)'],
  ['analogSigned', 'Analog Signed  (code / 2ᴺ⁻¹  →  −1 … +1)'],
  ['analogAuto', 'Analog  (auto range)'],
];
const DISPLAY_SHORT = { digital: 'digital', analogUnsigned: 'analog · unsigned, FS = 1', analogSigned: 'analog · signed, FS = ±1', analogAuto: 'analog · auto range' };
const INTERPOLATIONS = [['step', 'Step  (sample & hold)'], ['linear', 'Linear']];
const ROW_HEIGHTS = [1, 2, 3, 4, 6, 8, 12];

// Analog modes a trace supports.
function analogModes(tr) {
  if (tr.type === 'real') return ['analogAuto'];
  if (tr.type === 'bit' || tr.type === 'str') return [];
  return ['analogUnsigned', 'analogSigned', 'analogAuto'];
}

// Stored value → analog level, or null for X / Z.
// Unsigned: code / 2^N in [0, 1).  Signed (two's complement): code / 2^(N-1) in [-1, 1).
function analogLevel(v, tr, mode) {
  if (tr.type === 'real') { const d = parseFloat(v); return isNaN(d) ? null : d; }
  if (tr.type === 'str' || v == null) return null;
  const n = v.length;
  if (!n) return null;
  let acc = 0;
  for (let i = 0; i < n; i++) {
    const c = v.charCodeAt(i);
    if (c === 48) acc *= 2; else if (c === 49) acc = acc * 2 + 1; else return null;
  }
  if (mode === 'analogSigned') { if (v.charCodeAt(0) === 49) acc -= Math.pow(2, n); return acc / Math.pow(2, n - 1); }
  if (mode === 'analogAuto') return acc;
  return acc / Math.pow(2, n);
}

// Min and max level over the whole trace (for auto range), cached on the trace.
function levelRange(tr, mode) {
  if (tr._levelRange) return tr._levelRange;
  let lo = Infinity, hi = -Infinity;
  for (let i = 0; i < tr.n; i++) {
    const x = analogLevel(rawValue(tr, i), tr, mode);
    if (x != null) { if (x < lo) lo = x; if (x > hi) hi = x; }
  }
  tr._levelRange = isFinite(lo) ? { lo, hi } : { lo: 0, hi: 1 };
  return tr._levelRange;
}

function analogRange(tr, mode) {
  if (mode === 'analogSigned') return { lo: -1, hi: 1 };
  if (mode !== 'analogAuto') return { lo: 0, hi: 1 };
  const r = levelRange(tr, mode);
  if (r.hi - r.lo < 1e-12) return { lo: r.lo - 1, hi: r.hi + 1 };
  const pad = (r.hi - r.lo) * 0.05;
  return { lo: r.lo - pad, hi: r.hi + pad };
}

// Decimal places that show one LSB for an N-bit full-scale value.
function analogDecimals(width) { return Math.min(9, Math.max(3, Math.ceil(width * Math.log10(2)))); }

// C printf %g (and %+g, %.4g).
function fmtG(x, prec = 6, plus = false) {
  const sign = plus && x >= 0 ? '+' : '';
  if (x === 0) return sign + '0';
  if (!isFinite(x)) return String(x);
  const e = Math.floor(Math.log10(Math.abs(Number(x.toPrecision(prec)))));
  let s;
  if (e < -4 || e >= prec) {
    const [m, ex] = x.toExponential(prec - 1).split('e');
    const mm = m.includes('.') ? m.replace(/0+$/, '').replace(/\.$/, '') : m;
    const exn = parseInt(ex, 10);
    s = mm + 'e' + (exn < 0 ? '-' : '+') + String(Math.abs(exn)).padStart(2, '0');
  } else {
    s = x.toFixed(Math.max(0, prec - 1 - e));
    if (s.includes('.')) s = s.replace(/0+$/, '').replace(/\.$/, '');
  }
  return sign + s;
}

function formatAnalog(level, tr, mode) {
  if (mode === 'analogSigned') return (level >= 0 ? '+' : '') + level.toFixed(analogDecimals(tr.width - 1));
  if (mode === 'analogUnsigned') return level.toFixed(analogDecimals(tr.width));
  return fmtG(level);
}
