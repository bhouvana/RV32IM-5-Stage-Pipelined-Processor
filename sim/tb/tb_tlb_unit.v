`include "Tlb.v"

// docs/adr/00NN-mmu-sv32.md (Phase F4). Standalone unit test for Tlb.v,
// independent of the pipeline and of Ptw.v. Covers: cold-miss reset state,
// a fill/lookup round trip on each of the two independent read ports
// (confirming they share one array), permission-bit round trip, an
// overwrite of an existing entry, flush_all clearing everything, and --
// the one behavior that makes this module different from Bht.v/Btb.v's
// own unit tests -- confirming a same-index/different-VPN "alias" that
// would silently hit on an *untagged* table instead correctly MISSES here,
// because the full VPN tag no longer matches after the shared slot is
// overwritten by the other VPN.
module tb_tlb_unit;
    reg clk = 0;
    reg rst = 0;

    reg  [31:0] fetch_vaddr = 0;
    wire        fetch_hit;
    wire [31:0] fetch_ppn;
    wire        fetch_perm_r, fetch_perm_w, fetch_perm_x, fetch_perm_u;

    reg  [31:0] ls_vaddr = 0;
    wire        ls_hit;
    wire [31:0] ls_ppn;
    wire        ls_perm_r, ls_perm_w, ls_perm_x, ls_perm_u;

    reg         fill_valid = 0;
    reg  [31:0] fill_vaddr = 0;
    reg  [31:0] fill_ppn = 0;
    reg         fill_perm_r = 0, fill_perm_w = 0, fill_perm_x = 0, fill_perm_u = 0;
    reg         flush_all = 0;

    integer fails = 0;
    integer checks = 0;

    // NUM_ENTRIES=4 (index = vpn[1:0]) -- small enough to pick an aliasing
    // pair of VPNs by hand, same convention tb_bht_unit.v/tb_btb_unit.v use.
    Tlb #(.XLEN(32), .NUM_ENTRIES(4)) dut(
        .clk(clk), .rst(rst),
        .fetch_vaddr(fetch_vaddr), .fetch_hit(fetch_hit), .fetch_ppn(fetch_ppn),
        .fetch_perm_r(fetch_perm_r), .fetch_perm_w(fetch_perm_w),
        .fetch_perm_x(fetch_perm_x), .fetch_perm_u(fetch_perm_u),
        .ls_vaddr(ls_vaddr), .ls_hit(ls_hit), .ls_ppn(ls_ppn),
        .ls_perm_r(ls_perm_r), .ls_perm_w(ls_perm_w),
        .ls_perm_x(ls_perm_x), .ls_perm_u(ls_perm_u),
        .fill_valid(fill_valid), .fill_vaddr(fill_vaddr), .fill_ppn(fill_ppn),
        .fill_perm_r(fill_perm_r), .fill_perm_w(fill_perm_w),
        .fill_perm_x(fill_perm_x), .fill_perm_u(fill_perm_u),
        .flush_all(flush_all)
    );

    always #5 clk = ~clk;

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

    task fill;
        input [31:0] vaddr;
        input [31:0] ppn;
        input        r, w, x, u;
        begin
            @(posedge clk);
            fill_valid <= 1; fill_vaddr <= vaddr; fill_ppn <= ppn;
            fill_perm_r <= r; fill_perm_w <= w; fill_perm_x <= x; fill_perm_u <= u;
            @(posedge clk);
            fill_valid <= 0;
        end
    endtask

    // VPN(A)=0x1, VPN(C)=0x2 (independent indices), VPN(B)=0x5 (index 1,
    // same as A: 0x1 & 0x3 == 0x5 & 0x3 == 1 -- the aliasing pair).
    localparam [31:0] VADDR_A = 32'h0000_1000;
    localparam [31:0] VADDR_B = 32'h0000_5000;
    localparam [31:0] VADDR_C = 32'h0000_2000;

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Cold reset: every entry misses on both ports.
        fetch_vaddr = VADDR_A; ls_vaddr = VADDR_C;
        #1 check_bit(fetch_hit, 1'b0, "reset: fetch port cold-misses on VADDR_A");
        #0 check_bit(ls_hit, 1'b0, "reset: ls port cold-misses on VADDR_C");

        // Fill VADDR_A; both ports independently see the same shared entry.
        fill(VADDR_A, 32'h0000_00AA, 1'b1, 1'b0, 1'b1, 1'b0);
        fetch_vaddr = VADDR_A;
        #1 check_bit(fetch_hit, 1'b1, "VADDR_A hits on fetch port after fill");
        #0 check_word(fetch_ppn, 32'h0000_00AA, "VADDR_A PPN correct on fetch port");
        #0 check_bit(fetch_perm_r, 1'b1, "VADDR_A perm_r correct on fetch port");
        #0 check_bit(fetch_perm_w, 1'b0, "VADDR_A perm_w correct on fetch port");
        #0 check_bit(fetch_perm_x, 1'b1, "VADDR_A perm_x correct on fetch port");
        #0 check_bit(fetch_perm_u, 1'b0, "VADDR_A perm_u correct on fetch port");
        ls_vaddr = VADDR_A;
        #1 check_bit(ls_hit, 1'b1, "VADDR_A also hits on ls port (shared array)");
        #0 check_word(ls_ppn, 32'h0000_00AA, "VADDR_A PPN correct on ls port too");

        // Independent index: filling VADDR_C must not disturb VADDR_A's entry.
        fill(VADDR_C, 32'h0000_00CC, 1'b1, 1'b1, 1'b0, 1'b1);
        ls_vaddr = VADDR_C;
        #1 check_bit(ls_hit, 1'b1, "VADDR_C hits after its own fill");
        #0 check_word(ls_ppn, 32'h0000_00CC, "VADDR_C PPN correct");
        #0 check_bit(ls_perm_u, 1'b1, "VADDR_C perm_u correct");
        fetch_vaddr = VADDR_A;
        #1 check_bit(fetch_hit, 1'b1, "VADDR_A still hits (unaffected by VADDR_C's fill, different index)");
        #0 check_word(fetch_ppn, 32'h0000_00AA, "VADDR_A PPN unchanged by VADDR_C's fill");

        // The tagged-aliasing behavior a Bht.v/Btb.v-style untagged table
        // could NOT give: VADDR_B shares VADDR_A's index (1) but has a
        // different VPN. Filling VADDR_B overwrites the shared slot; a
        // subsequent VADDR_A lookup must MISS (tag no longer matches),
        // not silently return VADDR_B's translation as if it were its own.
        fill(VADDR_B, 32'h0000_00BB, 1'b0, 1'b1, 1'b0, 1'b1);
        fetch_vaddr = VADDR_B;
        #1 check_bit(fetch_hit, 1'b1, "VADDR_B hits after its own fill (shared index-1 slot)");
        #0 check_word(fetch_ppn, 32'h0000_00BB, "VADDR_B PPN correct");
        fetch_vaddr = VADDR_A;
        #1 check_bit(fetch_hit, 1'b0, "VADDR_A now MISSES: index-1 slot's tag is VADDR_B's VPN, not VADDR_A's (tagged, not aliased)");

        // Overwrite: refilling VADDR_B again replaces its own entry cleanly.
        fill(VADDR_B, 32'h0000_00DD, 1'b1, 1'b1, 1'b1, 1'b1);
        fetch_vaddr = VADDR_B;
        #1 check_bit(fetch_hit, 1'b1, "VADDR_B still hits after a second fill (overwrite, not corruption)");
        #0 check_word(fetch_ppn, 32'h0000_00DD, "VADDR_B PPN reflects the newest fill");
        #0 check_bit(fetch_perm_r, 1'b1, "VADDR_B perm_r reflects the newest fill");

        // flush_all: an unconditional whole-TLB flush, sfence.vma's job (F5).
        @(posedge clk); flush_all <= 1;
        @(posedge clk); flush_all <= 0;
        fetch_vaddr = VADDR_B;
        #1 check_bit(fetch_hit, 1'b0, "VADDR_B misses after flush_all");
        ls_vaddr = VADDR_C;
        #0 check_bit(ls_hit, 1'b0, "VADDR_C (different index) also misses after flush_all");

        if (fails == 0)
            $display("PASS  tlb_unit (%0d checks)", checks);
        else
            $display("FAIL  tlb_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
