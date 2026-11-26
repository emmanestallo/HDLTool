'use strict';
// HDLPhy schematic worker: yosys JSON -> SVG with netlistsvg. Runs as a plain Node process
// (Electron with ELECTRON_RUN_AS_NODE=1) so a large layout cannot freeze the window and can be stopped.
//
// stdin:  { json, view: 'rtl' | 'gate', module, skin, maxCells, force }
// stdout: { ok, svg, module, modules: [{ name, cells, top }], cells, cellInfo, error, tooBig }
const fs = require('fs');

const netlistsvg = require('netlistsvg');

const PREFIX = /^sky130_fd_sc_\w+?__/;

// SKY130 cell (base name without the drive strength) -> skin symbol and pin renames.
const GATES = {
  inv: ['$_NOT_', {}], clkinv: ['$_NOT_', {}], clkinvlp: ['$_NOT_', {}],
  buf: ['$hd_buf', { X: 'Y' }], clkbuf: ['$hd_buf', { X: 'Y' }], dlygate4sd1: ['$hd_buf', { X: 'Y' }],
  dlygate4sd2: ['$hd_buf', { X: 'Y' }], dlygate4sd3: ['$hd_buf', { X: 'Y' }], dlymetal6s2s: ['$hd_buf', { X: 'Y' }],
  dlymetal6s4s: ['$hd_buf', { X: 'Y' }], dlymetal6s6s: ['$hd_buf', { X: 'Y' }], clkdlybuf4s15: ['$hd_buf', { X: 'Y' }],
  clkdlybuf4s18: ['$hd_buf', { X: 'Y' }], clkdlybuf4s25: ['$hd_buf', { X: 'Y' }], clkdlybuf4s50: ['$hd_buf', { X: 'Y' }],
  and2: ['$_AND_', { X: 'Y' }], and3: ['$hd_and3', { X: 'Y' }], and4: ['$hd_and4', { X: 'Y' }],
  nand2: ['$_NAND_', {}], nand3: ['$hd_nand3', {}], nand4: ['$hd_nand4', {}],
  or2: ['$_OR_', { X: 'Y' }], or3: ['$hd_or3', { X: 'Y' }], or4: ['$hd_or4', { X: 'Y' }],
  nor2: ['$_NOR_', {}], nor3: ['$hd_nor3', {}], nor4: ['$hd_nor4', {}],
  xor2: ['$_XOR_', { X: 'Y' }], xnor2: ['$_XNOR_', {}],
  mux2: ['$_MUX_', { A0: 'A', A1: 'B', X: 'Y' }],
  dfxtp: ['$hd_dff', {}], dfrtp: ['$hd_dffr', {}], dfstp: ['$hd_dffs', {}],
};

function shortName(type) { return type.replace(PREFIX, ''); }

// $paramod\counter\WIDTH=s32'00000000000000000000000000001000 -> counter (WIDTH=8)
function prettyModule(name) {
  const m = /^\$paramod\\([^\\]+)\\(.*)$/.exec(name);
  if (!m) return name.replace(/^\\/, '');
  const params = m[2].split('\\').map((p) => {
    const q = /^(\w+)=(?:s?(\d+))'([01xz]+)$/.exec(p);
    if (!q) return p;
    const bits = q[3];
    return `${q[1]}=${/^[01]+$/.test(bits) ? parseInt(bits, 2) : bits}`;
  });
  return `${m[1]} (${params.join(', ')})`;
}
function baseName(short) { const m = /^(.*?)_(\d+)$/.exec(short); return m ? m[1] : short; }

function mapGateCell(cell) {
  const short = shortName(cell.type);
  if (short === cell.type) return cell;               // not a standard cell (a submodule or a yosys cell)
  const g = GATES[baseName(short)];
  const attrs = Object.assign({}, cell.attributes, { celltype: short });
  if (!g) return Object.assign({}, cell, { type: short, attributes: attrs });
  const [type, ren] = g;
  const rename = (obj) => {
    const out = {};
    for (const [k, v] of Object.entries(obj || {})) out[ren[k] || k] = v;
    return out;
  };
  return Object.assign({}, cell, { type, attributes: attrs, connections: rename(cell.connections), port_directions: rename(cell.port_directions) });
}

function countCells(mod) { return Object.keys(mod.cells || {}).length; }

function main(req) {
  const netlist = JSON.parse(fs.readFileSync(req.json, 'utf8'));
  const mods = netlist.modules || {};
  const names = Object.keys(mods).filter((n) => !(mods[n].attributes && mods[n].attributes.blackbox));
  const isTop = (n) => mods[n].attributes && Number(mods[n].attributes.top) === 1;
  const list = names.map((n) => ({ name: n, label: prettyModule(n), cells: countCells(mods[n]), top: !!isTop(n) }));
  let name = req.module && mods[req.module] ? req.module : (names.find(isTop) || names[0]);
  if (!name) return { ok: false, error: 'The netlist has no modules.', modules: list };
  const mod = mods[name];
  const cells = countCells(mod);
  const maxCells = req.maxCells || 2500;
  if (cells > maxCells && !req.force) {
    return { ok: false, tooBig: true, cells, module: name, modules: list,
      error: `${name} has ${cells} cells; drawing more than ${maxCells} can take minutes.` };
  }
  // A netlist holding only the chosen module (plus nothing else: submodules stay boxes).
  const one = Object.assign({}, mod, { attributes: Object.assign({}, mod.attributes, { top: '00000000000000000000000000000001' }) });
  const cellInfo = {};
  const out = {};
  for (const [k, c] of Object.entries(mod.cells || {})) {
    // submodule instances are drawn as boxes labelled with the (readable) module name
    const m = req.view === 'gate' ? mapGateCell(c) : (mods[c.type] ? Object.assign({}, c, { type: prettyModule(c.type) }) : c);
    out[k] = m;
    cellInfo[k] = { type: c.type, short: shortName(c.type), submodule: !!(mods[c.type] && !(mods[c.type].attributes || {}).blackbox),
      ports: Object.fromEntries(Object.entries(c.connections || {}).map(([p, bits]) => [p, { dir: (c.port_directions || {})[p] || '', bits }])) };
  }
  one.cells = out;
  const skin = fs.readFileSync(req.skin, 'utf8');
  return new Promise((resolve) => {
    netlistsvg.render(skin, { modules: { [name]: one } }, (err, svg) => {
      if (err) { resolve({ ok: false, error: String(err && err.message || err), modules: list, module: name }); return; }
      svg = svg.replace(/^<svg /, '<svg class="hdlphy-schem" ');
      resolve({ ok: true, svg, module: name, modules: list, cells, cellInfo });
    });
  });
}

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => { input += d; });
process.stdin.on('end', async () => {
  let res;
  try {
    res = await main(JSON.parse(input));
  } catch (e) {
    res = { ok: false, error: String(e && e.stack || e) };
  }
  process.stdout.write(JSON.stringify(res));
});

if (require.main !== module) module.exports = { mapGateCell, shortName, prettyModule };
