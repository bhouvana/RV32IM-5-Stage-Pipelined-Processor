`include "ICache.v"
`include "InstructionMemory.v"
`include "MemoryLatencyModel.v"

// docs/adr/0023-caches.md (Phase G2). Standalone unit test for ICache.v,
// independent of the pipeline. Deliberately instantiated SMALL (2-way,
// 32B total, 8B lines -> 2 sets, 2 ways/set, 2 words/line) rather than the
// real 4-way/4KB/16B default -- at the real size this core's tiny test
// programs would essentially never evict or alias anything, so the small
// override exists specifically to force conflict misses, fill, and
// round-robin replacement/eviction through their paces (see the ADR's
// testbench-sizing note). Backing InstructionMemory content is poked
// directly via a hierarchical reference (dut.m_imem.insts[...]) rather than
// an INIT_FILE, so this test owns exact control over every word's value at
// every address without needing a separate fixture .mem file.
//
// Address layout at this sizing (OFFSET_BITS=3, SET_BITS=1, byte addresses):
//   addr 0/4   -> set0, tag0 (line A, words0-1)
//   addr 8/12  -> set1, tag0 (line B, words2-3) -- independent set
//   addr 16/20 -> set0, tag1 (line C, words4-5)
//   addr 32/36 -> set0, tag2 (line E, words8-9) -- 3rd distinct tag in
//                 set0's 2-way set, forces round-robin eviction
module tb_icache_unit;
    reg clk = 0;
    reg rst = 0;
    reg [31:0] readAddr = 0;
    wire [31:0] inst_o;
    wire hit_o, busy_o, done_o;

    ICache #(.INIT_FILE(""), .IMEM_SIZE_BYTES(64), .XLEN(32),
             .WAYS(2), .CACHE_SIZE_BYTES(32), .LINE_BYTES(8)) dut(
        .clk(clk), .rst(rst), .readAddr(readAddr),
        .inst(inst_o), .hit(hit_o), .busy(busy_o), .done(done_o)
    );

    // docs/adr/0024-variable-latency-memory.md (Phase I4). A second, small
    // instance with MEM_LATENCY>0 -- proves the fill engine still produces
    // correct data (not just correct timing) under real per-word
    // wait-states, and that fill genuinely takes multiple cycles per word
    // rather than being a silent no-op.
    // A dedicated, independent reset (not shared with dut/rst) -- dut2's
    // sub-test runs AFTER dut's own long test sequence has already
    // consumed many real clock edges, and dut2 free-runs against its own
    // default readAddr2=0 the whole time like any other module; without
    // its own reset to re-trigger right at the point of its own sub-test,
    // it would auto-fill with stale pre-poke content long before the test
    // ever gets to poking or checking it.
    localparam MEM_LATENCY_TEST = 3;
    reg rst2 = 0;
    reg [31:0] readAddr2 = 0;
    wire [31:0] inst_o2;
    wire hit_o2, busy_o2, done_o2;
    ICache #(.INIT_FILE(""), .IMEM_SIZE_BYTES(64), .XLEN(32),
             .WAYS(2), .CACHE_SIZE_BYTES(32), .LINE_BYTES(8),
             .MEM_LATENCY(MEM_LATENCY_TEST)) dut2(
        .clk(clk), .rst(rst2), .readAddr(readAddr2),
        .inst(inst_o2), .hit(hit_o2), .busy(busy_o2), .done(done_o2)
    );

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

    task check_word;
        input [31:0] actual, expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: 0x%08h, expected 0x%08h", label, actual, expected);
            end else begin
                $display("pass  %0s: 0x%08h", label, actual);
            end
        end
    endtask

    task poke_word;
        input [31:0] addr;
        input [31:0] val;
        begin
            dut.m_imem.insts[addr]   = val[31:24];
            dut.m_imem.insts[addr+1] = val[23:16];
            dut.m_imem.insts[addr+2] = val[15:8];
            dut.m_imem.insts[addr+3] = val[7:0];
        end
    endtask


    // Polls until hit_o goes high or a generous cycle budget (this line
    // size only ever needs LINE_WORDS+1 = 3 edges) is exceeded.
    task wait_ready;
        integer i;
        begin
            i = 0;
            while (!hit_o && i < 10) begin
                @(posedge clk);
                i = i + 1;
            end
        end
    endtask

    function [31:0] val_at;
        input [31:0] addr;
        begin
            val_at = 32'hC0DE_0000 + (addr >> 2);
        end
    endfunction

    // Every readAddr change happens right after a negedge (>=5 time units of
    // margin before the next posedge), so a query is never set close enough
    // to a rising edge to race the DUT's `always @(posedge clk)` sampling of
    // it -- avoids the classic same-timestep testbench hazard entirely,
    // regardless of how much time earlier statements consumed.
    task set_addr;
        input [31:0] addr;
        begin
            @(negedge clk);
            readAddr = addr;
            #1;
        end
    endtask

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        poke_word(0,  val_at(0));
        poke_word(4,  val_at(4));
        poke_word(8,  val_at(8));
        poke_word(12, val_at(12));
        poke_word(16, val_at(16));
        poke_word(20, val_at(20));
        poke_word(32, val_at(32));
        poke_word(36, val_at(36));

        // Cold miss.
        set_addr(0);
        check_bit(hit_o, 1'b0, "cold reset: addr0 misses");

        // Fill line A (set0/tag0, way0): both words land together.
        wait_ready;
        check_bit(hit_o, 1'b1, "addr0 hits after fill");
        check_word(inst_o, val_at(0), "addr0 content correct");
        set_addr(4);
        check_bit(hit_o, 1'b1, "addr4 (same line as addr0) hits with no extra fill");
        check_word(inst_o, val_at(4), "addr4 content correct");

        // Independent set (set1/tag0): cold miss, own fill, no interference.
        set_addr(8);
        check_bit(hit_o, 1'b0, "addr8 (different set) cold-misses");
        wait_ready;
        check_bit(hit_o, 1'b1, "addr8 hits after its own fill");
        check_word(inst_o, val_at(8), "addr8 content correct");

        // Second way of set0 (tag1): cold miss, fills way1, way0 (tag0) untouched.
        set_addr(16);
        check_bit(hit_o, 1'b0, "addr16 (set0, 2nd tag) cold-misses");
        wait_ready;
        check_bit(hit_o, 1'b1, "addr16 hits after fill (way1)");
        check_word(inst_o, val_at(16), "addr16 content correct");
        set_addr(0);
        check_bit(hit_o, 1'b1, "addr0 (way0) still hits, unaffected by way1's fill");

        // Third distinct tag in set0 (tag2): forces round-robin eviction.
        // victim[0] progressed 0->1 (after tag0's fill)->0 (after tag1's
        // fill, wraps at WAYS=2) -- so this fill lands in way0, evicting tag0.
        set_addr(32);
        check_bit(hit_o, 1'b0, "addr32 (set0, 3rd tag) cold-misses");
        wait_ready;
        check_bit(hit_o, 1'b1, "addr32 hits after fill (evicts way0/tag0)");
        check_word(inst_o, val_at(32), "addr32 content correct");
        set_addr(0);
        check_bit(hit_o, 1'b0, "addr0 (tag0) now MISSES: round-robin evicted way0");
        set_addr(16);
        check_bit(hit_o, 1'b1, "addr16 (tag1, way1) still hits: eviction left way1 alone");

        // Independent set8 (tag0/set1) unaffected by all of set0's churn.
        set_addr(8);
        check_bit(hit_o, 1'b1, "addr8 (independent set) still hits after set0's churn");

        // Refill addr0: victim[0] wrapped again after tag2's fill, so this
        // lands in way1, evicting tag1 this time -- proves round-robin
        // continues correctly across a second eviction, not just the first.
        set_addr(0);
        wait_ready;
        check_bit(hit_o, 1'b1, "addr0 refilled (evicts way1/tag1)");
        check_word(inst_o, val_at(0), "addr0 content correct after refill");
        set_addr(16);
        check_bit(hit_o, 1'b0, "addr16 (tag1) now MISSES: 2nd round-robin eviction hit way1");
        set_addr(32);
        check_bit(hit_o, 1'b1, "addr32 (tag2, way0) still hits: 2nd eviction left way0 alone");

        // -- MEM_LATENCY>0 sub-test (dut2): 2 words/line, each word now
        // costs MEM_LATENCY_TEST extra cycles -- confirm the fill genuinely
        // takes that long AND still produces correct data. dut2 gets its
        // OWN fresh reset here (see rst2's own header comment) so its
        // timing is isolated from however many cycles dut's own test
        // sequence above already consumed.
        readAddr2 = 0;
        @(posedge clk); rst2 <= 0;
        @(posedge clk); rst2 <= 1;
        begin : poke2_block
            reg [31:0] w0, w4;
            w0 = val_at(0);
            w4 = val_at(4);
            dut2.m_imem.insts[0] = w0[31:24];
            dut2.m_imem.insts[1] = w0[23:16];
            dut2.m_imem.insts[2] = w0[15:8];
            dut2.m_imem.insts[3] = w0[7:0];
            dut2.m_imem.insts[4] = w4[31:24];
            dut2.m_imem.insts[5] = w4[23:16];
            dut2.m_imem.insts[6] = w4[15:8];
            dut2.m_imem.insts[7] = w4[7:0];
        end

        check_bit(hit_o2, 1'b0, "MEM_LATENCY>0: addr0 cold-misses");
        begin : wait2_block
            integer w, cyc_before, cyc_after;
            cyc_before = 0;
            w = 0;
            while (!hit_o2 && w < 40) begin
                @(posedge clk);
                cyc_before = cyc_before + 1;
                w = w + 1;
            end
            cyc_after = cyc_before;
            checks = checks + 1;
            // 2 words * (LATENCY+1) cycles minimum, generous margin either side.
            if (cyc_after < 2 * (MEM_LATENCY_TEST + 1) || cyc_after > 40) begin
                fails = fails + 1;
                $display("FAIL  MEM_LATENCY>0: fill took %0d cycles, expected roughly %0d (real multi-cycle wait per word)",
                    cyc_after, 2 * (MEM_LATENCY_TEST + 1));
            end else $display("pass  MEM_LATENCY>0: fill took %0d real cycles (matches per-word wait-states, not a no-op)", cyc_after);
        end
        check_bit(hit_o2, 1'b1, "MEM_LATENCY>0: addr0 hits after the (slower) fill");
        check_word(inst_o2, val_at(0), "MEM_LATENCY>0: addr0 content correct despite the wait");
        @(negedge clk); readAddr2 = 4; #1;
        check_bit(hit_o2, 1'b1, "MEM_LATENCY>0: addr4 (same line) hits with no extra fill");
        check_word(inst_o2, val_at(4), "MEM_LATENCY>0: addr4 content correct");

        if (fails == 0)
            $display("PASS  icache_unit (%0d checks)", checks);
        else
            $display("FAIL  icache_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
