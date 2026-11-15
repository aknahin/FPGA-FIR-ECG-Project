`timescale 1ns/1ps

// Self-checking testbench for the whole design (fir_top): ROM -> strobe -> FIR -> comparison -> Ethernet frames.
// The testbench also plays the role of the Ethernet PHY: it supplies the 25 MHz TX clock and decodes every frame
// that the design sends, checking headers, payload, sample number, values and the Ethernet CRC.
//
//   iverilog -g2012 -o sim_top tb/tb_fir_top.v rtl/fir_top.v rtl/fir_mac.v rtl/sample_strobe.v rtl/ecg_rom.v rtl/eth_udp_tx.v
//   vvp sim_top                      # real ECG data
//   vvp sim_top +VCD                 # also write tb_fir_top.vcd for GTKWave
// Another vector (negative test with wrong reference data):
//   iverilog ... -P tb_fir_top.EXP_FILE=\"data/impulse_expected.mem\" -P tb_fir_top.EXPECT_PASS=0 ...
module tb_fir_top;

    parameter ECG_FILE    = "data/ecg.mem";
    parameter EXP_FILE    = "data/expected.mem";
    parameter EXPECT_PASS = 1;           // set to 0 when EXP_FILE is deliberately wrong

    reg clk = 0;
    reg btn_up = 1;
    reg fast = 0;
    reg once = 0;
    reg phy_tx_clk = 0;
    wire [7:0] led;
    wire [3:0] phy_txd;
    wire phy_tx_en, phy_tx_er, phy_rstn, phy_mdc;

    // The strobe period is longer than on the board so that every Ethernet frame (about 6 us) fits between samples.
    fir_top #(
        .STROBE_PERIOD(1000), .FAST_PERIOD(200), .HOLD_CLOCKS(20000), .PHY_RESET_CLOCKS(100),
        .ECG_FILE(ECG_FILE), .EXP_FILE(EXP_FILE)
    ) dut (
        .clk(clk), .btn_up(btn_up), .fast(fast), .once(once), .led(led),
        .phy_tx_clk(phy_tx_clk), .phy_txd(phy_txd), .phy_tx_en(phy_tx_en),
        .phy_tx_er(phy_tx_er), .phy_rstn(phy_rstn), .phy_mdc(phy_mdc)
    );

    always #5  clk = ~clk;               // 100 MHz
    always #20 phy_tx_clk = ~phy_tx_clk; // 25 MHz, as from the PHY at 100 Mb/s

    // The reference data, loaded again here so the testbench checks the frames independently of the design.
    reg [15:0] ref_mem [0:1023];
    reg [15:0] in_mem  [0:1023];
    initial begin
        $readmemh(EXP_FILE, ref_mem);
        $readmemh(ECG_FILE, in_mem);
    end

    // ------------------------------------------------------------------
    // Ethernet frame receiver (plays the PHY/PC side)
    // ------------------------------------------------------------------
    reg [3:0]  nib [0:511];
    integer    nn = 0;
    reg        in_frame = 0;
    integer    frames = 0, frame_errors = 0, value_mismatches = 0;
    reg        seen [0:1023];
    integer    k;
    initial for (k = 0; k < 1024; k = k + 1) seen[k] = 0;

    function [7:0] frame_byte;           // byte j after the preamble; low nibble comes first
        input integer j;
        begin
            frame_byte = {nib[16 + 2*j + 1], nib[16 + 2*j]};
        end
    endfunction

    reg [31:0] crc;
    integer    j, b;
    reg [31:0] fcs_rx;
    reg [15:0] r_idx, r_y, r_exp, r_x;
    reg [7:0]  r_flags;

    task check_frame;
        begin
            frames = frames + 1;
            // length: 16 preamble nibbles + 62 bytes + 8 FCS nibbles = 148 nibbles
            if (nn != 148) begin
                frame_errors = frame_errors + 1;
                $display("FRAME ERROR: %0d nibbles, expected 148", nn);
            end else begin
                // CRC over bytes 0..61 (headers + payload), compared with the transmitted FCS
                crc = 32'hffffffff;
                for (j = 0; j < 62; j = j + 1)
                    for (b = 0; b < 8; b = b + 1)
                        crc = (crc[0] ^ frame_byte(j) >> b & 1'b1) ? (crc >> 1) ^ 32'hedb88320 : crc >> 1;
                crc = ~crc;
                fcs_rx = {frame_byte(65), frame_byte(64), frame_byte(63), frame_byte(62)};
                if (crc !== fcs_rx) begin
                    frame_errors = frame_errors + 1;
                    $display("FRAME ERROR: bad CRC, computed %h, received %h", crc, fcs_rx);
                end
                // Ethernet type IPv4, UDP destination port 5005
                if ({frame_byte(12), frame_byte(13)} !== 16'h0800 ||
                    {frame_byte(36), frame_byte(37)} !== 16'd5005) begin
                    frame_errors = frame_errors + 1;
                    $display("FRAME ERROR: wrong EtherType or UDP port");
                end
                // payload starts at byte 42
                r_flags = frame_byte(43);
                r_idx   = {frame_byte(45), frame_byte(44)};
                r_y     = {frame_byte(47), frame_byte(46)};
                r_exp   = {frame_byte(49), frame_byte(48)};
                r_x     = {frame_byte(51), frame_byte(50)};
                if (frame_byte(42) !== 8'hEC || r_idx > 1023) begin
                    frame_errors = frame_errors + 1;
                    $display("FRAME ERROR: bad marker or sample number (%0d)", r_idx);
                end else begin
                    if (seen[r_idx]) begin
                        frame_errors = frame_errors + 1;
                        $display("FRAME ERROR: sample %0d sent twice", r_idx);
                    end
                    seen[r_idx] = 1;
                    // the payload must match the independent reference and the input ROM
                    if (r_exp !== ref_mem[r_idx] || r_x !== in_mem[r_idx] || r_y !== ref_mem[r_idx]) begin
                        value_mismatches = value_mismatches + 1;
                        if (value_mismatches <= 5)
                            $display("VALUE MISMATCH sample %0d: y=%h exp=%h ref=%h x=%h", r_idx, r_y, r_exp, ref_mem[r_idx], r_x);
                    end
                end
            end
        end
    endtask

    always @(posedge phy_tx_clk) begin
        if (phy_tx_en) begin
            nib[nn] = phy_txd;
            nn = nn + 1;
            in_frame = 1;
        end else if (in_frame) begin
            in_frame = 0;
            check_frame;
            nn = 0;
        end
    end

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    integer errors = 0;
    integer waited;
    integer all_seen;

    initial begin
        if ($test$plusargs("VCD")) begin
            $dumpfile("tb_fir_top.vcd");
            $dumpvars(0, tb_fir_top);
        end

        repeat (10) @(posedge clk);
        btn_up = 0;

        // Wait for "done" (led[1]); 1024 samples * 1000 clocks = 1.02 M clocks.
        waited = 0;
        while (!led[1] && waited < 3000000) begin
            @(posedge clk);
            waited = waited + 1;
        end
        repeat (3000) @(posedge clk);    // let the last Ethernet frame finish

        if (!led[1]) begin
            errors = errors + 1;
            $display("FAIL: the run never finished");
        end else begin
            $display("run finished after %0d clocks: pass_led=%b fail_led=%b mismatch_count=%0d",
                     waited, led[2], led[3], led[7:4]);
            if (EXPECT_PASS) begin
                if (led[2] !== 1'b1 || led[3] !== 1'b0 || led[7:4] !== 4'd0) begin
                    errors = errors + 1;
                    $display("FAIL: expected PASS on the LEDs");
                end else $display("PASS: LEDs show PASS");
            end else begin
                if (led[2] !== 1'b0 || led[3] !== 1'b1) begin
                    errors = errors + 1;
                    $display("FAIL: wrong reference data was not detected");
                end else $display("PASS (negative test): the mismatches were detected");
            end
        end

        // Ethernet: one frame per sample, all frames correct
        all_seen = 1;
        for (k = 0; k < 1024; k = k + 1) if (!seen[k]) all_seen = 0;
        $display("Ethernet: %0d frames received, %0d frame errors, %0d value mismatches, all 1024 samples seen: %0d",
                 frames, frame_errors, value_mismatches, all_seen);
        if (frames !== 1024 || frame_errors != 0 || !all_seen) begin
            errors = errors + 1;
            $display("FAIL: Ethernet output");
        end else if (EXPECT_PASS && value_mismatches != 0) begin
            errors = errors + 1;
            $display("FAIL: Ethernet values differ from the reference");
        end else $display("PASS: Ethernet output");

        // With SW1 down the design must start the next run by itself after the pause.
        waited = 0;
        while (led[1] && waited < 30000) begin
            @(posedge clk);
            waited = waited + 1;
        end
        if (led[1]) begin
            errors = errors + 1;
            $display("FAIL: the design did not restart");
        end else $display("PASS: the design restarted by itself after %0d clocks", waited);

        // Second run: the filter history must start from zero again, so the output is identical to the first run.
        for (k = 0; k < 1024; k = k + 1) seen[k] = 0;
        frames = 0; frame_errors = 0; value_mismatches = 0;
        waited = 0;
        while (!led[1] && waited < 3000000) begin
            @(posedge clk);
            waited = waited + 1;
        end
        repeat (3000) @(posedge clk);
        all_seen = 1;
        for (k = 0; k < 1024; k = k + 1) if (!seen[k]) all_seen = 0;
        $display("second run: %0d frames, %0d frame errors, %0d value mismatches, all samples seen: %0d, mismatch_count=%0d",
                 frames, frame_errors, value_mismatches, all_seen, led[7:4]);
        if (frames !== 1024 || frame_errors != 0 || !all_seen || (EXPECT_PASS && (value_mismatches != 0 || led[2] !== 1'b1))) begin
            errors = errors + 1;
            $display("FAIL: second run differs from the first (stale filter history?)");
        end else $display("PASS: second run is identical (history was cleared at restart)");

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #200000000;
        $display("FAIL: global timeout");
        $finish;
    end

endmodule
