`timescale 1ns/1ps

// Testbench for the counter. Press Run (⌘R) to simulate it.
module tb_counter;

    localparam WIDTH = 4;

    reg              clk = 1'b0;
    reg              rst_n = 1'b0;
    reg              en = 1'b0;
    wire [WIDTH-1:0] count;
    wire             wrap;

    always #5 clk = ~clk;

    counter #(
        .WIDTH (WIDTH)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .count (count),
        .wrap  (wrap)
    );

    initial begin
        $dumpfile("tb_counter.vcd");
        $dumpvars(0, tb_counter);

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        en = 1'b1;

        repeat (20) @(posedge clk);
        en = 1'b0;
        repeat (4) @(posedge clk);

        $display("count = %0d at %0t", count, $time);
        $finish;
    end

endmodule
