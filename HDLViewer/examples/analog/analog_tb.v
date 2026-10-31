// Mixed-signal style test signals for HDL Viewer's analog display.
// Run:  iverilog -o sim analog_tb.v && vvp sim     (writes analog.vcd)
//
// In the viewer, right-click a bus → Display:
//   Analog Unsigned : code / 2^N        →  0 … 1   (e.g. a unipolar DAC)
//   Analog Signed   : code / 2^(N-1)    → -1 … +1  (two's complement, Q1.(N-1))
`timescale 1ns/1ps

module tb;
    reg clk = 0;
    always #5 clk = ~clk;                       // 100 MHz sample clock

    reg  [11:0]        dac_code  = 0;           // unsigned 12-bit triangle ramp
    reg                ramp_up   = 1;
    reg  signed [15:0] sine_q15  = 0;           // signed 16-bit sine, ~0.95 FS
    reg  signed [7:0]  noise_s8  = 0;           // signed 8-bit noisy sine
    reg  [9:0]         adc_code;                // unsigned 10-bit, X until calibrated
    reg  signed [15:0] fs_test   = 0;           // full-scale edge cases
    real               vin       = 0.0;         // real-valued node (auto range)

    real phase = 0.0;
    localparam real TWO_PI = 6.283185307179586;
    integer n = 0;

    always @(posedge clk) begin
        n <= n + 1;
        phase = phase + TWO_PI / 64.0;          // 64 samples per sine period

        // Triangle ramp, 64 LSB per sample.
        if (ramp_up) begin
            if (dac_code >= 12'd4095 - 64) begin dac_code <= 12'd4095; ramp_up <= 0; end
            else dac_code <= dac_code + 64;
        end else begin
            if (dac_code <= 64) begin dac_code <= 0; ramp_up <= 1; end
            else dac_code <= dac_code - 64;
        end

        sine_q15 <= $rtoi(0.95 * 32767.0 * $sin(phase));
        noise_s8 <= $rtoi(90.0 * $sin(phase / 3.0)) + ($random % 20);
        vin       = 1.65 + 1.2 * $sin(phase / 2.0);

        if (n > 40) adc_code <= $rtoi(511.5 + 500.0 * $sin(phase / 2.0));
        if (n > 300 && n < 320) adc_code <= 10'bx;   // dropout
    end

    initial begin
        $dumpfile("analog.vcd");
        $dumpvars(0, tb);
        // Exact full-scale codes on fs_test:
        #100  fs_test = 16'sh7FFF;   // +0.99997 (max positive)
        #100  fs_test = 16'sh4000;   // +0.5
        #100  fs_test = 16'sh0000;   //  0
        #100  fs_test = 16'shC000;   // -0.5
        #100  fs_test = 16'sh8000;   // -1.0 (min negative)
        #100  fs_test = 16'sh0000;
        #4400 $finish;
    end
endmodule
