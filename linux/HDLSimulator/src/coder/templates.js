'use strict';
/* global symPorts, symParams, HDLLanguage */
// Generated code: instance templates, testbenches and new-file skeletons. Port of Templates.swift.

const Templates = (() => {
  const pad = (s, n) => (s.length >= n ? s : s + ' '.repeat(n - s.length));
  const maxLen = (arr) => arr.reduce((m, p) => Math.max(m, p.name.length), 0);

  function instance(m, language, unit = '    ', instName = null) {
    if (language === 'vhdl') return vhdlInstance(m, unit, instName);
    const params = symParams(m), ports = symPorts(m);
    const name = instName || `u_${m.name}`;
    let out = m.name;
    if (params.length) {
      const w = maxLen(params);
      out += ' #(\n' + params.map((p, i) => `${unit}.${pad(p.name, w)} (${pad(p.name, w)})` + (i < params.length - 1 ? ',' : '')).join('\n') + '\n)';
    }
    out += ` ${name} (\n`;
    const w = maxLen(ports);
    out += ports.map((p, i) => {
      const comment = p.detail ? `  // ${p.detail}` : '';
      return `${unit}.${pad(p.name, w)} (${pad(p.name, w)})` + (i < ports.length - 1 ? ',' : ' ') + comment;
    }).join('\n');
    out += '\n);';
    return out;
  }

  function vhdlInstance(m, unit, instName) {
    const generics = m.children.filter((c) => c.kind === 'param');
    const ports = m.children.filter((c) => c.kind === 'port');
    let out = `${instName || `u_${m.name}`} : entity work.${m.name}\n`;
    if (generics.length) {
      const w = maxLen(generics);
      out += `${unit}generic map (\n` + generics.map((g, i) => `${unit}${unit}${pad(g.name, w)} => ${g.name}` + (i < generics.length - 1 ? ',' : '')).join('\n') + `\n${unit})\n`;
    }
    const w = maxLen(ports);
    out += `${unit}port map (\n` + ports.map((p, i) => `${unit}${unit}${pad(p.name, w)} => ${p.name}` + (i < ports.length - 1 ? ',' : '')).join('\n') + `\n${unit});`;
    return out;
  }

  function isClock(n) {
    const l = n.toLowerCase();
    return l === 'clk' || l === 'clock' || l === 'i_clk' || l === 'clk_i' || (l.startsWith('clk_') && l.length <= 8) || l === 'aclk';
  }
  function resetPolarity(n) {
    const l = n.toLowerCase();
    if (['rst_n', 'rstn', 'resetn', 'reset_n', 'nrst', 'areset_n', 'aresetn', 'i_rst_n', 'rst_ni', 'rst_b'].includes(l)) return false;
    if (['rst', 'reset', 'areset', 'i_rst', 'rst_i', 'srst'].includes(l)) return true;
    return null;
  }

  function testbench(m, language, unit = '    ') {
    if (language === 'vhdl') return vhdlTestbench(m, unit);
    const sv = language === 'systemVerilog';
    const tb = `tb_${m.name}`;
    const ports = symPorts(m);
    const isIn = (p) => (p.dir || 'input') === 'input';
    const clocks = ports.filter((p) => isIn(p) && isClock(p.name));
    const resets = ports.filter((p) => isIn(p) && resetPolarity(p.name) != null);
    const inputs = ports.filter(isIn);
    const outputs = ports.filter((p) => (p.dir || '') !== 'input' && p.dir != null);
    let s = '`timescale 1ns/1ps\n\n';
    s += `module ${tb};\n\n`;
    const params = symParams(m);
    if (params.length) {
      s += `${unit}// Parameters\n`;
      for (const p of params) s += `${unit}localparam ${p.name} = ${p.value != null ? p.value : '0'};\n`;
      s += '\n';
    }
    const decl = (p, out) => {
      const kw = sv ? 'logic' : (out ? 'wire' : 'reg ');
      const dt = p.dataType || '';
      const signed = dt.includes('signed') && !dt.includes('unsigned') ? ' signed' : '';
      const r = p.range ? ` ${p.range}` : '';
      return `${unit}${kw}${signed}${r} ${p.name};`;
    };
    s += `${unit}// DUT inputs\n`;
    for (const p of inputs) s += decl(p, false) + '\n';
    if (outputs.length) {
      s += `\n${unit}// DUT outputs\n`;
      for (const p of outputs) s += decl(p, true) + '\n';
    }
    if (clocks.length) {
      s += `\n${unit}// Clock: 100 MHz\n`;
      for (const c of clocks) s += `${unit}initial ${c.name} = 1'b0;\n${unit}always #5 ${c.name} = ~${c.name};\n`;
    }
    s += `\n${unit}// Device under test\n`;
    s += instance(m, language, unit, 'dut').split('\n').map((l) => unit + l).join('\n');
    s += `\n\n${unit}initial begin\n`;
    const u2 = unit + unit;
    s += `${u2}$dumpfile("${tb}.vcd");\n`;
    s += `${u2}$dumpvars(0, ${tb});\n\n`;
    const others = inputs.filter((p) => !clocks.some((c) => c.name === p.name) && !resets.some((r) => r.name === p.name));
    if (others.length || resets.length) {
      s += `${u2}// Initial values\n`;
      for (const r of resets) s += `${u2}${r.name} = 1'b${resetPolarity(r.name) ? 1 : 0};\n`;
      for (const p of others) s += `${u2}${p.name} = ${sv ? "'0" : '0'};\n`;
      s += '\n';
    }
    if (clocks.length) {
      const clk = clocks[0];
      if (resets.length) {
        s += `${u2}// Release reset\n${u2}repeat (4) @(posedge ${clk.name});\n`;
        for (const r of resets) s += `${u2}${r.name} = 1'b${resetPolarity(r.name) ? 0 : 1};\n`;
        s += '\n';
      }
      s += `${u2}// Stimulus\n${u2}repeat (20) @(posedge ${clk.name});\n`;
    } else {
      if (resets.length) {
        s += `${u2}#20;\n`;
        for (const r of resets) s += `${u2}${r.name} = 1'b${resetPolarity(r.name) ? 0 : 1};\n`;
      }
      s += `${u2}// Stimulus\n${u2}#10;\n`;
    }
    s += `\n${u2}$display("Simulation finished at %0t", $time);\n${u2}$finish;\n${unit}end\n\nendmodule\n`;
    return { name: tb, text: s };
  }

  function vhdlTestbench(m, unit) {
    const tb = `tb_${m.name}`;
    const ports = m.children.filter((c) => c.kind === 'port');
    const isIn = (p) => (p.dir || 'in') === 'in';
    const clocks = ports.filter((p) => isIn(p) && isClock(p.name));
    const resets = ports.filter((p) => isIn(p) && resetPolarity(p.name) != null);
    let s = 'library ieee;\nuse ieee.std_logic_1164.all;\nuse ieee.numeric_std.all;\n\n';
    s += `entity ${tb} is\nend entity;\n\narchitecture sim of ${tb} is\n`;
    for (const p of ports) {
      const t = p.dataType || 'std_logic';
      const tl = t.toLowerCase();
      let initial = '';
      if (isIn(p)) {
        const pol = resetPolarity(p.name);
        if (pol != null) initial = ` := '${pol ? 1 : 0}'`;
        else if (tl === 'std_logic') initial = " := '0'";
        else if (tl.includes('vector') || tl.startsWith('unsigned') || tl.startsWith('signed')) initial = " := (others => '0')";
      }
      s += `${unit}signal ${p.name} : ${t}${initial};\n`;
    }
    s += 'begin\n';
    for (const c of clocks) s += `${unit}${c.name} <= not ${c.name} after 5 ns;\n`;
    if (clocks.length) s += '\n';
    s += vhdlInstance(m, unit, 'dut').split('\n').map((l) => unit + l).join('\n');
    s += `\n\n${unit}stim : process\n${unit}begin\n`;
    const u2 = unit + unit;
    if (resets.length) {
      s += `${u2}wait for 40 ns;\n`;
      for (const r of resets) s += `${u2}${r.name} <= '${resetPolarity(r.name) ? 0 : 1}';\n`;
    }
    s += `${u2}-- Stimulus\n${u2}wait for 200 ns;\n${u2}report "Simulation finished";\n${u2}std.env.finish;\n`;
    s += `${unit}end process;\nend architecture;\n`;
    return { name: tb, text: s };
  }

  const kinds = [
    { id: 'verilogModule', title: 'Verilog Module', ext: 'v', defaultName: 'top' },
    { id: 'svModule', title: 'SystemVerilog Module', ext: 'sv', defaultName: 'top' },
    { id: 'verilogTB', title: 'Verilog Testbench', ext: 'v', defaultName: 'tb_top' },
    { id: 'vhdlEntity', title: 'VHDL Entity', ext: 'vhd', defaultName: 'top' },
    { id: 'vhdlTB', title: 'VHDL Testbench', ext: 'vhd', defaultName: 'tb_top' },
    { id: 'empty', title: 'Empty File', ext: 'v', defaultName: 'untitled' },
  ];

  function newFile(kindId, name, unit = '    ') {
    const kind = kinds.find((k) => k.id === kindId);
    const n = name || kind.defaultName;
    const u = unit;
    switch (kindId) {
      case 'empty': return '';
      case 'verilogModule': return [
        '`timescale 1ns/1ps', '', `module ${n} #(`, `${u}parameter WIDTH = 8`, ') (',
        `${u}input  wire             clk,`, `${u}input  wire             rst_n,`, `${u}input  wire [WIDTH-1:0] din,`,
        `${u}output reg  [WIDTH-1:0] dout`, ');', '', `${u}always @(posedge clk or negedge rst_n) begin`,
        `${u}${u}if (!rst_n)`, `${u}${u}${u}dout <= {WIDTH{1'b0}};`, `${u}${u}else`, `${u}${u}${u}dout <= din;`, `${u}end`,
        '', 'endmodule', ''].join('\n');
      case 'svModule': return [
        '`timescale 1ns/1ps', '', `module ${n} #(`, `${u}parameter int WIDTH = 8`, ') (',
        `${u}input  logic             clk,`, `${u}input  logic             rst_n,`, `${u}input  logic [WIDTH-1:0] din,`,
        `${u}output logic [WIDTH-1:0] dout`, ');', '', `${u}always_ff @(posedge clk or negedge rst_n) begin`,
        `${u}${u}if (!rst_n) dout <= '0;`, `${u}${u}else        dout <= din;`, `${u}end`, '', 'endmodule', ''].join('\n');
      case 'verilogTB': return [
        '`timescale 1ns/1ps', '', `module ${n};`, '', `${u}reg clk = 1'b0;`, `${u}reg rst_n = 1'b0;`, `${u}always #5 clk = ~clk;`,
        '', `${u}initial begin`, `${u}${u}$dumpfile("${n}.vcd");`, `${u}${u}$dumpvars(0, ${n});`, `${u}${u}repeat (4) @(posedge clk);`,
        `${u}${u}rst_n = 1'b1;`, '', `${u}${u}repeat (20) @(posedge clk);`, `${u}${u}$display("Simulation finished at %0t", $time);`,
        `${u}${u}$finish;`, `${u}end`, '', 'endmodule', ''].join('\n');
      case 'vhdlEntity': return [
        'library ieee;', 'use ieee.std_logic_1164.all;', 'use ieee.numeric_std.all;', '', `entity ${n} is`, `${u}generic (`,
        `${u}${u}WIDTH : natural := 8`, `${u});`, `${u}port (`, `${u}${u}clk   : in  std_logic;`, `${u}${u}rst_n : in  std_logic;`,
        `${u}${u}din   : in  std_logic_vector(WIDTH-1 downto 0);`, `${u}${u}dout  : out std_logic_vector(WIDTH-1 downto 0)`,
        `${u});`, 'end entity;', '', `architecture rtl of ${n} is`, 'begin', `${u}process (clk, rst_n)`, `${u}begin`,
        `${u}${u}if rst_n = '0' then`, `${u}${u}${u}dout <= (others => '0');`, `${u}${u}elsif rising_edge(clk) then`,
        `${u}${u}${u}dout <= din;`, `${u}${u}end if;`, `${u}end process;`, 'end architecture;', ''].join('\n');
      case 'vhdlTB': return [
        'library ieee;', 'use ieee.std_logic_1164.all;', '', `entity ${n} is`, 'end entity;', '', `architecture sim of ${n} is`,
        `${u}signal clk   : std_logic := '0';`, `${u}signal rst_n : std_logic := '0';`, 'begin', `${u}clk <= not clk after 5 ns;`,
        '', `${u}stim : process`, `${u}begin`, `${u}${u}wait for 40 ns;`, `${u}${u}rst_n <= '1';`, `${u}${u}wait for 1 us;`,
        `${u}${u}std.env.finish;`, `${u}end process;`, 'end architecture;', ''].join('\n');
      default: return '';
    }
  }

  function starter(fileName) {
    const base = fileName.split(/[\\/]/).pop().replace(/\.[^.]*$/, '');
    const id = base.replace(/[^A-Za-z0-9_]/g, '_');
    const isTB = id.toLowerCase().startsWith('tb') || id.toLowerCase().endsWith('_tb');
    switch (HDLLanguage.detect(fileName)) {
      case 'verilog': return newFile(isTB ? 'verilogTB' : 'verilogModule', id);
      case 'systemVerilog': return newFile(isTB ? 'verilogTB' : 'svModule', id);
      case 'vhdl': return newFile(isTB ? 'vhdlTB' : 'vhdlEntity', id);
      default: return '';
    }
  }

  return { pad, instance, vhdlInstance, isClock, resetPolarity, testbench, kinds, newFile, starter };
})();

// Converts a Verilog/VHDL number literal into other bases for the status bar.
const NumberInfo = {
  describe(literal) {
    let s = literal.replace(/_/g, '');
    let width = null, base = 10, signed = false;
    const q = s.indexOf("'");
    if (q >= 0) {
      const w = s.slice(0, q).trim();
      width = /^\d+$/.test(w) ? parseInt(w, 10) : null;
      let rest = s.slice(q + 1).trim();
      if (rest[0] === 's' || rest[0] === 'S') { signed = true; rest = rest.slice(1); }
      if (!rest) return null;
      const b = rest[0].toLowerCase();
      base = { b: 2, o: 8, d: 10, h: 16 }[b];
      if (!base) return null;
      s = rest.slice(1);
    } else if (s.includes('#')) {
      const parts = s.split('#').filter((p) => p.length);
      if (parts.length < 2 || !/^\d+$/.test(parts[0])) return null;
      base = parseInt(parts[0], 10);
      s = parts[1];
    } else if (s.includes('"') && s.length > 2) {
      const qi = s.indexOf('"');
      const prefix = s.slice(0, qi).toLowerCase();
      base = prefix.endsWith('x') ? 16 : (prefix.endsWith('o') ? 8 : 2);
      s = s.slice(qi + 1).replace(/"/g, '');
      width = s.length * (base === 16 ? 4 : (base === 8 ? 3 : 1));
    } else if (!/^\d+$/.test(s)) return null;
    const lower = s.toLowerCase();
    if (/[xz?u]/.test(lower)) return null;
    if (!s || s.length > 64) return null;
    const digits = '0123456789abcdefghijklmnopqrstuvwxyz'.slice(0, base);
    if (![...lower].every((c) => digits.includes(c))) return null;
    let v;
    try { v = BigInt(base === 10 ? s : (base === 16 ? '0x' + s : base === 8 ? '0o' + s : base === 2 ? '0b' + s : NaN)); } catch { return null; }
    if (v >= (1n << 64n)) return null;
    const parts = [];
    const bitLen = v === 0n ? 0 : v.toString(2).length;
    const w = width != null ? width : Math.max(1, bitLen);
    let dec = v.toString();
    if (signed && width != null && width < 64 && width > 0 && (v & (1n << BigInt(width - 1))) !== 0n) {
      dec = (v - (1n << BigInt(width))).toString();
    }
    parts.push(dec);
    parts.push('0x' + v.toString(16).toUpperCase());
    if (w <= 32) {
      let b = v.toString(2);
      if (b.length < w) b = '0'.repeat(w - b.length) + b;
      let grouped = '';
      for (let i = 0; i < b.length; i++) { if (i > 0 && (b.length - i) % 4 === 0) grouped += '_'; grouped += b[i]; }
      parts.push('0b' + grouped);
    }
    if (width != null) parts.push(`${width} bit${width === 1 ? '' : 's'}`);
    return parts.join(' · ');
  },
};

if (typeof module !== 'undefined') module.exports = { Templates, NumberInfo };
