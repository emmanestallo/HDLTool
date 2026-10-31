import Foundation

/// Generated code: instance templates, testbenches and new-file skeletons.
enum Templates {
    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }

    // MARK: Instance

    static func instance(of m: HDLSymbol, language: HDLLanguage, unit: String = "    ", instName: String? = nil) -> String {
        if language == .vhdl { return vhdlInstance(of: m, unit: unit, instName: instName) }
        let params = m.params
        let ports = m.ports
        let name = instName ?? "u_\(m.name)"
        var out = m.name
        if !params.isEmpty {
            let w = params.map(\.name.count).max() ?? 0
            out += " #(\n"
            out += params.enumerated().map { i, p in
                "\(unit).\(pad(p.name, w)) (\(pad(p.name, w)))" + (i < params.count - 1 ? "," : "")
            }.joined(separator: "\n")
            out += "\n)"
        }
        out += " \(name) (\n"
        let w = ports.map(\.name.count).max() ?? 0
        out += ports.enumerated().map { i, p in
            let comment = p.detail.isEmpty ? "" : "  // \(p.detail)"
            return "\(unit).\(pad(p.name, w)) (\(pad(p.name, w)))" + (i < ports.count - 1 ? "," : " ") + comment
        }.joined(separator: "\n")
        out += "\n);"
        return out
    }

    static func vhdlInstance(of m: HDLSymbol, unit: String, instName: String?) -> String {
        let generics = m.children.filter { $0.kind == .param }
        let ports = m.children.filter { $0.kind == .port }
        var out = "\(instName ?? "u_\(m.name)") : entity work.\(m.name)\n"
        if !generics.isEmpty {
            let w = generics.map(\.name.count).max() ?? 0
            out += "\(unit)generic map (\n"
            out += generics.enumerated().map { i, g in "\(unit)\(unit)\(pad(g.name, w)) => \(g.name)" + (i < generics.count - 1 ? "," : "") }.joined(separator: "\n")
            out += "\n\(unit))\n"
        }
        let w = ports.map(\.name.count).max() ?? 0
        out += "\(unit)port map (\n"
        out += ports.enumerated().map { i, p in "\(unit)\(unit)\(pad(p.name, w)) => \(p.name)" + (i < ports.count - 1 ? "," : "") }.joined(separator: "\n")
        out += "\n\(unit));"
        return out
    }

    // MARK: Testbench

    static func isClock(_ n: String) -> Bool {
        let l = n.lowercased()
        return l == "clk" || l == "clock" || l == "i_clk" || l == "clk_i" || l.hasPrefix("clk_") && l.count <= 8 || l == "aclk"
    }
    static func resetPolarity(_ n: String) -> Bool? {
        let l = n.lowercased()
        if ["rst_n", "rstn", "resetn", "reset_n", "nrst", "areset_n", "aresetn", "i_rst_n", "rst_ni", "rst_b"].contains(l) { return false }
        if ["rst", "reset", "areset", "i_rst", "rst_i", "srst"].contains(l) { return true }
        return nil
    }

    static func testbench(for m: HDLSymbol, language: HDLLanguage, unit: String = "    ") -> (name: String, text: String) {
        if language == .vhdl { return vhdlTestbench(for: m, unit: unit) }
        let sv = language == .systemVerilog
        let tb = "tb_\(m.name)"
        let ports = m.ports
        let clocks = ports.filter { ($0.dir ?? "input") == "input" && isClock($0.name) }
        let resets = ports.filter { ($0.dir ?? "input") == "input" && resetPolarity($0.name) != nil }
        let inputs = ports.filter { ($0.dir ?? "input") == "input" }
        let outputs = ports.filter { ($0.dir ?? "") != "input" && $0.dir != nil }
        var s = "`timescale 1ns/1ps\n\n"
        s += "module \(tb);\n\n"
        let params = m.params
        if !params.isEmpty {
            s += "\(unit)// Parameters\n"
            for p in params { s += "\(unit)localparam \(p.name) = \(p.value ?? "0");\n" }
            s += "\n"
        }
        func decl(_ p: HDLSymbol, out: Bool) -> String {
            let kw = sv ? "logic" : (out ? "wire" : "reg ")
            let signed = (p.dataType ?? "").contains("signed") && !(p.dataType ?? "").contains("unsigned") ? " signed" : ""
            let r = p.range.map { " \($0)" } ?? ""
            return "\(unit)\(kw)\(signed)\(r) \(p.name);"
        }
        s += "\(unit)// DUT inputs\n"
        for p in inputs { s += decl(p, out: false) + "\n" }
        if !outputs.isEmpty {
            s += "\n\(unit)// DUT outputs\n"
            for p in outputs { s += decl(p, out: true) + "\n" }
        }
        if !clocks.isEmpty {
            s += "\n\(unit)// Clock: 100 MHz\n"
            for c in clocks {
                s += "\(unit)initial \(c.name) = 1'b0;\n"
                s += "\(unit)always #5 \(c.name) = ~\(c.name);\n"
            }
        }
        s += "\n\(unit)// Device under test\n"
        s += instance(of: m, language: language, unit: unit, instName: "dut")
            .components(separatedBy: "\n").map { unit + $0 }.joined(separator: "\n")
        s += "\n\n\(unit)initial begin\n"
        let u2 = unit + unit
        s += "\(u2)$dumpfile(\"\(tb).vcd\");\n"
        s += "\(u2)$dumpvars(0, \(tb));\n\n"
        let others = inputs.filter { p in !clocks.contains(where: { $0.name == p.name }) && !resets.contains(where: { $0.name == p.name }) }
        if !others.isEmpty || !resets.isEmpty {
            s += "\(u2)// Initial values\n"
            for r in resets { s += "\(u2)\(r.name) = 1'b\(resetPolarity(r.name)! ? 1 : 0);\n" }
            for p in others { s += "\(u2)\(p.name) = '0;\n".replacingOccurrences(of: "'0", with: sv ? "'0" : "0") }
            s += "\n"
        }
        if let clk = clocks.first {
            if !resets.isEmpty {
                s += "\(u2)// Release reset\n"
                s += "\(u2)repeat (4) @(posedge \(clk.name));\n"
                for r in resets { s += "\(u2)\(r.name) = 1'b\(resetPolarity(r.name)! ? 0 : 1);\n" }
                s += "\n"
            }
            s += "\(u2)// Stimulus\n"
            s += "\(u2)repeat (20) @(posedge \(clk.name));\n"
        } else {
            if !resets.isEmpty {
                s += "\(u2)#20;\n"
                for r in resets { s += "\(u2)\(r.name) = 1'b\(resetPolarity(r.name)! ? 0 : 1);\n" }
            }
            s += "\(u2)// Stimulus\n"
            s += "\(u2)#10;\n"
        }
        s += "\n\(u2)$display(\"Simulation finished at %0t\", $time);\n"
        s += "\(u2)$finish;\n"
        s += "\(unit)end\n\n"
        s += "endmodule\n"
        return (tb, s)
    }

    static func vhdlTestbench(for m: HDLSymbol, unit: String) -> (name: String, text: String) {
        let tb = "tb_\(m.name)"
        let ports = m.children.filter { $0.kind == .port }
        let clocks = ports.filter { ($0.dir ?? "in") == "in" && isClock($0.name) }
        let resets = ports.filter { ($0.dir ?? "in") == "in" && resetPolarity($0.name) != nil }
        var s = "library ieee;\nuse ieee.std_logic_1164.all;\nuse ieee.numeric_std.all;\n\n"
        s += "entity \(tb) is\nend entity;\n\n"
        s += "architecture sim of \(tb) is\n"
        for p in ports {
            let t = p.dataType ?? "std_logic"
            var initial = ""
            if (p.dir ?? "in") == "in" {
                if let pol = resetPolarity(p.name) { initial = " := '\(pol ? 1 : 0)'" }
                else if t.lowercased() == "std_logic" { initial = " := '0'" }
                else if t.lowercased().contains("vector") || t.lowercased().hasPrefix("unsigned") || t.lowercased().hasPrefix("signed") { initial = " := (others => '0')" }
            }
            s += "\(unit)signal \(p.name) : \(t)\(initial);\n"
        }
        s += "begin\n"
        for c in clocks { s += "\(unit)\(c.name) <= not \(c.name) after 5 ns;\n" }
        if !clocks.isEmpty { s += "\n" }
        s += vhdlInstance(of: m, unit: unit, instName: "dut").components(separatedBy: "\n").map { unit + $0 }.joined(separator: "\n")
        s += "\n\n\(unit)stim : process\n\(unit)begin\n"
        let u2 = unit + unit
        if !resets.isEmpty {
            s += "\(u2)wait for 40 ns;\n"
            for r in resets { s += "\(u2)\(r.name) <= '\(resetPolarity(r.name)! ? 0 : 1)';\n" }
        }
        s += "\(u2)-- Stimulus\n\(u2)wait for 200 ns;\n"
        s += "\(u2)report \"Simulation finished\";\n\(u2)std.env.finish;\n"
        s += "\(unit)end process;\nend architecture;\n"
        return (tb, s)
    }

    // MARK: New files

    enum Kind: String, CaseIterable, Identifiable {
        case verilogModule, svModule, verilogTB, vhdlEntity, vhdlTB, empty
        var id: String { rawValue }
        var title: String {
            switch self {
            case .verilogModule: return "Verilog Module"
            case .svModule: return "SystemVerilog Module"
            case .verilogTB: return "Verilog Testbench"
            case .vhdlEntity: return "VHDL Entity"
            case .vhdlTB: return "VHDL Testbench"
            case .empty: return "Empty File"
            }
        }
        var ext: String {
            switch self {
            case .verilogModule, .verilogTB, .empty: return "v"
            case .svModule: return "sv"
            case .vhdlEntity, .vhdlTB: return "vhd"
            }
        }
        var defaultName: String {
            switch self {
            case .verilogTB, .vhdlTB: return "tb_top"
            case .empty: return "untitled"
            default: return "top"
            }
        }
    }

    static func newFile(_ kind: Kind, name: String, unit: String = "    ") -> String {
        let n = name.isEmpty ? kind.defaultName : name
        switch kind {
        case .empty: return ""
        case .verilogModule:
            return """
            `timescale 1ns/1ps

            module \(n) #(
            \(unit)parameter WIDTH = 8
            ) (
            \(unit)input  wire             clk,
            \(unit)input  wire             rst_n,
            \(unit)input  wire [WIDTH-1:0] din,
            \(unit)output reg  [WIDTH-1:0] dout
            );

            \(unit)always @(posedge clk or negedge rst_n) begin
            \(unit)\(unit)if (!rst_n)
            \(unit)\(unit)\(unit)dout <= {WIDTH{1'b0}};
            \(unit)\(unit)else
            \(unit)\(unit)\(unit)dout <= din;
            \(unit)end

            endmodule

            """
        case .svModule:
            return """
            `timescale 1ns/1ps

            module \(n) #(
            \(unit)parameter int WIDTH = 8
            ) (
            \(unit)input  logic             clk,
            \(unit)input  logic             rst_n,
            \(unit)input  logic [WIDTH-1:0] din,
            \(unit)output logic [WIDTH-1:0] dout
            );

            \(unit)always_ff @(posedge clk or negedge rst_n) begin
            \(unit)\(unit)if (!rst_n) dout <= '0;
            \(unit)\(unit)else        dout <= din;
            \(unit)end

            endmodule

            """
        case .verilogTB:
            return """
            `timescale 1ns/1ps

            module \(n);

            \(unit)reg clk = 1'b0;
            \(unit)reg rst_n = 1'b0;
            \(unit)always #5 clk = ~clk;

            \(unit)initial begin
            \(unit)\(unit)$dumpfile("\(n).vcd");
            \(unit)\(unit)$dumpvars(0, \(n));
            \(unit)\(unit)repeat (4) @(posedge clk);
            \(unit)\(unit)rst_n = 1'b1;

            \(unit)\(unit)repeat (20) @(posedge clk);
            \(unit)\(unit)$display("Simulation finished at %0t", $time);
            \(unit)\(unit)$finish;
            \(unit)end

            endmodule

            """
        case .vhdlEntity:
            return """
            library ieee;
            use ieee.std_logic_1164.all;
            use ieee.numeric_std.all;

            entity \(n) is
            \(unit)generic (
            \(unit)\(unit)WIDTH : natural := 8
            \(unit));
            \(unit)port (
            \(unit)\(unit)clk   : in  std_logic;
            \(unit)\(unit)rst_n : in  std_logic;
            \(unit)\(unit)din   : in  std_logic_vector(WIDTH-1 downto 0);
            \(unit)\(unit)dout  : out std_logic_vector(WIDTH-1 downto 0)
            \(unit));
            end entity;

            architecture rtl of \(n) is
            begin
            \(unit)process (clk, rst_n)
            \(unit)begin
            \(unit)\(unit)if rst_n = '0' then
            \(unit)\(unit)\(unit)dout <= (others => '0');
            \(unit)\(unit)elsif rising_edge(clk) then
            \(unit)\(unit)\(unit)dout <= din;
            \(unit)\(unit)end if;
            \(unit)end process;
            end architecture;

            """
        case .vhdlTB:
            return """
            library ieee;
            use ieee.std_logic_1164.all;

            entity \(n) is
            end entity;

            architecture sim of \(n) is
            \(unit)signal clk   : std_logic := '0';
            \(unit)signal rst_n : std_logic := '0';
            begin
            \(unit)clk <= not clk after 5 ns;

            \(unit)stim : process
            \(unit)begin
            \(unit)\(unit)wait for 40 ns;
            \(unit)\(unit)rst_n <= '1';
            \(unit)\(unit)wait for 1 us;
            \(unit)\(unit)std.env.finish;
            \(unit)end process;
            end architecture;

            """
        }
    }

    /// A starter file for a newly created file with this name.
    static func starter(forFileNamed fileName: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        let base = url.deletingPathExtension().lastPathComponent
        let id = base.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        let isTB = id.lowercased().hasPrefix("tb") || id.lowercased().hasSuffix("_tb")
        switch HDLLanguage.detect(url) {
        case .verilog: return newFile(isTB ? .verilogTB : .verilogModule, name: id)
        case .systemVerilog: return newFile(isTB ? .verilogTB : .svModule, name: id)
        case .vhdl: return newFile(isTB ? .vhdlTB : .vhdlEntity, name: id)
        case .plain: return ""
        }
    }
}

/// Converts a Verilog/VHDL number literal into other bases for the status bar.
enum NumberInfo {
    static func describe(_ literal: String) -> String? {
        var s = literal.replacingOccurrences(of: "_", with: "")
        var width: Int? = nil
        var base = 10
        var signed = false
        if let q = s.firstIndex(of: "'") {
            let w = String(s[..<q]).trimmingCharacters(in: .whitespaces)
            width = Int(w)
            var rest = String(s[s.index(after: q)...]).trimmingCharacters(in: .whitespaces)
            if rest.first == "s" || rest.first == "S" { signed = true; rest.removeFirst() }
            guard let b = rest.first else { return nil }
            switch b.lowercased() {
            case "b": base = 2
            case "o": base = 8
            case "d": base = 10
            case "h": base = 16
            default: return nil
            }
            s = String(rest.dropFirst())
        } else if s.contains("#") {
            // VHDL based literal 16#FF#
            let parts = s.split(separator: "#")
            guard parts.count >= 2, let b = Int(parts[0]) else { return nil }
            base = b
            s = String(parts[1])
        } else if let q = s.firstIndex(of: "\""), s.count > 2 {
            // VHDL bit string x"FF"
            let prefix = s[..<q].lowercased()
            base = prefix.hasSuffix("x") ? 16 : (prefix.hasSuffix("o") ? 8 : 2)
            s = String(s[s.index(after: q)...]).replacingOccurrences(of: "\"", with: "")
            width = s.count * (base == 16 ? 4 : (base == 8 ? 3 : 1))
        } else {
            guard s.allSatisfy(\.isNumber) else { return nil }
        }
        let lower = s.lowercased()
        if lower.contains("x") || lower.contains("z") || lower.contains("?") || lower.contains("u") {
            return nil
        }
        guard !s.isEmpty, s.count <= 64, let v = UInt64(s, radix: base) else { return nil }
        var parts: [String] = []
        let w = width ?? max(1, 64 - v.leadingZeroBitCount)
        var dec = "\(v)"
        if signed, let width, width < 64, width > 0, v & (1 << (width - 1)) != 0 {
            dec = "\(Int64(bitPattern: v) - (Int64(1) << width))"
        }
        parts.append("\(dec)")
        parts.append("0x" + String(v, radix: 16, uppercase: true))
        if w <= 32 {
            var b = String(v, radix: 2)
            if b.count < w { b = String(repeating: "0", count: w - b.count) + b }
            // group by 4
            var grouped = ""
            for (i, c) in b.enumerated() {
                if i > 0 && (b.count - i) % 4 == 0 { grouped += "_" }
                grouped.append(c)
            }
            parts.append("0b" + grouped)
        }
        if let width { parts.append("\(width) bit\(width == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
