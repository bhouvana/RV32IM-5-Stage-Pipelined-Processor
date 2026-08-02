`include "Ptw.v"

// docs/adr/00NN-mmu-sv32.md (Phase F4). Standalone unit test for Ptw.v,
// independent of the pipeline and of Tlb.v. Drives the walker directly
// (task-based, mirroring tb_divider_unit.v's own busy/done polling idiom)
// against a hand-built in-memory page-table fixture -- a plain array
// standing in for real memory, read through a minimal mock Wishbone slave
// that reproduces RamWishboneAdapter.v's own exact 1-cycle-registered-read
// timing (request this cycle, ack + data exactly one cycle later), since
// that's the timing contract Ptw.v's own header documents matching.
//
// Fixture layout (all addresses are byte addresses in the mock's small
// word-addressed array):
//   - Level-1 table at PPN=1 (byte base 0x1000), indexed by VPN1.
//   - VPN1=1's PDE is a non-leaf pointing at a level-0 table at PPN=2
//     (byte base 0x2000), which hosts every "goes to level 0" sub-case
//     below at a distinct VPN0 index within that one shared table.
//   - VPN1=2..5 each hold a distinct level-1-only fault/success case
//     (invalid PDE, a valid megapage, a misaligned megapage, a
//     permission-violating megapage) -- see the case list in the initial
//     block below for the full coverage this mirrors from the phase plan.
//
// PTEs are built with make_pte() from named fields rather than hand-
// computed hex literals -- far less error-prone than deriving bit-packed
// constants by hand, and it directly encodes the same Sv32 PTE layout
// riscv_defs.vh documents (PPN[31:10], 2 reserved bits, D/A/G/U/X/W/R/V),
// so a mismatch between this fixture and Ptw.v's own decoding would still
// be caught -- this function is common, spec-defined packing, not a
// duplicate of any decoding logic under test.
module tb_ptw_unit;
    reg clk = 0;
    reg rst = 0;

    reg         start = 0;
    reg  [31:0] vaddr = 0;
    reg  [21:0] satp_ppn = 0;
    reg         is_fetch = 0, is_store = 0, priv_is_u = 0;
    wire        busy, done, fault;
    wire [31:0] result_ppn;
    wire        result_perm_r, result_perm_w, result_perm_x, result_perm_u;

    wire        m_cyc, m_stb, m_we;
    wire [31:0] m_addr, m_data_o;
    wire [3:0]  m_sel;
    wire [31:0] m_data_i;
    reg         m_ack = 0;

    integer fails = 0;
    integer checks = 0;

    Ptw #(.XLEN(32)) dut(
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

    // Mock Wishbone slave: a flat 16KB word array (matches the phase plan's
    // own "MMU directed tests need a real MEM_SIZE_BYTES override, e.g.
    // 16KB" precedent -- realistic 4KB pages don't fit this project's tiny
    // default 128-byte memory), word-addressed, with the same registered-
    // one-cycle-later ack/data timing RamWishboneAdapter.v's own mem_read_r
    // uses -- the exact contract Ptw.v's header documents matching.
    reg [31:0] mem [0:4095];
    reg [31:0] addr_r;
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
    // Continuous assign, not always @(*) -- iverilog warns that a
    // combinational block reading a memory-array element is only
    // "sensitive to all words in the array" (a real simulator limitation,
    // not a correctness issue here since addr_r is the only true input),
    // and this project's bar is a genuinely zero-warning compile.
    assign m_data_i = mem[addr_r[13:2]];

    function [31:0] make_pte;
        input [21:0] ppn;
        input v, r, w, x, u, g, a, d;
        begin
            make_pte = {ppn, 2'b00, d, a, g, u, x, w, r, v};
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

    // Drives one walk to completion (bounded so a stuck walker fails loudly
    // instead of hanging the whole suite) and leaves done/fault/result_*
    // holding their pulsed values for the caller to check immediately after.
    task do_walk;
        input [31:0] vaddr_in;
        input [21:0] satp_ppn_in;
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

    // satp_ppn used throughout: PPN=1 -> level-1 table byte base 0x1000.
    localparam [21:0] SATP_PPN = 22'd1;

    initial begin
        // VPN1=1's PDE: non-leaf, points at the level-0 table (PPN=2).
        mem[(32'h1000 + 1*4) >> 2] = make_pte(22'd2, 1,0,0,0, 0,0,0,0);

        // Shared level-0 table (PPN=2, byte base 0x2000), one sub-case per VPN0:
        // VPN0=1: successful leaf -- kernel (U=0) RW data page, PPN=5.
        mem[(32'h2000 + 1*4) >> 2] = make_pte(22'd5, 1,1,1,0, 0,0,0,0);
        // VPN0=2: invalid PTE (V=0).
        mem[(32'h2000 + 2*4) >> 2] = make_pte(22'd9, 0,1,1,0, 0,0,0,0);
        // VPN0=3: non-leaf at level 0 (R=W=X=0 but V=1) -- malformed, Sv32 is only 2 levels.
        mem[(32'h2000 + 3*4) >> 2] = make_pte(22'd0, 1,0,0,0, 0,0,0,0);
        // VPN0=4: permission violation -- X-only page (R=0,W=0,X=1), a load will request R.
        mem[(32'h2000 + 4*4) >> 2] = make_pte(22'd6, 1,0,0,1, 0,0,0,0);
        // VPN0=5: U-bit mismatch -- a U=1 (user-only) page, requested from S-mode (priv_is_u=0).
        mem[(32'h2000 + 5*4) >> 2] = make_pte(22'd7, 1,1,1,0, 1,0,0,0);
        // VPN0=6: successful leaf for an instruction fetch -- X=1, U=0, PPN=8.
        mem[(32'h2000 + 6*4) >> 2] = make_pte(22'd8, 1,0,0,1, 0,0,0,0);
        // VPN0=7: successful leaf for a store -- W=1, U=0, PPN=10.
        mem[(32'h2000 + 7*4) >> 2] = make_pte(22'd10, 1,0,1,0, 0,0,0,0);

        // VPN1=2: invalid level-1 PDE (V=0) -- faults before ever reaching level 0.
        mem[(32'h1000 + 2*4) >> 2] = make_pte(22'd0, 0,0,0,0, 0,0,0,0);
        // VPN1=3: a valid, aligned megapage -- PPN=22'h001000 (low 10 bits clear), R=1,X=1,U=0.
        mem[(32'h1000 + 3*4) >> 2] = make_pte(22'h001000, 1,1,0,1, 0,0,0,0);
        // VPN1=4: a megapage with PPN[0] != 0 -- misaligned, must fault regardless of permissions.
        mem[(32'h1000 + 4*4) >> 2] = make_pte(22'h000401, 1,1,1,1, 0,0,0,0);
        // VPN1=5: a valid, aligned megapage but R=0/W=0 -- a store request must permission-fault.
        mem[(32'h1000 + 5*4) >> 2] = make_pte(22'h002000, 1,0,0,1, 0,0,0,0);

        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // -- Successful 2-level walk (load, S-mode, VPN1=1/VPN0=1) --
        do_walk({10'd1, 10'd1, 12'h345}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "2-level success: done pulses");
        check_bit(fault, 1'b0, "2-level success: no fault");
        check_word(result_ppn, 32'd5, "2-level success: result_ppn == leaf's own PPN");
        check_bit(result_perm_r, 1'b1, "2-level success: perm_r");
        check_bit(result_perm_w, 1'b1, "2-level success: perm_w");
        check_bit(result_perm_x, 1'b0, "2-level success: perm_x");

        // -- Invalid level-0 PTE (VPN1=1/VPN0=2) --
        do_walk({10'd1, 10'd2, 12'h000}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "invalid level-0 PTE: done pulses");
        check_bit(fault, 1'b1, "invalid level-0 PTE: faults");

        // -- Non-leaf at level 0, malformed (VPN1=1/VPN0=3) --
        do_walk({10'd1, 10'd3, 12'h000}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "non-leaf-at-level-0: done pulses");
        check_bit(fault, 1'b1, "non-leaf-at-level-0: faults (Sv32 has only 2 levels)");

        // -- Permission violation: load against an X-only page (VPN1=1/VPN0=4) --
        do_walk({10'd1, 10'd4, 12'h000}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "load-vs-X-only: done pulses");
        check_bit(fault, 1'b1, "load-vs-X-only: permission-faults (R not set)");

        // -- U-bit mismatch: S-mode request against a U=1 page (VPN1=1/VPN0=5) --
        do_walk({10'd1, 10'd5, 12'h000}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "S-mode-vs-U-page: done pulses");
        check_bit(fault, 1'b1, "S-mode-vs-U-page: faults (no SUM -- S can never match a U=1 page)");

        // -- Successful leaf, instruction fetch (VPN1=1/VPN0=6) --
        do_walk({10'd1, 10'd6, 12'h000}, SATP_PPN, 1'b1, 1'b0, 1'b0);
        check_bit(done, 1'b1, "fetch success: done pulses");
        check_bit(fault, 1'b0, "fetch success: no fault");
        check_word(result_ppn, 32'd8, "fetch success: result_ppn correct");
        check_bit(result_perm_x, 1'b1, "fetch success: perm_x");

        // -- Successful leaf, store (VPN1=1/VPN0=7) --
        do_walk({10'd1, 10'd7, 12'h000}, SATP_PPN, 1'b0, 1'b1, 1'b0);
        check_bit(done, 1'b1, "store success: done pulses");
        check_bit(fault, 1'b0, "store success: no fault");
        check_word(result_ppn, 32'd10, "store success: result_ppn correct");
        check_bit(result_perm_w, 1'b1, "store success: perm_w");

        // -- Invalid level-1 PDE (VPN1=2) -- faults without ever touching level 0 --
        do_walk({10'd2, 10'd0, 12'h000}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "invalid level-1 PDE: done pulses");
        check_bit(fault, 1'b1, "invalid level-1 PDE: faults");

        // -- Successful, aligned megapage (VPN1=3), fetch access --
        do_walk({10'd3, 10'd7, 12'h000}, SATP_PPN, 1'b1, 1'b0, 1'b0);
        check_bit(done, 1'b1, "megapage success: done pulses");
        check_bit(fault, 1'b0, "megapage success: no fault");
        // Spec formula: result PPN = {PDE's own PPN[19:10], VPN[0]} -- PPN=0x001000 -> PPN[19:10]=4, VPN0=7.
        check_word(result_ppn, {22'b0, 10'd4, 10'd7}, "megapage success: result_ppn == {PPN[19:10], vpn0}");

        // -- Misaligned megapage (VPN1=4) -- PPN[0] != 0, must fault regardless of permissions --
        do_walk({10'd4, 10'd0, 12'h000}, SATP_PPN, 1'b0, 1'b0, 1'b0);
        check_bit(done, 1'b1, "misaligned megapage: done pulses");
        check_bit(fault, 1'b1, "misaligned megapage: faults (PPN[0] != 0)");

        // -- Megapage permission violation (VPN1=5) -- a store against R=0/W=0 --
        do_walk({10'd5, 10'd0, 12'h000}, SATP_PPN, 1'b0, 1'b1, 1'b0);
        check_bit(done, 1'b1, "megapage permission violation: done pulses");
        check_bit(fault, 1'b1, "megapage permission violation: faults (W not set)");

        if (fails == 0)
            $display("PASS  ptw_unit (%0d checks)", checks);
        else
            $display("FAIL  ptw_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
