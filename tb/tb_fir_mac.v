`timescale 1ns/1ps

// Self-checking testbench for fir_mac.
//
// Feeds every sample of an input .mem file into the filter, waits for each result,
// and compares it with the matching word of an expected .mem file.
//
// Run from the project root (the .mem paths are relative to where vvp starts):
//   iverilog -g2012 -o sim_fir tb/tb_fir_mac.v rtl/fir_mac.v
//   vvp sim_fir                                   # ECG data (default)
//   vvp sim_fir +IN=data/impulse_in.mem +EXP=data/impulse_expected.mem
//   vvp sim_fir +VCD                              # also write tb_fir_mac.vcd for GTKWave
module tb_fir_mac;

    localparam NUM_SAMPLES = 1024;
    localparam TIMEOUT_CLKS = 500;   // max clocks to wait for one output (design needs ~64)

    reg clk = 0;
    reg rst = 1;
    reg in_valid = 0;
    reg signed [15:0] x = 0;
    wire busy;
    wire out_valid;
    wire signed [15:0] y;

    fir_mac dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .x(x),
        .busy(busy),
        .out_valid(out_valid),
        .y(y)
    );

    // 100 MHz clock
    always #5 clk = ~clk;

    reg [15:0] in_mem  [0:NUM_SAMPLES-1];
    reg [15:0] exp_mem [0:NUM_SAMPLES-1];

    reg [1023:0] in_file;
    reg [1023:0] exp_file;

    integer n;
    integer errors;
    integer waited;
    integer latency;
    integer max_latency;
    integer outputs_seen;

    // Count every out_valid pulse; there must be exactly one per input sample.
    always @(posedge clk) begin
        if (out_valid) outputs_seen <= outputs_seen + 1;
    end

    // busy must always be a clean 0 or 1 (an X means two drivers fight over it).
    integer busy_unknown;
    always @(posedge clk) begin
        if (!rst && (busy !== 1'b0) && (busy !== 1'b1)) busy_unknown <= busy_unknown + 1;
    end

    // Wait for the next rising edge, then 1 ns more so registered outputs have settled.
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Offer one sample for exactly one clock, once the filter is not busy.
    task send_sample;
        input [15:0] sample;
        begin
            tick;
            while (busy) tick;
            x = sample;
            in_valid = 1'b1;
            tick;                       // the filter accepted the sample on this edge
            in_valid = 1'b0;
        end
    endtask

    // Wait for out_valid; flag a timeout if the filter hangs.
    task wait_for_output;
        begin
            waited = 0;
            while (!out_valid && waited < TIMEOUT_CLKS) begin
                tick;
                waited = waited + 1;
            end
            latency = waited;
        end
    endtask

    initial begin
        if (!$value$plusargs("IN=%s",  in_file))  in_file  = "data/ecg.mem";
        if (!$value$plusargs("EXP=%s", exp_file)) exp_file = "data/expected.mem";
        if ($test$plusargs("VCD")) begin
            $dumpfile("tb_fir_mac.vcd");
            $dumpvars(0, tb_fir_mac);
        end

        $readmemh(in_file,  in_mem);
        $readmemh(exp_file, exp_mem);

        errors       = 0;
        max_latency  = 0;
        outputs_seen = 0;
        busy_unknown = 0;

        // Reset for a few clocks, then release.
        repeat (3) tick;
        rst = 1'b0;

        for (n = 0; n < NUM_SAMPLES; n = n + 1) begin
            send_sample(in_mem[n]);
            wait_for_output;

            if (!out_valid) begin
                errors = errors + 1;
                $display("FAIL @%0t: sample %0d: no out_valid within %0d clocks", $time, n, TIMEOUT_CLKS);
                $finish;
            end else if (y !== exp_mem[n]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH @%0t: sample %0d  x=%0d  got=%0d (%h)  expected=%0d (%h)",
                             $time, n, $signed(in_mem[n]), y, y, $signed(exp_mem[n]), exp_mem[n]);
            end

            if (latency > max_latency) max_latency = latency;
        end

        // Let the last out_valid pulse be counted, and catch any extra pulses.
        repeat (5) tick;
        if (outputs_seen != NUM_SAMPLES) begin
            errors = errors + 1;
            $display("FAIL: saw %0d out_valid pulses, expected %0d", outputs_seen, NUM_SAMPLES);
        end

        if (busy_unknown != 0) begin
            errors = errors + 1;
            $display("FAIL: busy was X/Z on %0d clocks (check for two assigns to busy)", busy_unknown);
        end

        $display("---- %0s vs %0s", in_file, exp_file);
        $display("samples=%0d  mismatches=%0d  out_valid pulses=%0d  max wait after accept=%0d clocks",
                 NUM_SAMPLES, errors, outputs_seen, max_latency);
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    // Safety stop in case something deadlocks outside the per-sample timeout.
    initial begin
        #2000000000;
        $display("FAIL: global timeout");
        $finish;
    end

endmodule
