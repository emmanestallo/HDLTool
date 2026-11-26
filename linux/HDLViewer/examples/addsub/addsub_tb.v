// Signed 16-bit adder / subtractor with a self-checking testbench.
// Run:  iverilog -o sim addsub_tb.v && vvp sim     (writes addsub.vcd)
`timescale 1ns/1ps

module addsub16 (
    input  wire signed [15:0] a,
    input  wire signed [15:0] b,
    input  wire               sub,       // 0: a + b,  1: a - b
    output wire signed [15:0] y,
    output wire               carry,     // carry out of bit 15 (unsigned view)
    output wire               overflow,  // signed overflow
    output wire               zero,
    output wire               negative
);
    // a - b  ==  a + ~b + 1, so one adder does both operations.
    wire [15:0] b_eff = sub ? ~b : b;
    wire [16:0] sum   = {1'b0, a} + {1'b0, b_eff} + sub;

    assign y        = sum[15:0];
    assign carry    = sum[16];
    assign overflow = (a[15] == b_eff[15]) && (y[15] != a[15]);
    assign zero     = (y == 16'sd0);
    assign negative = y[15];
endmodule

module tb;
    reg  signed [15:0] a, b;
    reg                sub;
    wire signed [15:0] y;
    wire               carry, overflow, zero, negative;

    // Reference model, computed with extra bits so overflow is visible.
    reg  signed [16:0] expected_wide;
    reg  signed [15:0] expected;
    reg                expected_ovf;
    integer            errors = 0;
    integer            tests  = 0;

    addsub16 dut (.a(a), .b(b), .sub(sub), .y(y), .carry(carry),
                  .overflow(overflow), .zero(zero), .negative(negative));

    task check(input signed [15:0] ta, input signed [15:0] tb_, input tsub);
        begin
            a = ta; b = tb_; sub = tsub;
            expected_wide = tsub ? ({ta[15], ta} - {tb_[15], tb_}) : ({ta[15], ta} + {tb_[15], tb_});
            expected      = expected_wide[15:0];
            expected_ovf  = expected_wide[16] != expected_wide[15];
            #10;
            tests = tests + 1;
            if (y !== expected || overflow !== expected_ovf) begin
                errors = errors + 1;
                $display("FAIL %0d %s %0d = %0d (expected %0d, ovf=%b)",
                         ta, tsub ? "-" : "+", tb_, y, expected, expected_ovf);
            end
        end
    endtask

    integer i;
    initial begin
        $dumpfile("addsub.vcd");
        $dumpvars(0, tb);
        a = 0; b = 0; sub = 0;
        #10;

        // Hand-picked cases
        check(16'sd100,    16'sd23,     0);   //   123
        check(16'sd100,    16'sd23,     1);   //    77
        check(16'sd23,     16'sd100,    1);   //   -77
        check(-16'sd500,   16'sd200,    0);   //  -300
        check(-16'sd500,  -16'sd200,    1);   //  -300
        check(16'sd0,      16'sd0,      1);   //     0 (zero flag)
        check(16'sd1234,   16'sd1234,   1);   //     0
        check(16'sd32767,  16'sd1,      0);   // overflow: wraps to -32768
        check(-16'sd32768, 16'sd1,      1);   // overflow: wraps to 32767
        check(-16'sd32768,-16'sd1,      0);   // overflow
        check(16'sd32767, -16'sd32768,  1);   // overflow
        check(-16'sd1,    -16'sd1,      0);   //    -2

        // Random cases
        for (i = 0; i < 40; i = i + 1)
            check($random, $random, $random & 1);

        #10;
        $display("%0d tests, %0d errors", tests, errors);
        $finish;
    end
endmodule
