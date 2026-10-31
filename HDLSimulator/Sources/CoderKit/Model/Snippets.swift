import Foundation

/// A code snippet. `<#name#>` marks a placeholder (Tab jumps to the next one), `\t` one indent level.
struct Snippet: Identifiable, Hashable {
    let prefix: String
    let title: String
    let body: String
    let family: Family

    enum Family { case verilog, systemVerilog, vhdl }

    var id: String { "\(family)-\(prefix)" }

    func applies(to lang: HDLLanguage) -> Bool {
        switch family {
        case .verilog: return lang.isVerilogFamily
        case .systemVerilog: return lang == .systemVerilog
        case .vhdl: return lang == .vhdl
        }
    }

    static func available(for lang: HDLLanguage) -> [Snippet] {
        all.filter { $0.applies(to: lang) }
    }

    /// Body with indentation applied: every line after the first gets `baseIndent`, `\t` becomes `unit`.
    func expand(baseIndent: String, unit: String) -> String {
        body.replacingOccurrences(of: "\t", with: unit)
            .components(separatedBy: "\n")
            .enumerated()
            .map { $0.offset == 0 ? $0.element : ($0.element.isEmpty ? "" : baseIndent + $0.element) }
            .joined(separator: "\n")
    }

    static let all: [Snippet] = verilog + systemVerilog + vhdl

    static let verilog: [Snippet] = [
        Snippet(prefix: "module", title: "Module (ANSI ports)", body: """
            module <#name#> #(
            \tparameter WIDTH = 8
            ) (
            \tinput  wire             clk,
            \tinput  wire             rst_n,
            \tinput  wire [WIDTH-1:0] <#din#>,
            \toutput reg  [WIDTH-1:0] <#dout#>
            );

            \t<#body#>

            endmodule
            """, family: .verilog),
        Snippet(prefix: "always_ff_rst", title: "Clocked always with async reset", body: """
            always @(posedge <#clk#> or negedge <#rst_n#>) begin
            \tif (!<#rst_n#>) begin
            \t\t<#reset#>
            \tend else begin
            \t\t<#logic#>
            \tend
            end
            """, family: .verilog),
        Snippet(prefix: "always_posedge", title: "Clocked always", body: """
            always @(posedge <#clk#>) begin
            \t<#body#>
            end
            """, family: .verilog),
        Snippet(prefix: "always_comb", title: "Combinational always @(*)", body: """
            always @(*) begin
            \t<#body#>
            end
            """, family: .verilog),
        Snippet(prefix: "initial", title: "Initial block", body: """
            initial begin
            \t<#body#>
            end
            """, family: .verilog),
        Snippet(prefix: "begin", title: "begin … end", body: """
            begin
            \t<#body#>
            end
            """, family: .verilog),
        Snippet(prefix: "if", title: "if", body: """
            if (<#cond#>) begin
            \t<#body#>
            end
            """, family: .verilog),
        Snippet(prefix: "ifelse", title: "if … else", body: """
            if (<#cond#>) begin
            \t<#then#>
            end else begin
            \t<#else#>
            end
            """, family: .verilog),
        Snippet(prefix: "case", title: "case with default", body: """
            case (<#sel#>)
            \t<#value#>: begin
            \t\t<#body#>
            \tend
            \tdefault: begin
            \t\t<#default#>
            \tend
            endcase
            """, family: .verilog),
        Snippet(prefix: "casez", title: "casez", body: """
            casez (<#sel#>)
            \t<#4'b1???#>: <#stmt#>;
            \tdefault: <#stmt#>;
            endcase
            """, family: .verilog),
        Snippet(prefix: "for", title: "for loop", body: """
            for (<#i#> = 0; <#i#> < <#N#>; <#i#> = <#i#> + 1) begin
            \t<#body#>
            end
            """, family: .verilog),
        Snippet(prefix: "genfor", title: "generate for", body: """
            genvar <#i#>;
            generate
            \tfor (<#i#> = 0; <#i#> < <#N#>; <#i#> = <#i#> + 1) begin : <#gen_label#>
            \t\t<#body#>
            \tend
            endgenerate
            """, family: .verilog),
        Snippet(prefix: "genif", title: "generate if", body: """
            generate
            \tif (<#cond#>) begin : <#gen_label#>
            \t\t<#body#>
            \tend else begin : <#gen_else#>
            \t\t<#body#>
            \tend
            endgenerate
            """, family: .verilog),
        Snippet(prefix: "function", title: "function", body: """
            function [<#7:0#>] <#name#>;
            \tinput [<#7:0#>] <#arg#>;
            \tbegin
            \t\t<#name#> = <#expr#>;
            \tend
            endfunction
            """, family: .verilog),
        Snippet(prefix: "task", title: "task", body: """
            task <#name#>;
            \tinput [<#7:0#>] <#arg#>;
            \tbegin
            \t\t<#body#>
            \tend
            endtask
            """, family: .verilog),
        Snippet(prefix: "localparam", title: "localparam", body: "localparam <#NAME#> = <#value#>;", family: .verilog),
        Snippet(prefix: "parameter", title: "parameter", body: "parameter <#NAME#> = <#value#>;", family: .verilog),
        Snippet(prefix: "wire", title: "wire vector", body: "wire [<#7#>:0] <#name#>;", family: .verilog),
        Snippet(prefix: "reg", title: "reg vector", body: "reg  [<#7#>:0] <#name#>;", family: .verilog),
        Snippet(prefix: "assign", title: "continuous assignment", body: "assign <#lhs#> = <#rhs#>;", family: .verilog),
        Snippet(prefix: "fsm", title: "Finite state machine (2 always blocks)", body: """
            localparam [1:0] S_IDLE = 2'd0,
            \t\t\t\t S_RUN  = 2'd1,
            \t\t\t\t S_DONE = 2'd2;

            reg [1:0] state, state_next;

            always @(posedge <#clk#> or negedge <#rst_n#>) begin
            \tif (!<#rst_n#>)
            \t\tstate <= S_IDLE;
            \telse
            \t\tstate <= state_next;
            end

            always @(*) begin
            \tstate_next = state;
            \tcase (state)
            \t\tS_IDLE: if (<#start#>) state_next = S_RUN;
            \t\tS_RUN:  if (<#done#>)  state_next = S_DONE;
            \t\tS_DONE: state_next = S_IDLE;
            \t\tdefault: state_next = S_IDLE;
            \tendcase
            end
            """, family: .verilog),
        Snippet(prefix: "counter", title: "Counter with enable", body: """
            reg [<#WIDTH-1#>:0] <#count#>;
            always @(posedge <#clk#> or negedge <#rst_n#>) begin
            \tif (!<#rst_n#>)
            \t\t<#count#> <= 0;
            \telse if (<#en#>)
            \t\t<#count#> <= <#count#> + 1'b1;
            end
            """, family: .verilog),
        Snippet(prefix: "shiftreg", title: "Shift register", body: """
            reg [<#N-1#>:0] <#sr#>;
            always @(posedge <#clk#>) begin
            \t<#sr#> <= {<#sr#>[<#N-2#>:0], <#din#>};
            end
            """, family: .verilog),
        Snippet(prefix: "sync2ff", title: "Two-flop synchronizer", body: """
            reg [1:0] <#sync#>;
            always @(posedge <#clk#>) begin
            \t<#sync#> <= {<#sync#>[0], <#async_in#>};
            end
            wire <#synced#> = <#sync#>[1];
            """, family: .verilog),
        Snippet(prefix: "edgedet", title: "Rising-edge detector", body: """
            reg <#sig#>_d;
            always @(posedge <#clk#>) <#sig#>_d <= <#sig#>;
            wire <#sig#>_rise = <#sig#> & ~<#sig#>_d;
            """, family: .verilog),
        Snippet(prefix: "ram", title: "Single-port RAM (inferred)", body: """
            reg [<#DATA_W-1#>:0] <#mem#> [0:<#DEPTH-1#>];
            always @(posedge <#clk#>) begin
            \tif (<#we#>)
            \t\t<#mem#>[<#addr#>] <= <#din#>;
            \t<#dout#> <= <#mem#>[<#addr#>];
            end
            """, family: .verilog),
        Snippet(prefix: "inst", title: "Module instance", body: """
            <#module#> <#u_name#> (
            \t.<#port#>(<#signal#>)
            );
            """, family: .verilog),
        Snippet(prefix: "tb", title: "Testbench skeleton", body: """
            `timescale 1ns/1ps

            module <#tb_name#>;

            \treg clk = 1'b0;
            \treg rst_n = 1'b0;
            \talways #5 clk = ~clk;

            \t// DUT
            \t<#dut#>

            \tinitial begin
            \t\t$dumpfile("<#tb_name#>.vcd");
            \t\t$dumpvars(0, <#tb_name#>);
            \t\trepeat (4) @(posedge clk);
            \t\trst_n = 1'b1;
            \t\t<#stimulus#>
            \t\t#1000;
            \t\t$finish;
            \tend

            endmodule
            """, family: .verilog),
        Snippet(prefix: "clkgen", title: "Clock generator", body: """
            initial <#clk#> = 1'b0;
            always #<#5#> <#clk#> = ~<#clk#>;
            """, family: .verilog),
        Snippet(prefix: "dump", title: "Dump waveforms to VCD", body: """
            initial begin
            \t$dumpfile("<#wave#>.vcd");
            \t$dumpvars(0, <#top#>);
            end
            """, family: .verilog),
        Snippet(prefix: "display", title: "$display", body: "$display(\"%0t: <#message#>\", $time<#, args#>);", family: .verilog),
        Snippet(prefix: "monitor", title: "$monitor", body: "$monitor(\"%0t: <#sig#>=%h\", $time, <#sig#>);", family: .verilog),
        Snippet(prefix: "readmemh", title: "$readmemh", body: "$readmemh(\"<#file.hex#>\", <#mem#>);", family: .verilog),
        Snippet(prefix: "timescale", title: "`timescale", body: "`timescale 1ns/1ps", family: .verilog),
        Snippet(prefix: "ifdef", title: "`ifdef … `endif", body: """
            `ifdef <#MACRO#>
            <#code#>
            `endif
            """, family: .verilog),
        Snippet(prefix: "define", title: "`define", body: "`define <#NAME#> <#value#>", family: .verilog),
        Snippet(prefix: "include", title: "`include", body: "`include \"<#file.vh#>\"", family: .verilog),
    ]

    static let systemVerilog: [Snippet] = [
        Snippet(prefix: "svmodule", title: "Module (SystemVerilog)", body: """
            module <#name#> #(
            \tparameter int WIDTH = 8
            ) (
            \tinput  logic             clk,
            \tinput  logic             rst_n,
            \tinput  logic [WIDTH-1:0] <#din#>,
            \toutput logic [WIDTH-1:0] <#dout#>
            );

            \t<#body#>

            endmodule
            """, family: .systemVerilog),
        Snippet(prefix: "always_ff", title: "always_ff with async reset", body: """
            always_ff @(posedge <#clk#> or negedge <#rst_n#>) begin
            \tif (!<#rst_n#>) begin
            \t\t<#reset#>
            \tend else begin
            \t\t<#logic#>
            \tend
            end
            """, family: .systemVerilog),
        Snippet(prefix: "always_comb", title: "always_comb", body: """
            always_comb begin
            \t<#body#>
            end
            """, family: .systemVerilog),
        Snippet(prefix: "always_latch", title: "always_latch", body: """
            always_latch begin
            \tif (<#en#>) <#q#> = <#d#>;
            end
            """, family: .systemVerilog),
        Snippet(prefix: "uniquecase", title: "unique case", body: """
            unique case (<#sel#>)
            \t<#value#>: <#stmt#>;
            \tdefault: <#stmt#>;
            endcase
            """, family: .systemVerilog),
        Snippet(prefix: "svfsm", title: "FSM with typedef enum", body: """
            typedef enum logic [1:0] {
            \tIDLE,
            \tRUN,
            \tDONE
            } state_t;

            state_t state, state_next;

            always_ff @(posedge <#clk#> or negedge <#rst_n#>) begin
            \tif (!<#rst_n#>) state <= IDLE;
            \telse           state <= state_next;
            end

            always_comb begin
            \tstate_next = state;
            \tunique case (state)
            \t\tIDLE: if (<#start#>) state_next = RUN;
            \t\tRUN:  if (<#done#>)  state_next = DONE;
            \t\tDONE: state_next = IDLE;
            \t\tdefault: state_next = IDLE;
            \tendcase
            end
            """, family: .systemVerilog),
        Snippet(prefix: "typedefenum", title: "typedef enum", body: """
            typedef enum logic [<#1#>:0] {
            \t<#A#>,
            \t<#B#>
            } <#name_t#>;
            """, family: .systemVerilog),
        Snippet(prefix: "typedefstruct", title: "typedef struct packed", body: """
            typedef struct packed {
            \tlogic [<#7#>:0] <#field#>;
            } <#name_t#>;
            """, family: .systemVerilog),
        Snippet(prefix: "interface", title: "interface with modports", body: """
            interface <#name#>_if #(parameter int WIDTH = 8) (input logic clk);
            \tlogic [WIDTH-1:0] data;
            \tlogic             valid;
            \tlogic             ready;

            \tmodport master (output data, valid, input ready);
            \tmodport slave  (input data, valid, output ready);
            endinterface
            """, family: .systemVerilog),
        Snippet(prefix: "package", title: "package", body: """
            package <#name#>_pkg;
            \t<#body#>
            endpackage
            """, family: .systemVerilog),
        Snippet(prefix: "class", title: "class", body: """
            class <#name#>;
            \t<#members#>

            \tfunction new();
            \tendfunction
            endclass
            """, family: .systemVerilog),
        Snippet(prefix: "assert", title: "Concurrent assertion", body: """
            <#label#>: assert property (@(posedge <#clk#>) disable iff (!<#rst_n#>)
            \t<#antecedent#> |-> ##1 <#consequent#>)
            \telse $error("<#message#>");
            """, family: .systemVerilog),
        Snippet(prefix: "covergroup", title: "covergroup", body: """
            covergroup <#cg_name#> @(posedge <#clk#>);
            \tcoverpoint <#sig#>;
            endgroup
            """, family: .systemVerilog),
        Snippet(prefix: "foreach", title: "foreach loop", body: """
            foreach (<#arr#>[<#i#>]) begin
            \t<#body#>
            end
            """, family: .systemVerilog),
        Snippet(prefix: "svfor", title: "for loop with int", body: """
            for (int <#i#> = 0; <#i#> < <#N#>; <#i#>++) begin
            \t<#body#>
            end
            """, family: .systemVerilog),
    ]

    static let vhdl: [Snippet] = [
        Snippet(prefix: "libs", title: "IEEE libraries", body: """
            library ieee;
            use ieee.std_logic_1164.all;
            use ieee.numeric_std.all;
            """, family: .vhdl),
        Snippet(prefix: "entity", title: "Entity and architecture", body: """
            entity <#name#> is
            \tgeneric (
            \t\tWIDTH : natural := 8
            \t);
            \tport (
            \t\tclk   : in  std_logic;
            \t\trst_n : in  std_logic;
            \t\t<#din#>   : in  std_logic_vector(WIDTH-1 downto 0);
            \t\t<#dout#>  : out std_logic_vector(WIDTH-1 downto 0)
            \t);
            end entity;

            architecture rtl of <#name#> is
            begin
            \t<#body#>
            end architecture;
            """, family: .vhdl),
        Snippet(prefix: "architecture", title: "Architecture", body: """
            architecture <#rtl#> of <#entity#> is
            \t<#declarations#>
            begin
            \t<#statements#>
            end architecture;
            """, family: .vhdl),
        Snippet(prefix: "process_clk", title: "Clocked process with async reset", body: """
            process (<#clk#>, <#rst_n#>)
            begin
            \tif <#rst_n#> = '0' then
            \t\t<#reset#>
            \telsif rising_edge(<#clk#>) then
            \t\t<#logic#>
            \tend if;
            end process;
            """, family: .vhdl),
        Snippet(prefix: "process_comb", title: "Combinational process (VHDL-2008)", body: """
            process (all)
            begin
            \t<#body#>
            end process;
            """, family: .vhdl),
        Snippet(prefix: "if", title: "if … elsif … else", body: """
            if <#cond#> then
            \t<#body#>
            elsif <#cond2#> then
            \t<#body#>
            else
            \t<#body#>
            end if;
            """, family: .vhdl),
        Snippet(prefix: "case", title: "case", body: """
            case <#sel#> is
            \twhen <#value#> =>
            \t\t<#body#>
            \twhen others =>
            \t\tnull;
            end case;
            """, family: .vhdl),
        Snippet(prefix: "signal", title: "signal", body: "signal <#name#> : std_logic_vector(<#7#> downto 0) := (others => '0');", family: .vhdl),
        Snippet(prefix: "constant", title: "constant", body: "constant <#NAME#> : <#integer#> := <#value#>;", family: .vhdl),
        Snippet(prefix: "component", title: "component declaration", body: """
            component <#name#> is
            \tport (
            \t\t<#port#> : in std_logic
            \t);
            end component;
            """, family: .vhdl),
        Snippet(prefix: "inst", title: "Entity instance", body: """
            <#u_name#> : entity work.<#entity#>
            \tport map (
            \t\t<#port#> => <#signal#>
            \t);
            """, family: .vhdl),
        Snippet(prefix: "forgen", title: "for generate", body: """
            <#gen_label#> : for <#i#> in 0 to <#N-1#> generate
            \t<#body#>
            end generate;
            """, family: .vhdl),
        Snippet(prefix: "fsm", title: "FSM with enumerated type", body: """
            type state_t is (IDLE, RUN, DONE);
            signal state : state_t := IDLE;
            """, family: .vhdl),
        Snippet(prefix: "tb", title: "Testbench skeleton", body: """
            library ieee;
            use ieee.std_logic_1164.all;

            entity <#tb_name#> is
            end entity;

            architecture sim of <#tb_name#> is
            \tsignal clk   : std_logic := '0';
            \tsignal rst_n : std_logic := '0';
            begin
            \tclk <= not clk after 5 ns;

            \t<#dut#>

            \tstim : process
            \tbegin
            \t\twait for 40 ns;
            \t\trst_n <= '1';
            \t\t<#stimulus#>
            \t\twait for 1 us;
            \t\tstd.env.finish;
            \tend process;
            end architecture;
            """, family: .vhdl),
        Snippet(prefix: "report", title: "report", body: "report \"<#message#>\" severity <#note#>;", family: .vhdl),
    ]
}
