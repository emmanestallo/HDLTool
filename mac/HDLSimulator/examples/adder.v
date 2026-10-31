// Ripple-carry adder written in the older (non-ANSI) port style.
`define ADD_W 4

module full_adder(a, b, cin, sum, cout);
    input  a, b, cin;
    output sum, cout;
    assign sum  = a ^ b ^ cin;
    assign cout = (a & b) | (cin & (a ^ b));
endmodule

module ripple_adder(a, b, cin, sum, cout);
    input  [`ADD_W-1:0] a;
    input  [`ADD_W-1:0] b;
    input               cin;
    output [`ADD_W-1:0] sum;
    output              cout;

    wire [`ADD_W:0] c;
    assign c[0] = cin;
    assign cout = c[`ADD_W];

    genvar i;
    generate
        for (i = 0; i < `ADD_W; i = i + 1) begin : stage
            full_adder fa (.a(a[i]), .b(b[i]), .cin(c[i]), .sum(sum[i]), .cout(c[i+1]));
        end
    endgenerate
endmodule
