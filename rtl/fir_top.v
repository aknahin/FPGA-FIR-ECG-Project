`timescale 1ns/1ps

// Top level for the FPGA FIR ECG demonstration (Digilent Nexys 3, 100 MHz clock).
//
// What it does, step by step:
//   1. sample_strobe gives one pulse every 1/360 s.
//   2. On each pulse the next noisy ECG sample is read from ROM and sent into the FIR filter (fir_mac).
//   3. When the filter has its output, it is compared with the Python reference value from a second ROM.
//   4. The result is also sent to the PC as one UDP packet over Ethernet.
//   5. After 1024 samples the run is finished: LEDs show PASS / FAIL, and the run starts again (unless SW1 = 1).
//
// LEDs:  led[0] running   led[1] done   led[2] PASS   led[3] FAIL   led[7:4] mismatch count (max 15)
// Switches: SW0 = fast (feed samples much faster than 360 Hz; Ethernet frames will be dropped)
//           SW1 = once (stop after one run instead of repeating)
// Button:   BTNU = reset / restart
//
// UDP packet payload (20 bytes, multi-byte values are little-endian):
//   byte 0      0xEC (marker)
//   byte 1      flags: bit0 = output equals reference, bit1 = last sample of the run
//   bytes 2-3   sample number 0..1023
//   bytes 4-5   filtered output y from the FPGA (signed 16 bit)
//   bytes 6-7   reference output from Python (signed 16 bit)
//   bytes 8-9   noisy input sample (signed 16 bit)
//   bytes 10-19 zero (padding so the Ethernet frame reaches its minimum size)
module fir_top #(
    parameter STROBE_PERIOD = 277778,        // 100 MHz / 360 Hz
    parameter FAST_PERIOD   = 200,           // must be well above the filter's 66 clocks per sample
    parameter HOLD_CLOCKS   = 67108864,      // pause between runs: 2^26 clocks = 0.67 s
    parameter PHY_RESET_CLOCKS = 1000000,    // hold the Ethernet PHY in reset for 10 ms
    parameter ECG_FILE      = "data/ecg.mem",
    parameter EXP_FILE      = "data/expected.mem",
    parameter COEFF_FILE    = "data/coeff.mem",
    parameter NUM_SAMPLES   = 1024
) (
    input        clk,                        // 100 MHz
    input        btn_up,                     // reset / restart (BTNU)
    input        fast,                       // SW0
    input        once,                       // SW1
    output [7:0] led,
    // Ethernet PHY (MII, transmit side only)
    input        phy_tx_clk,
    output [3:0] phy_txd,
    output       phy_tx_en,
    output       phy_tx_er,
    output reg   phy_rstn = 1'b0,
    output       phy_mdc
);

    // ---------------- reset button: two flip-flops so it is synchronous to clk ----------------
    reg rst_s1 = 1'b0, rst_s2 = 1'b0;
    always @(posedge clk) begin
        rst_s1 <= btn_up;
        rst_s2 <= rst_s1;
    end
    wire rst = rst_s2;

    // ---------------- sample strobe: 360 Hz (or fast) ----------------
    wire strobe;
    wire [19:0] period = fast ? FAST_PERIOD : STROBE_PERIOD;
    sample_strobe u_strobe (.clk(clk), .rst(rst), .period(period), .strobe(strobe));

    // ---------------- ROMs: noisy input and Python reference output, both addressed by idx ----------------
    reg  [9:0]  idx = 10'd0;
    wire [15:0] ecg_q, exp_q;
    ecg_rom #(.FILE(ECG_FILE)) u_ecg (.clk(clk), .addr(idx), .q(ecg_q));
    ecg_rom #(.FILE(EXP_FILE)) u_exp (.clk(clk), .addr(idx), .q(exp_q));

    // ---------------- the FIR filter ----------------
    reg                in_valid = 1'b0;
    reg  signed [15:0] x        = 16'sd0;
    wire               busy, out_valid;
    wire signed [15:0] y;
    reg                restart = 1'b0;        // one-clock pulse when a new run starts: clears the filter history
    wire               fir_rst = rst | restart;
    fir_mac #(.COEFF_FILE(COEFF_FILE)) u_fir (
        .clk(clk), .rst(fir_rst), .in_valid(in_valid), .x(x),
        .busy(busy), .out_valid(out_valid), .y(y)
    );

    // ---------------- control: feed a sample, wait for the result, check it, send it ----------------
    reg        waiting  = 1'b0;      // a sample is inside the filter
    reg        done     = 1'b0;
    reg        overrun  = 1'b0;      // a strobe arrived while the filter was busy (must never happen)
    reg [7:0]  errors   = 8'd0;
    reg [26:0] hold_cnt = 27'd0;

    // values copied for the Ethernet packet
    reg        pkt_send = 1'b0;
    reg [15:0] pkt_idx  = 16'd0, pkt_y = 16'd0, pkt_exp = 16'd0, pkt_x = 16'd0;
    reg [1:0]  pkt_flags = 2'd0;

    always @(posedge clk) begin
        in_valid <= 1'b0;            // default: one-clock pulses
        pkt_send <= 1'b0;
        restart  <= 1'b0;

        if (rst) begin
            idx      <= 10'd0;
            waiting  <= 1'b0;
            done     <= 1'b0;
            overrun  <= 1'b0;
            errors   <= 8'd0;
            hold_cnt <= 27'd0;
        end else if (done) begin
            // run finished: wait a little, then start again unless SW1 is up
            if (!once) begin
                if (hold_cnt >= HOLD_CLOCKS - 1) begin
                    restart  <= 1'b1;        // the Python reference starts from an empty history, so the filter must too
                    idx      <= 10'd0;
                    done     <= 1'b0;
                    errors   <= 8'd0;
                    overrun  <= 1'b0;
                    hold_cnt <= 27'd0;
                end else begin
                    hold_cnt <= hold_cnt + 27'd1;
                end
            end
        end else if (!waiting) begin
            if (strobe) begin
                if (busy) begin
                    overrun <= 1'b1;
                end else begin
                    x        <= ecg_q;       // the ROMs have had many clocks to settle on mem[idx]
                    in_valid <= 1'b1;
                    waiting  <= 1'b1;
                end
            end
        end else if (out_valid) begin
            // the filter has finished this sample
            if (y !== exp_q && errors != 8'd255) errors <= errors + 8'd1;
            pkt_send  <= 1'b1;
            pkt_idx   <= {6'd0, idx};
            pkt_y     <= y;
            pkt_exp   <= exp_q;
            pkt_x     <= x;
            pkt_flags <= {(idx == NUM_SAMPLES - 1), (y === exp_q)};
            waiting   <= 1'b0;
            if (idx == NUM_SAMPLES - 1) done <= 1'b1;
            else                        idx  <= idx + 10'd1;
        end
    end

    // ---------------- LEDs ----------------
    wire pass = done && (errors == 8'd0) && !overrun;
    wire fail = (errors != 8'd0) || overrun;

    assign led[0]   = !done;
    assign led[1]   = done;
    assign led[2]   = pass;
    assign led[3]   = fail;
    assign led[7:4] = (errors > 8'd15) ? 4'd15 : errors[3:0];

    // ---------------- Ethernet output ----------------
    // The PHY must be held in reset for a while after power-up.
    reg [19:0] phy_timer = 20'd0;
    always @(posedge clk) begin
        if (!phy_rstn) begin
            if (phy_timer == PHY_RESET_CLOCKS - 1) phy_rstn <= 1'b1;
            else                                   phy_timer <= phy_timer + 20'd1;
        end
    end
    assign phy_tx_er = 1'b0;
    assign phy_mdc   = 1'b0;         // PHY registers stay at their power-on settings

    wire eth_ready;
    wire eth_sent_toggle;            // flips after every frame (not used)
    wire [159:0] payload = {80'd0, pkt_x, pkt_exp, pkt_y, pkt_idx, 6'd0, pkt_flags, 8'hEC};

    eth_udp_tx #(.PAYLOAD_BYTES(20)) u_eth (
        .clk(clk), .send(pkt_send), .payload(payload), .ready(eth_ready),
        .mii_tx_clk(phy_tx_clk), .mii_txd(phy_txd), .mii_tx_en(phy_tx_en),
        .sent_toggle(eth_sent_toggle)
    );

endmodule
