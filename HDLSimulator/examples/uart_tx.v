// 8N1 UART transmitter. One bit lasts CLKS_PER_BIT clock cycles.
module uart_tx #(
    parameter CLKS_PER_BIT = 4
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx,
    output reg        busy
);
    localparam CW = $clog2(CLKS_PER_BIT);

    reg [CW:0]  clk_cnt;
    reg [3:0]   bit_idx;
    reg [9:0]   shift;

    always @(posedge clk) begin
        if (rst) begin
            tx <= 1'b1;
            busy <= 1'b0;
            clk_cnt <= 0;
            bit_idx <= 0;
        end else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                shift <= {1'b1, data, 1'b0};
                busy <= 1'b1;
                clk_cnt <= 0;
                bit_idx <= 0;
            end
        end else begin
            tx <= shift[bit_idx];
            if (clk_cnt == CLKS_PER_BIT - 1) begin
                clk_cnt <= 0;
                if (bit_idx == 9) busy <= 1'b0;
                else bit_idx <= bit_idx + 1'b1;
            end else begin
                clk_cnt <= clk_cnt + 1'b1;
            end
        end
    end
endmodule
