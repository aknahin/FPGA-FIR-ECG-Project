`timescale 1ns/1ps

// Sample strobe: one clock-wide pulse every `period` clocks.
// 100 MHz / 360 Hz = 277,778 clocks. This is a clock *enable*, not a slower clock:
// everything else keeps running on the 100 MHz clock and just acts when strobe is high.
module sample_strobe (
    input             clk,
    input             rst,        // synchronous, active-high
    input      [19:0] period,     // clocks between pulses (must be at least 2)
    output reg        strobe = 1'b0
);

    reg [19:0] cnt = 20'd0;

    always @(posedge clk) begin
        strobe <= 1'b0;
        if (rst) begin
            cnt <= 20'd0;
        end else if (cnt >= period - 20'd1) begin   // >= keeps it safe if period changes mid-count
            cnt    <= 20'd0;
            strobe <= 1'b1;
        end else begin
            cnt <= cnt + 20'd1;
        end
    end

endmodule
