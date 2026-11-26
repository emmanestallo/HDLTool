'use strict';
/* global HDLLanguage */
// Code snippets. <#name#> marks a placeholder, a tab one indent level. Generated from Snippets.swift.

const SNIPPETS = [
 {
  "prefix": "module",
  "title": "Module (ANSI ports)",
  "body": "module <#name#> #(\n\tparameter WIDTH = 8\n) (\n\tinput  wire             clk,\n\tinput  wire             rst_n,\n\tinput  wire [WIDTH-1:0] <#din#>,\n\toutput reg  [WIDTH-1:0] <#dout#>\n);\n\n\t<#body#>\n\nendmodule",
  "family": "verilog"
 },
 {
  "prefix": "always_ff_rst",
  "title": "Clocked always with async reset",
  "body": "always @(posedge <#clk#> or negedge <#rst_n#>) begin\n\tif (!<#rst_n#>) begin\n\t\t<#reset#>\n\tend else begin\n\t\t<#logic#>\n\tend\nend",
  "family": "verilog"
 },
 {
  "prefix": "always_posedge",
  "title": "Clocked always",
  "body": "always @(posedge <#clk#>) begin\n\t<#body#>\nend",
  "family": "verilog"
 },
 {
  "prefix": "always_comb",
  "title": "Combinational always @(*)",
  "body": "always @(*) begin\n\t<#body#>\nend",
  "family": "verilog"
 },
 {
  "prefix": "initial",
  "title": "Initial block",
  "body": "initial begin\n\t<#body#>\nend",
  "family": "verilog"
 },
 {
  "prefix": "begin",
  "title": "begin … end",
  "body": "begin\n\t<#body#>\nend",
  "family": "verilog"
 },
 {
  "prefix": "if",
  "title": "if",
  "body": "if (<#cond#>) begin\n\t<#body#>\nend",
  "family": "verilog"
 },
 {
  "prefix": "ifelse",
  "title": "if … else",
  "body": "if (<#cond#>) begin\n\t<#then#>\nend else begin\n\t<#else#>\nend",
  "family": "verilog"
 },
 {
  "prefix": "case",
  "title": "case with default",
  "body": "case (<#sel#>)\n\t<#value#>: begin\n\t\t<#body#>\n\tend\n\tdefault: begin\n\t\t<#default#>\n\tend\nendcase",
  "family": "verilog"
 },
 {
  "prefix": "casez",
  "title": "casez",
  "body": "casez (<#sel#>)\n\t<#4'b1???#>: <#stmt#>;\n\tdefault: <#stmt#>;\nendcase",
  "family": "verilog"
 },
 {
  "prefix": "for",
  "title": "for loop",
  "body": "for (<#i#> = 0; <#i#> < <#N#>; <#i#> = <#i#> + 1) begin\n\t<#body#>\nend",
  "family": "verilog"
 },
 {
  "prefix": "genfor",
  "title": "generate for",
  "body": "genvar <#i#>;\ngenerate\n\tfor (<#i#> = 0; <#i#> < <#N#>; <#i#> = <#i#> + 1) begin : <#gen_label#>\n\t\t<#body#>\n\tend\nendgenerate",
  "family": "verilog"
 },
 {
  "prefix": "genif",
  "title": "generate if",
  "body": "generate\n\tif (<#cond#>) begin : <#gen_label#>\n\t\t<#body#>\n\tend else begin : <#gen_else#>\n\t\t<#body#>\n\tend\nendgenerate",
  "family": "verilog"
 },
 {
  "prefix": "function",
  "title": "function",
  "body": "function [<#7:0#>] <#name#>;\n\tinput [<#7:0#>] <#arg#>;\n\tbegin\n\t\t<#name#> = <#expr#>;\n\tend\nendfunction",
  "family": "verilog"
 },
 {
  "prefix": "task",
  "title": "task",
  "body": "task <#name#>;\n\tinput [<#7:0#>] <#arg#>;\n\tbegin\n\t\t<#body#>\n\tend\nendtask",
  "family": "verilog"
 },
 {
  "prefix": "localparam",
  "title": "localparam",
  "body": "localparam <#NAME#> = <#value#>;",
  "family": "verilog"
 },
 {
  "prefix": "parameter",
  "title": "parameter",
  "body": "parameter <#NAME#> = <#value#>;",
  "family": "verilog"
 },
 {
  "prefix": "wire",
  "title": "wire vector",
  "body": "wire [<#7#>:0] <#name#>;",
  "family": "verilog"
 },
 {
  "prefix": "reg",
  "title": "reg vector",
  "body": "reg  [<#7#>:0] <#name#>;",
  "family": "verilog"
 },
 {
  "prefix": "assign",
  "title": "continuous assignment",
  "body": "assign <#lhs#> = <#rhs#>;",
  "family": "verilog"
 },
 {
  "prefix": "fsm",
  "title": "Finite state machine (2 always blocks)",
  "body": "localparam [1:0] S_IDLE = 2'd0,\n\t\t\t\t S_RUN  = 2'd1,\n\t\t\t\t S_DONE = 2'd2;\n\nreg [1:0] state, state_next;\n\nalways @(posedge <#clk#> or negedge <#rst_n#>) begin\n\tif (!<#rst_n#>)\n\t\tstate <= S_IDLE;\n\telse\n\t\tstate <= state_next;\nend\n\nalways @(*) begin\n\tstate_next = state;\n\tcase (state)\n\t\tS_IDLE: if (<#start#>) state_next = S_RUN;\n\t\tS_RUN:  if (<#done#>)  state_next = S_DONE;\n\t\tS_DONE: state_next = S_IDLE;\n\t\tdefault: state_next = S_IDLE;\n\tendcase\nend",
  "family": "verilog"
 },
 {
  "prefix": "counter",
  "title": "Counter with enable",
  "body": "reg [<#WIDTH-1#>:0] <#count#>;\nalways @(posedge <#clk#> or negedge <#rst_n#>) begin\n\tif (!<#rst_n#>)\n\t\t<#count#> <= 0;\n\telse if (<#en#>)\n\t\t<#count#> <= <#count#> + 1'b1;\nend",
  "family": "verilog"
 },
 {
  "prefix": "shiftreg",
  "title": "Shift register",
  "body": "reg [<#N-1#>:0] <#sr#>;\nalways @(posedge <#clk#>) begin\n\t<#sr#> <= {<#sr#>[<#N-2#>:0], <#din#>};\nend",
  "family": "verilog"
 },
 {
  "prefix": "sync2ff",
  "title": "Two-flop synchronizer",
  "body": "reg [1:0] <#sync#>;\nalways @(posedge <#clk#>) begin\n\t<#sync#> <= {<#sync#>[0], <#async_in#>};\nend\nwire <#synced#> = <#sync#>[1];",
  "family": "verilog"
 },
 {
  "prefix": "edgedet",
  "title": "Rising-edge detector",
  "body": "reg <#sig#>_d;\nalways @(posedge <#clk#>) <#sig#>_d <= <#sig#>;\nwire <#sig#>_rise = <#sig#> & ~<#sig#>_d;",
  "family": "verilog"
 },
 {
  "prefix": "ram",
  "title": "Single-port RAM (inferred)",
  "body": "reg [<#DATA_W-1#>:0] <#mem#> [0:<#DEPTH-1#>];\nalways @(posedge <#clk#>) begin\n\tif (<#we#>)\n\t\t<#mem#>[<#addr#>] <= <#din#>;\n\t<#dout#> <= <#mem#>[<#addr#>];\nend",
  "family": "verilog"
 },
 {
  "prefix": "inst",
  "title": "Module instance",
  "body": "<#module#> <#u_name#> (\n\t.<#port#>(<#signal#>)\n);",
  "family": "verilog"
 },
 {
  "prefix": "tb",
  "title": "Testbench skeleton",
  "body": "`timescale 1ns/1ps\n\nmodule <#tb_name#>;\n\n\treg clk = 1'b0;\n\treg rst_n = 1'b0;\n\talways #5 clk = ~clk;\n\n\t// DUT\n\t<#dut#>\n\n\tinitial begin\n\t\t$dumpfile(\"<#tb_name#>.vcd\");\n\t\t$dumpvars(0, <#tb_name#>);\n\t\trepeat (4) @(posedge clk);\n\t\trst_n = 1'b1;\n\t\t<#stimulus#>\n\t\t#1000;\n\t\t$finish;\n\tend\n\nendmodule",
  "family": "verilog"
 },
 {
  "prefix": "clkgen",
  "title": "Clock generator",
  "body": "initial <#clk#> = 1'b0;\nalways #<#5#> <#clk#> = ~<#clk#>;",
  "family": "verilog"
 },
 {
  "prefix": "dump",
  "title": "Dump waveforms to VCD",
  "body": "initial begin\n\t$dumpfile(\"<#wave#>.vcd\");\n\t$dumpvars(0, <#top#>);\nend",
  "family": "verilog"
 },
 {
  "prefix": "display",
  "title": "$display",
  "body": "$display(\"%0t: <#message#>\", $time<#, args#>);",
  "family": "verilog"
 },
 {
  "prefix": "monitor",
  "title": "$monitor",
  "body": "$monitor(\"%0t: <#sig#>=%h\", $time, <#sig#>);",
  "family": "verilog"
 },
 {
  "prefix": "readmemh",
  "title": "$readmemh",
  "body": "$readmemh(\"<#file.hex#>\", <#mem#>);",
  "family": "verilog"
 },
 {
  "prefix": "timescale",
  "title": "`timescale",
  "body": "`timescale 1ns/1ps",
  "family": "verilog"
 },
 {
  "prefix": "ifdef",
  "title": "`ifdef … `endif",
  "body": "`ifdef <#MACRO#>\n<#code#>\n`endif",
  "family": "verilog"
 },
 {
  "prefix": "define",
  "title": "`define",
  "body": "`define <#NAME#> <#value#>",
  "family": "verilog"
 },
 {
  "prefix": "include",
  "title": "`include",
  "body": "`include \"<#file.vh#>\"",
  "family": "verilog"
 },
 {
  "prefix": "svmodule",
  "title": "Module (SystemVerilog)",
  "body": "module <#name#> #(\n\tparameter int WIDTH = 8\n) (\n\tinput  logic             clk,\n\tinput  logic             rst_n,\n\tinput  logic [WIDTH-1:0] <#din#>,\n\toutput logic [WIDTH-1:0] <#dout#>\n);\n\n\t<#body#>\n\nendmodule",
  "family": "systemVerilog"
 },
 {
  "prefix": "always_ff",
  "title": "always_ff with async reset",
  "body": "always_ff @(posedge <#clk#> or negedge <#rst_n#>) begin\n\tif (!<#rst_n#>) begin\n\t\t<#reset#>\n\tend else begin\n\t\t<#logic#>\n\tend\nend",
  "family": "systemVerilog"
 },
 {
  "prefix": "always_comb",
  "title": "always_comb",
  "body": "always_comb begin\n\t<#body#>\nend",
  "family": "systemVerilog"
 },
 {
  "prefix": "always_latch",
  "title": "always_latch",
  "body": "always_latch begin\n\tif (<#en#>) <#q#> = <#d#>;\nend",
  "family": "systemVerilog"
 },
 {
  "prefix": "uniquecase",
  "title": "unique case",
  "body": "unique case (<#sel#>)\n\t<#value#>: <#stmt#>;\n\tdefault: <#stmt#>;\nendcase",
  "family": "systemVerilog"
 },
 {
  "prefix": "svfsm",
  "title": "FSM with typedef enum",
  "body": "typedef enum logic [1:0] {\n\tIDLE,\n\tRUN,\n\tDONE\n} state_t;\n\nstate_t state, state_next;\n\nalways_ff @(posedge <#clk#> or negedge <#rst_n#>) begin\n\tif (!<#rst_n#>) state <= IDLE;\n\telse           state <= state_next;\nend\n\nalways_comb begin\n\tstate_next = state;\n\tunique case (state)\n\t\tIDLE: if (<#start#>) state_next = RUN;\n\t\tRUN:  if (<#done#>)  state_next = DONE;\n\t\tDONE: state_next = IDLE;\n\t\tdefault: state_next = IDLE;\n\tendcase\nend",
  "family": "systemVerilog"
 },
 {
  "prefix": "typedefenum",
  "title": "typedef enum",
  "body": "typedef enum logic [<#1#>:0] {\n\t<#A#>,\n\t<#B#>\n} <#name_t#>;",
  "family": "systemVerilog"
 },
 {
  "prefix": "typedefstruct",
  "title": "typedef struct packed",
  "body": "typedef struct packed {\n\tlogic [<#7#>:0] <#field#>;\n} <#name_t#>;",
  "family": "systemVerilog"
 },
 {
  "prefix": "interface",
  "title": "interface with modports",
  "body": "interface <#name#>_if #(parameter int WIDTH = 8) (input logic clk);\n\tlogic [WIDTH-1:0] data;\n\tlogic             valid;\n\tlogic             ready;\n\n\tmodport master (output data, valid, input ready);\n\tmodport slave  (input data, valid, output ready);\nendinterface",
  "family": "systemVerilog"
 },
 {
  "prefix": "package",
  "title": "package",
  "body": "package <#name#>_pkg;\n\t<#body#>\nendpackage",
  "family": "systemVerilog"
 },
 {
  "prefix": "class",
  "title": "class",
  "body": "class <#name#>;\n\t<#members#>\n\n\tfunction new();\n\tendfunction\nendclass",
  "family": "systemVerilog"
 },
 {
  "prefix": "assert",
  "title": "Concurrent assertion",
  "body": "<#label#>: assert property (@(posedge <#clk#>) disable iff (!<#rst_n#>)\n\t<#antecedent#> |-> ##1 <#consequent#>)\n\telse $error(\"<#message#>\");",
  "family": "systemVerilog"
 },
 {
  "prefix": "covergroup",
  "title": "covergroup",
  "body": "covergroup <#cg_name#> @(posedge <#clk#>);\n\tcoverpoint <#sig#>;\nendgroup",
  "family": "systemVerilog"
 },
 {
  "prefix": "foreach",
  "title": "foreach loop",
  "body": "foreach (<#arr#>[<#i#>]) begin\n\t<#body#>\nend",
  "family": "systemVerilog"
 },
 {
  "prefix": "svfor",
  "title": "for loop with int",
  "body": "for (int <#i#> = 0; <#i#> < <#N#>; <#i#>++) begin\n\t<#body#>\nend",
  "family": "systemVerilog"
 },
 {
  "prefix": "libs",
  "title": "IEEE libraries",
  "body": "library ieee;\nuse ieee.std_logic_1164.all;\nuse ieee.numeric_std.all;",
  "family": "vhdl"
 },
 {
  "prefix": "entity",
  "title": "Entity and architecture",
  "body": "entity <#name#> is\n\tgeneric (\n\t\tWIDTH : natural := 8\n\t);\n\tport (\n\t\tclk   : in  std_logic;\n\t\trst_n : in  std_logic;\n\t\t<#din#>   : in  std_logic_vector(WIDTH-1 downto 0);\n\t\t<#dout#>  : out std_logic_vector(WIDTH-1 downto 0)\n\t);\nend entity;\n\narchitecture rtl of <#name#> is\nbegin\n\t<#body#>\nend architecture;",
  "family": "vhdl"
 },
 {
  "prefix": "architecture",
  "title": "Architecture",
  "body": "architecture <#rtl#> of <#entity#> is\n\t<#declarations#>\nbegin\n\t<#statements#>\nend architecture;",
  "family": "vhdl"
 },
 {
  "prefix": "process_clk",
  "title": "Clocked process with async reset",
  "body": "process (<#clk#>, <#rst_n#>)\nbegin\n\tif <#rst_n#> = '0' then\n\t\t<#reset#>\n\telsif rising_edge(<#clk#>) then\n\t\t<#logic#>\n\tend if;\nend process;",
  "family": "vhdl"
 },
 {
  "prefix": "process_comb",
  "title": "Combinational process (VHDL-2008)",
  "body": "process (all)\nbegin\n\t<#body#>\nend process;",
  "family": "vhdl"
 },
 {
  "prefix": "if",
  "title": "if … elsif … else",
  "body": "if <#cond#> then\n\t<#body#>\nelsif <#cond2#> then\n\t<#body#>\nelse\n\t<#body#>\nend if;",
  "family": "vhdl"
 },
 {
  "prefix": "case",
  "title": "case",
  "body": "case <#sel#> is\n\twhen <#value#> =>\n\t\t<#body#>\n\twhen others =>\n\t\tnull;\nend case;",
  "family": "vhdl"
 },
 {
  "prefix": "signal",
  "title": "signal",
  "body": "signal <#name#> : std_logic_vector(<#7#> downto 0) := (others => '0');",
  "family": "vhdl"
 },
 {
  "prefix": "constant",
  "title": "constant",
  "body": "constant <#NAME#> : <#integer#> := <#value#>;",
  "family": "vhdl"
 },
 {
  "prefix": "component",
  "title": "component declaration",
  "body": "component <#name#> is\n\tport (\n\t\t<#port#> : in std_logic\n\t);\nend component;",
  "family": "vhdl"
 },
 {
  "prefix": "inst",
  "title": "Entity instance",
  "body": "<#u_name#> : entity work.<#entity#>\n\tport map (\n\t\t<#port#> => <#signal#>\n\t);",
  "family": "vhdl"
 },
 {
  "prefix": "forgen",
  "title": "for generate",
  "body": "<#gen_label#> : for <#i#> in 0 to <#N-1#> generate\n\t<#body#>\nend generate;",
  "family": "vhdl"
 },
 {
  "prefix": "fsm",
  "title": "FSM with enumerated type",
  "body": "type state_t is (IDLE, RUN, DONE);\nsignal state : state_t := IDLE;",
  "family": "vhdl"
 },
 {
  "prefix": "tb",
  "title": "Testbench skeleton",
  "body": "library ieee;\nuse ieee.std_logic_1164.all;\n\nentity <#tb_name#> is\nend entity;\n\narchitecture sim of <#tb_name#> is\n\tsignal clk   : std_logic := '0';\n\tsignal rst_n : std_logic := '0';\nbegin\n\tclk <= not clk after 5 ns;\n\n\t<#dut#>\n\n\tstim : process\n\tbegin\n\t\twait for 40 ns;\n\t\trst_n <= '1';\n\t\t<#stimulus#>\n\t\twait for 1 us;\n\t\tstd.env.finish;\n\tend process;\nend architecture;",
  "family": "vhdl"
 },
 {
  "prefix": "report",
  "title": "report",
  "body": "report \"<#message#>\" severity <#note#>;",
  "family": "vhdl"
 }
];

const Snippets = {
  all: SNIPPETS,
  applies(s, lang) {
    if (s.family === 'verilog') return HDLLanguage.isVerilogFamily(lang);
    if (s.family === 'systemVerilog') return lang === 'systemVerilog';
    return lang === 'vhdl';
  },
  available(lang) { return SNIPPETS.filter((s) => Snippets.applies(s, lang)); },
  id(s) { return `${s.family}-${s.prefix}`; },
  // Body with indentation applied: lines after the first get baseIndent, tabs become unit.
  expand(s, baseIndent, unit) {
    return s.body.replace(/\t/g, unit).split('\n')
      .map((l, i) => (i === 0 ? l : (l === '' ? '' : baseIndent + l))).join('\n');
  },
  // Converts <#name#> placeholders to Monaco snippet syntax. Same names share a tab stop.
  toMonaco(text) {
    const ids = new Map();
    let out = '';
    let last = 0;
    const re = /<#(.*?)#>/g;
    let m;
    while ((m = re.exec(text))) {
      out += text.slice(last, m.index).replace(/[$}\\]/g, '\\$&');
      const name = m[1];
      if (!ids.has(name)) ids.set(name, ids.size + 1);
      out += '${' + ids.get(name) + ':' + name.replace(/[$}\\]/g, '\\$&') + '}';
      last = re.lastIndex;
    }
    out += text.slice(last).replace(/[$}\\]/g, '\\$&');
    return out;
  },
};

if (typeof module !== 'undefined') module.exports = { Snippets };
