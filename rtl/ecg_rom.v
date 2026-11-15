`timescale 1ns/1ps

// 1024 x 16 ROM initialised from a .mem file (one 4-digit hex word per line).
// The read is synchronous: q shows mem[addr] one clock AFTER addr is presented,
// which is what lets the FPGA tools map this onto block RAM.
// Used twice in fir_top: once for the ECG input samples, once for the expected outputs.
module ecg_rom #(
    parameter FILE  = "data/ecg.mem",
    parameter DEPTH = 1024,
    parameter AW    = 10
) (
    input             clk,
    input  [AW-1:0]   addr,
    output reg [15:0] q
);

    reg [15:0] mem [0:DEPTH-1];

    initial $readmemh(FILE, mem);

    always @(posedge clk) begin
        q <= mem[addr];
    end

endmodule
