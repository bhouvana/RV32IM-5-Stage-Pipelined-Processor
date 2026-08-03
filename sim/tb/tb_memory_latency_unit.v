`include "MemoryLatencyModel.v"

// docs/adr/0024-variable-latency-memory.md (Phase I1). Standalone test for
// MemoryLatencyModel.v, independent of the pipeline -- three DUT instances
// (LATENCY=0/1/4) exercised in parallel against the same clock, mirroring
// this project's own "small standalone-first, own testbench" precedent
// (Tlb.v/Ptw.v/ICache.v/DCache.v/Bht.v/Btb.v all got this before any
// pipeline wiring touched them).
//
// Sampling discipline: set an input at @(negedge clk), then check outputs
// at @(posedge clk); #1 -- the same discipline tb_dcache_unit.v's own
// do_read/do_write tasks already established, since busy/done are
// registered outputs that only update ON a posedge, not immediately after
// an input changes.
module tb_memory_latency_unit;
    reg clk = 0;
    reg rst = 0;

    reg start0 = 0, start1 = 0, start4 = 0;
    wire busy0, done0, busy1, done1, busy4, done4;

    MemoryLatencyModel #(.LATENCY(0)) dut0(.clk(clk), .rst(rst), .start(start0), .busy(busy0), .done(done0));
    MemoryLatencyModel #(.LATENCY(1)) dut1(.clk(clk), .rst(rst), .start(start1), .busy(busy1), .done(done1));
    MemoryLatencyModel #(.LATENCY(4)) dut4(.clk(clk), .rst(rst), .start(start4), .busy(busy4), .done(done4));

    always #5 clk = ~clk;

    integer fails = 0;
    integer checks = 0;

    task check_bit;
        input actual, expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: %b, expected %b", label, actual, expected);
            end else begin
                $display("pass  %0s: %b", label, actual);
            end
        end
    endtask

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // -- LATENCY=0: done pulses the SAME cycle as start (combinational passthrough) --
        @(negedge clk);
        start0 = 1;
        #1;
        check_bit(done0, 1'b1, "LATENCY=0: done pulses same cycle as start");
        check_bit(busy0, 1'b0, "LATENCY=0: busy stays tied 0");
        @(negedge clk);
        start0 = 0;
        #1;
        check_bit(done0, 1'b0, "LATENCY=0: done deasserts once start deasserts");

        // -- LATENCY=1: done pulses exactly 1 cycle after start, not same-cycle --
        @(negedge clk);
        start1 = 1;
        @(posedge clk); #1;
        check_bit(busy1, 1'b1, "LATENCY=1: busy asserted the posedge start was seen");
        check_bit(done1, 1'b0, "LATENCY=1: done NOT yet asserted that same posedge");
        @(negedge clk);
        start1 = 0;
        @(posedge clk); #1;
        check_bit(done1, 1'b1, "LATENCY=1: done pulses exactly 1 cycle after start");
        check_bit(busy1, 1'b0, "LATENCY=1: busy clears the cycle done pulses");
        @(posedge clk); #1;
        check_bit(done1, 1'b0, "LATENCY=1: done is a one-cycle pulse, not held");

        // -- LATENCY=4: done pulses exactly 4 cycles after start, busy held throughout --
        @(negedge clk);
        start4 = 1;
        @(posedge clk); #1;   // E0: start&&!busy accepted
        check_bit(busy4, 1'b1, "LATENCY=4: busy asserted the posedge start was seen");
        @(negedge clk);
        start4 = 0;   // one-shot start pulse; busy/count must hold the wait regardless
        @(posedge clk); #1;   // E1: 1 cycle in
        check_bit(busy4, 1'b1, "LATENCY=4: busy still held 1 cycle in");
        check_bit(done4, 1'b0, "LATENCY=4: done not yet asserted 1 cycle in");
        @(posedge clk); #1;   // E2: 2 cycles in
        check_bit(busy4, 1'b1, "LATENCY=4: busy still held 2 cycles in");
        @(posedge clk); #1;   // E3: 3 cycles in
        check_bit(busy4, 1'b1, "LATENCY=4: busy still held 3 cycles in");
        @(posedge clk); #1;   // E4: done pulses
        check_bit(done4, 1'b1, "LATENCY=4: done pulses exactly 4 cycles after start");
        check_bit(busy4, 1'b0, "LATENCY=4: busy clears the cycle done pulses");

        // -- A start pulse arriving WHILE busy is ignored, not restarted --
        @(negedge clk);
        start4 = 1;
        @(posedge clk); #1;   // E0
        @(negedge clk);
        start4 = 1;   // spurious re-assert mid-count -- must NOT restart the 4-cycle wait
        @(posedge clk); #1;   // E1
        check_bit(busy4, 1'b1, "LATENCY=4 re-trigger test: still busy 1 cycle in (spurious start ignored)");
        @(negedge clk); start4 = 0;
        @(posedge clk); #1;   // E2
        @(posedge clk); #1;   // E3
        @(posedge clk); #1;   // E4
        check_bit(done4, 1'b1, "LATENCY=4 re-trigger test: done still lands on the ORIGINAL 4th cycle, not restarted");

        // -- Back-to-back: a fresh start right after done completes a full new wait --
        @(negedge clk);
        start1 = 1;
        @(posedge clk); #1;   // E0
        @(negedge clk);
        start1 = 0;
        @(posedge clk); #1;   // E1: done pulses
        check_bit(done1, 1'b1, "LATENCY=1 back-to-back: first wait completes normally");
        @(negedge clk);
        start1 = 1;   // busy is clear again (done pulsed last cycle) -- this is a genuine new request
        @(posedge clk); #1;
        check_bit(busy1, 1'b1, "LATENCY=1 back-to-back: second request accepted (not stuck busy from first)");
        @(negedge clk);
        start1 = 0;
        @(posedge clk); #1;
        check_bit(done1, 1'b1, "LATENCY=1 back-to-back: second wait also completes after exactly 1 cycle");

        if (fails == 0)
            $display("PASS  memory_latency_unit (%0d checks)", checks);
        else
            $display("FAIL  memory_latency_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
