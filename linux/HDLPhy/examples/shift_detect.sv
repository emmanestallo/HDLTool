// Serial pattern detector (SystemVerilog). Raises `found` after seeing 1011.
module shift_detect (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       din,
    output logic       found,
    output logic [3:0] window
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) window <= '0;
        else        window <= {window[2:0], din};
    end
    assign found = (window == 4'b1011);
endmodule
