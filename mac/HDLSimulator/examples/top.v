// Top level: a counter drives a UART transmitter and an adder.
`timescale 1ns/1ps

module top (
    input  wire       clk,
    input  wire       rst_n,
    output wire       tx,
    output wire [3:0] sum,
    output wire       carry
);
    wire [7:0] count;
    wire       wrap;
    wire       busy;

    counter #(
        .WIDTH (8)
    ) u_counter (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (1'b1),
        .count (count),
        .wrap  (wrap)
    );

    uart_tx #(
        .CLKS_PER_BIT (4)
    ) u_uart (
        .clk   (clk),
        .rst   (~rst_n),
        .start (wrap),
        .data  (count),
        .tx    (tx),
        .busy  (busy)
    );

    ripple_adder u_adder (
        .a    (count[3:0]),
        .b    (count[7:4]),
        .cin  (1'b0),
        .sum  (sum),
        .cout (carry)
    );
endmodule
