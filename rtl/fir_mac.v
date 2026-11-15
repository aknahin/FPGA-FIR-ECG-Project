`timescale 1ns/1ps

module fir_mac #(
    parameter NUM_TAPS = 63,
    parameter DATA_W   = 16,
    parameter ACC_W    = 40,
    parameter FRAC     = 15,
    parameter COEFF_FILE = "data/coeff.mem"
) (
    input  clk,
    input  rst,                          // synchronous, active-high
    input  in_valid,
    input  signed [DATA_W-1:0] x,
    output busy,
    output reg out_valid,
    output reg signed [DATA_W-1:0] y
);

    // Internal signals
    reg signed [DATA_W-1:0] coeffs [0:NUM_TAPS-1];
    reg signed [ACC_W-1:0] acc;
    reg [$clog2(NUM_TAPS):0] tap_count;

    // Load coefficients from file
    initial begin
        $readmemh(COEFF_FILE, coeffs);
    end

    localparam IDLE = 2'd0, MAC = 2'd1, OUT = 2'd2, FLUSH = 2'd3;
    reg [1:0] state;
    reg signed [DATA_W-1:0] hist [0:NUM_TAPS-1];
    integer i;

    // Three-stage multiply-accumulate pipeline (a single clock for mux + multiply + 40-bit add was too slow
    // for 100 MHz on the Spartan-6). Tap k is issued in MAC, then flows through:
    //   stage 1: h_r, c_r   operands registered (63:1 history mux and coefficient lookup)
    //   stage 2: p_r        product registered (maps onto a DSP block)
    //   stage 3: acc        product added to the accumulator
    // v1 says that h_r,c_r hold a real tap. p_r is forced to 0 whenever no real tap is flowing, so adding p_r to
    // the accumulator at any time is harmless. (The FPGA tools merge the multiplier and the accumulator into one
    // DSP block and may implement "acc <= 0" as "acc <= 0 + p_r"; a stale p_r would then add one wrong product.)
    // FLUSH waits for the last tap to reach acc.
    reg signed [DATA_W-1:0]   h_r, c_r;
    reg signed [2*DATA_W-1:0] p_r;
    reg v1;

    assign busy = (state != IDLE);

    always @(posedge clk) begin
        out_valid <= 1'b0;                    // default: pulse for one clock only
        if (rst) begin
            state <= IDLE;
            acc <= 0;
            tap_count <= 0;
            y <= 0;
            v1 <= 1'b0;
            p_r <= 0;
            for (i = 0; i < NUM_TAPS; i = i + 1) hist[i] <= 0;
        end else begin
            // MAC pipeline: runs every clock; v1 marks that h_r and c_r hold a real tap
            v1  <= (state == MAC);
            h_r <= hist[tap_count];
            c_r <= coeffs[tap_count];
            p_r <= v1 ? h_r * c_r : 32'sd0;
            acc <= acc + p_r;

            case (state)
                IDLE: if (in_valid) begin
                    for (i = NUM_TAPS-1; i > 0; i = i - 1) hist[i] <= hist[i-1];
                    hist[0] <= x;
                    acc <= 0;
                    tap_count <= 0;
                    state <= MAC;
                end

                MAC: begin                          // issue one tap per clock
                    if (tap_count == NUM_TAPS-1) state <= FLUSH;
                    else tap_count <= tap_count + 1;
                end

                FLUSH: if (!v1) state <= OUT;       // when v1 falls, the last product is in p_r and reaches acc this clock

                OUT: begin
                    // acc now has all 63 products
                    if (acc >>> FRAC > 32767)       y <= 16'sd32767;
                    else if (acc >>> FRAC < -32768) y <= -16'sd32768;
                    else                            y <= (acc >>> FRAC);
                    out_valid <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end
    
endmodule