`include "Ptw39.v"

// docs/adr/00NN-sv39-mmu-phase-p.md (Phase P2). Standalone unit test for
// Ptw39.v, independent of the pipeline and of Tlb39.v -- mirrors
// tb_ptw_unit.v's structure exactly (task-based busy/done polling against
// a hand-built in-memory page-table fixture, read through a minimal mock
// Wishbone slave reproducing RamWishboneAdapter.v's real 1-cycle-
// registered-read timing) extended one level deeper for Sv39's real
// 3-level/8-byte-PTE walk.
//
// Fixture layout (byte addresses in the mock's own small array, PTEs are
// 8 bytes so each level's index stride is 8, not Sv32's 4):
//   - Level-2 table at PPN=1 (byte base 0x1000): VPN2=1 is the non-leaf
//     entry descending into the rest of this fixture; VPN2=2..5 each hold
//     their own distinct level-2-only fault/success case (invalid PDE,
//     a valid gigapage, a misaligned gigapage, a permission-violating
//     gigapage).
//   - Level-1 table at PPN=2 (byte base 0x2000), reachable only via
//     VPN2=1: VPN1=1 is the non-leaf entry descending to level 0;
//     VPN1=2..5 mirror the level-2 table's own fault/success shape one
//     level down (invalid PDE, valid megapage, misaligned megapage,
//     permission-violating megapage).
//   - Level-0 table at PPN=3 (byte base 0x3000), reachable only via
//     VPN2=1/VPN1=1: VPN0=1..7 mirror tb_ptw_unit.v's own level-0
//     sub-case set exactly (success/invalid/malformed-non-leaf/
//     permission-violation/U-mismatch/fetch-success/store-success).
//
// PTEs are built with make_pte39() from named fields (same reasoning as
// tb_ptw_unit.v's make_pte() -- common, spec-defined packing, not a
// duplicate of the decoding logic under test).
module tb_ptw39_unit;
    reg clk = 0;
    reg rst = 0;

    reg         start = 0;
    reg  [63:0] vaddr = 0;
    reg  [43:0] satp_ppn = 0;
    reg         is_fetch = 0, is_store = 0, priv_is_u = 0;
    wire        busy, done, fault;
    wire [63:0] result_ppn;
    wire        result_perm_r, result_perm_w, result_perm_x, result_perm_u;

    wire        m_cyc, m_stb, m_we;
    wire [63:0] m_addr, m_data_o;
    wire [3:0]  m_sel;
    wire [63:0] m_data_i;
    reg         m_ack = 0;

    integer fails = 0;
    integer checks = 0;

    Ptw39 #(.XLEN(64)) dut(
        .clk(clk), .rst(rst),
        .start(start), .vaddr(vaddr), .satp_ppn(satp_ppn),
        .is_fetch(is_fetch), .is_store(is_store), .priv_is_u(priv_is_u),
        .busy(busy), .done(done), .fault(fault), .result_ppn(result_ppn),
        .result_perm_r(result_perm_r), .result_perm_w(result_perm_w),
        .result_perm_x(result_perm_x), .result_perm_u(result_perm_u),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_we(m_we), .m_addr(m_addr),
        .m_data_o(m_data_o), .m_sel(m_sel), .m_data_i(m_data_i), .m_ack(m_ack)
    );

    always #5 clk = ~clk;

    // Mock Wishbone slave: a flat 16KB array of 8-byte words (this
    // fixture's own tables all fit within 0x0000-0x3FFF), same
    // registered-one-cycle-later ack/data timing RamWishboneAdapter.v's
    // own mem_read_r uses -- the exact contract Ptw39.v's header documents
    // matching.
    reg [63:0] mem [0:2047];
    reg [63:0] addr_r;
    always @(posedge clk) begin
        if (~rst) begin
            m_ack <= 1'b0;
        end
        else begin
            m_ack <= m_cyc && m_stb;
            if (m_cyc && m_stb)
                addr_r <= m_addr;
        end
    end
    assign m_data_i = mem[addr_r[13:3]];

    function [63:0] make_pte39;
        input [43:0] ppn;
        input v, r, w, x, u, g, a, d;
        begin
            make_pte39 = {10'b0, ppn, 2'b00, d, a, g, u, x, w, r, v};
        end
    endfunction

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
        input [63:0] actual, expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: 0x%016h, expected 0x%016h", label, actual, expected);
            end else begin
                $display("pass  %0s: 0x%016h", label, actual);
            end
        end
    endtask

    // Drives one walk to completion (bounded so a stuck walker fails loudly
    // instead of hanging the whole suite).
    task do_walk;
        input [63:0] vaddr_in;
        input [43:0] satp_ppn_in;
        input        is_fetch_in, is_store_in, priv_is_u_in;
        integer cyc;
        begin
            @(posedge clk);
            vaddr <= vaddr_in; satp_ppn <= satp_ppn_in;
            is_fetch <= is_fetch_in; is_store <= is_store_in; priv_is_u <= priv_is_u_in;
            start <= 1;
            @(posedge clk);
            cyc = 0;
            while (!done && cyc < 40) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
            start <= 0;
        end
    endtask

    // satp_ppn used throughout: PPN=1 -> level-2 table byte base 0x1000.
    localparam [43:0] SATP_PPN = 44'd1;

    initial begin
        // VPN2=1's PDE: non-leaf, points at the level-1 table (PPN=2).
        mem[(32'h1000 + 1*8) >> 3] = make_pte39(44'd2, 1,0,0,0, 0,0,0,0);
        // VPN2=2: invalid level-2 PDE (V=0) -- faults before touching level 1.
        mem[(32'h1000 + 2*8) >> 3] = make_pte39(44'd0, 0,0,0,0, 0,0,0,0);
        // VPN2=3: a valid, aligned gigapage -- PPN low-20 bits = 0x40000 (bit18 set, PPN[1:0]=0), X=1 (fetch).
        mem[(32'h1000 + 3*8) >> 3] = make_pte39(44'h40000, 1,0,0,1, 0,0,0,0);
        // VPN2=4: a gigapage with PPN[1:0] != 0 -- misaligned, must fault regardless of permissions.
        mem[(32'h1000 + 4*8) >> 3] = make_pte39(44'h1, 1,1,1,1, 0,0,0,0);
        // VPN2=5: a valid, aligned gigapage but W=0 -- a store request must permission-fault.
        mem[(32'h1000 + 5*8) >> 3] = make_pte39(44'h80000, 1,1,0,0, 0,0,0,0);

        // VPN1=1's PDE (level-1 table, PPN=2): non-leaf, points at level-0 (PPN=3).
        mem[(32'h2000 + 1*8) >> 3] = make_pte39(44'd3, 1,0,0,0, 0,0,0,0);
        // VPN1=2: invalid level-1 PDE (V=0) -- faults before touching level 0.
        mem[(32'h2000 + 2*8) >> 3] = make_pte39(44'd0, 0,0,0,0, 0,0,0,0);
        // VPN1=3: a valid, aligned megapage -- PPN low bits = 0x200 (bit9 set, PPN[0]=0), X=1 (fetch).
        mem[(32'h2000 + 3*8) >> 3] = make_pte39(44'h200, 1,0,0,1, 0,0,0,0);
        // VPN1=4: a megapage with PPN[0] != 0 -- misaligned, must fault regardless of permissions.
        mem[(32'h2000 + 4*8) >> 3] = make_pte39(44'h1, 1,1,1,1, 0,0,0,0);
        // VPN1=5: a valid, aligned megapage but W=0 -- a store request must permission-fault.
        mem[(32'h2000 + 5*8) >> 3] = make_pte39(44'h400, 1,1,0,0, 0,0,0,0);

        // Level-0 table (PPN=3, byte base 0x3000), one sub-case per VPN0
        // (same set tb_ptw_unit.v's own level-0 table uses):
        // VPN0=1: successful leaf -- kernel (U=0) RW data page, PPN=5.
        mem[(32'h3000 + 1*8) >> 3] = make_pte39(44'd5, 1,1,1,0, 0,0,0,0);
        // VPN0=2: invalid PTE (V=0).
        mem[(32'h3000 + 2*8) >> 3] = make_pte39(44'd9, 0,1,1,0, 0,0,0,0);
        // VPN0=3: non-leaf at level 0 (R=W=X=0 but V=1) -- malformed, Sv39 is only 3 levels.
        mem[(32'h3000 + 3*8) >> 3] = make_pte39(44'd0, 1,0,0,0, 0,0,0,0);
        // VPN0=4: permission violation -- X-only page (R=0,W=0,X=1), a load will request R.
        mem[(32'h3000 + 4*8) >> 3] = make_pte39(44'd6, 1,0,0,1, 0,0,0,0);
        // VPN0=5: U-bit mismatch -- a U=1 (user-only) page, requested from S-mode (priv_is_u=0).
        mem[(32'h3000 + 5*8) >> 3] = make_pte39(44'd7, 1,1,1,0, 1,0,0,0);
        // VPN0=6: successful leaf for an instruction fetch -- X=1, U=0, PPN=8.
        mem[(32'h3000 + 6*8) >> 3] = make_pte39(44'd8, 1,0,0,1, 0,0,0,0);
        // VPN0=7: successful leaf for a store -- W=1, U=0, PPN=10.
        mem[(32'h3000 + 7*8) >> 3] = make_pte39(44'd10, 1,0,1,0, 0,0,0,0);

        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // -- Successful 3-level walk (load, S-mode, VPN2=1/VPN1=1/VPN0=1) --
        do_walk({25'b0, 9'd1, 9'd1, 9'd1, 12'h345}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "3-level success: done pulses");
        check_bit(fault, 1'b0, "3-level success: no fault");
        check_word(result_ppn, 64'd5, "3-level success: result_ppn == leaf's own PPN");
        check_bit(result_perm_r, 1'b1, "3-level success: perm_r");
        check_bit(result_perm_w, 1'b1, "3-level success: perm_w");
        check_bit(result_perm_x, 1'b0, "3-level success: perm_x");

        // -- Invalid level-0 PTE (VPN2=1/VPN1=1/VPN0=2) --
        do_walk({25'b0, 9'd1, 9'd1, 9'd2, 12'h000}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "invalid level-0 PTE: done pulses");
        check_bit(fault, 1'b1, "invalid level-0 PTE: faults");

        // -- Non-leaf at level 0, malformed (VPN2=1/VPN1=1/VPN0=3) --
        do_walk({25'b0, 9'd1, 9'd1, 9'd3, 12'h000}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "non-leaf-at-level-0: done pulses");
        check_bit(fault, 1'b1, "non-leaf-at-level-0: faults (Sv39 has only 3 levels)");

        // -- Permission violation: load against an X-only page (VPN2=1/VPN1=1/VPN0=4) --
        do_walk({25'b0, 9'd1, 9'd1, 9'd4, 12'h000}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "load-vs-X-only: done pulses");
        check_bit(fault, 1'b1, "load-vs-X-only: permission-faults (R not set)");

        // -- U-bit mismatch: S-mode request against a U=1 page (VPN2=1/VPN1=1/VPN0=5) --
        do_walk({25'b0, 9'd1, 9'd1, 9'd5, 12'h000}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "S-mode-vs-U-page: done pulses");
        check_bit(fault, 1'b1, "S-mode-vs-U-page: faults (no SUM -- S can never match a U=1 page)");

        // -- Successful leaf, instruction fetch (VPN2=1/VPN1=1/VPN0=6) --
        do_walk({25'b0, 9'd1, 9'd1, 9'd6, 12'h000}, SATP_PPN, 1'b1, 1'b0, 1'b0);
        check_bit(done, 1'b1, "fetch success: done pulses");
        check_bit(fault, 1'b0, "fetch success: no fault");
        check_word(result_ppn, 64'd8, "fetch success: result_ppn correct");
        check_bit(result_perm_x, 1'b1, "fetch success: perm_x");

        // -- Successful leaf, store (VPN2=1/VPN1=1/VPN0=7) --
        do_walk({25'b0, 9'd1, 9'd1, 9'd7, 12'h000}, SATP_PPN, 1'b0, 1'b1, 1'b0);
        check_bit(done, 1'b1, "store success: done pulses");
        check_bit(fault, 1'b0, "store success: no fault");
        check_word(result_ppn, 64'd10, "store success: result_ppn correct");
        check_bit(result_perm_w, 1'b1, "store success: perm_w");

        // -- Invalid level-1 PDE (VPN2=1/VPN1=2) -- faults without ever touching level 0 --
        do_walk({25'b0, 9'd1, 9'd2, 9'd0, 12'h000}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "invalid level-1 PDE: done pulses");
        check_bit(fault, 1'b1, "invalid level-1 PDE: faults");

        // -- Invalid level-2 PDE (VPN2=2) -- faults without ever touching level 1 --
        do_walk({25'b0, 9'd2, 9'd0, 9'd0, 12'h000}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "invalid level-2 PDE: done pulses");
        check_bit(fault, 1'b1, "invalid level-2 PDE: faults");

        // -- Successful, aligned gigapage (VPN2=3/VPN1=7/VPN0=9), fetch access --
        do_walk({25'b0, 9'd3, 9'd7, 9'd9, 12'h000}, SATP_PPN, 1'b1, 1'b0, 1'b0);
        check_bit(done, 1'b1, "gigapage success: done pulses");
        check_bit(fault, 1'b0, "gigapage success: no fault");
        // pte_ppn20 = 0x40000 -> pte_ppn20[19:18] = 2'b01; result = {2'b01, vpn1=7, vpn0=9}.
        check_word(result_ppn, {45'b0, 2'b01, 9'd7, 9'd9}, "gigapage success: result_ppn == {PPN[2] low bits, vpn1, vpn0}");
        check_bit(result_perm_x, 1'b1, "gigapage success: perm_x");

        // -- Misaligned gigapage (VPN2=4) -- PPN[1:0] != 0, must fault regardless of permissions --
        do_walk({25'b0, 9'd4, 9'd0, 9'd0, 12'h000}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "misaligned gigapage: done pulses");
        check_bit(fault, 1'b1, "misaligned gigapage: faults (PPN[1:0] != 0)");

        // -- Gigapage permission violation (VPN2=5) -- a store against W=0 --
        do_walk({25'b0, 9'd5, 9'd0, 9'd0, 12'h000}, SATP_PPN, 1'b0, 1'b1, 1'b0);
        check_bit(done, 1'b1, "gigapage permission violation: done pulses");
        check_bit(fault, 1'b1, "gigapage permission violation: faults (W not set)");

        // -- Successful, aligned megapage (VPN2=1/VPN1=3/VPN0=9), fetch access --
        do_walk({25'b0, 9'd1, 9'd3, 9'd9, 12'h000}, SATP_PPN, 1'b1, 1'b0, 1'b0);
        check_bit(done, 1'b1, "megapage success: done pulses");
        check_bit(fault, 1'b0, "megapage success: no fault");
        // pte_ppn20 = 0x200 -> pte_ppn20[19:9] = 11'd1; result = {11'd1, vpn0=9}.
        check_word(result_ppn, {44'b0, 11'd1, 9'd9}, "megapage success: result_ppn == {PPN[2:1] low bits, vpn0}");
        check_bit(result_perm_x, 1'b1, "megapage success: perm_x");

        // -- Misaligned megapage (VPN2=1/VPN1=4) -- PPN[0] != 0, must fault regardless of permissions --
        do_walk({25'b0, 9'd1, 9'd4, 9'd0, 12'h000}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "misaligned megapage: done pulses");
        check_bit(fault, 1'b1, "misaligned megapage: faults (PPN[0] != 0)");

        // -- Megapage permission violation (VPN2=1/VPN1=5) -- a store against W=0 --
        do_walk({25'b0, 9'd1, 9'd5, 9'd0, 12'h000}, SATP_PPN, 1'b0, 1'b1, 1'b0);
        check_bit(done, 1'b1, "megapage permission violation: done pulses");
        check_bit(fault, 1'b1, "megapage permission violation: faults (W not set)");

        if (fails == 0)
            $display("PASS  ptw39_unit (%0d checks)", checks);
        else
            $display("FAIL  ptw39_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
