// Example design for HDL Viewer.
// Build & run:  iverilog -o sim counter_tb.v && vvp sim   (writes counter.vcd)
`timescale 1ns/1ps

module counter #(parameter W = 8) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         en,
    output reg  [W-1:0] count,
    output wire         wrap
);
    always @(posedge clk or negedge rst_n)
        if (!rst_n)  count <= 0;
        else if (en) count <= count + 1'b1;

    assign wrap = en & (&count);
endmodule

module uart_tx #(parameter CLKS_PER_BIT = 4) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx,
    output reg        busy
);
    localparam IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;
    reg [1:0] state;
    reg [2:0] bit_idx;
    reg [7:0] shreg;
    reg [3:0] clk_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; tx <= 1'b1; busy <= 1'b0; clk_cnt <= 0; bit_idx <= 0;
        end else begin
            case (state)
                IDLE: if (start) begin
                    shreg <= data; busy <= 1'b1; tx <= 1'b0; clk_cnt <= 0; state <= START;
                end
                START: if (clk_cnt == CLKS_PER_BIT - 1) begin
                    clk_cnt <= 0; tx <= shreg[0]; bit_idx <= 0; state <= DATA;
                end else clk_cnt <= clk_cnt + 1;
                DATA: if (clk_cnt == CLKS_PER_BIT - 1) begin
                    clk_cnt <= 0;
                    if (bit_idx == 7) begin tx <= 1'b1; state <= STOP; end
                    else begin bit_idx <= bit_idx + 1; tx <= shreg[bit_idx + 1]; end
                end else clk_cnt <= clk_cnt + 1;
                STOP: if (clk_cnt == CLKS_PER_BIT - 1) begin
                    busy <= 1'b0; state <= IDLE;
                end else clk_cnt <= clk_cnt + 1;
            endcase
        end
    end
endmodule

module tb;
    reg clk = 0;
    always #5 clk = ~clk;              // 100 MHz

    reg        rst_n;
    reg        en;
    reg        start;
    reg  [7:0] tx_data;
    reg        drive;
    reg  [7:0] drive_val;
    wire [7:0] count;
    wire       wrap;
    wire       tx, busy;
    wire [7:0] shared_bus = drive ? drive_val : 8'bz;   // tri-state bus
    reg  [15:0] late_init;                              // stays X for a while
    integer    errors = 0;
    real       temperature = 25.0;

    counter #(.W(8)) u_counter (.clk(clk), .rst_n(rst_n), .en(en), .count(count), .wrap(wrap));
    uart_tx #(.CLKS_PER_BIT(4)) u_uart (.clk(clk), .rst_n(rst_n), .start(start), .data(tx_data),
                                        .tx(tx), .busy(busy));

    always #37 temperature = temperature + 0.75;

    initial begin
        $dumpfile("counter.vcd");
        $dumpvars(0, tb);

        rst_n = 0; en = 0; start = 0; tx_data = 8'h00; drive = 0; drive_val = 8'h00;
        #22 rst_n = 1;
        #20 en = 1;

        @(posedge clk) begin start <= 1; tx_data <= 8'hA5; end
        @(posedge clk) start <= 0;
        #150 late_init = 16'hBEEF;
        drive = 1; drive_val = 8'h3C;
        #80 drive = 0;
        wait (!busy);
        @(posedge clk) begin start <= 1; tx_data <= "H"; end
        @(posedge clk) start <= 0;
        #200 drive = 1; drive_val = 8'hF0;
        #60 drive = 0;
        #1200 en = 0;
        #100 en = 1;
        #900;
        $display("done, count=%0d", count);
        $finish;
    end
endmodule
