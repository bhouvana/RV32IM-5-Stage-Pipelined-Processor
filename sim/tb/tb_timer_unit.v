`include "Timer.v"

// docs/adr/0020-soc-integration.md (Phase D6) / docs/adr/0034-uart-clint-
// register-compat-phase-r.md (Phase R). Standalone unit test for Timer.v,
// independent of the pipeline. Two DUT instances -- XLEN=32 (split 32-bit-
// half register access, matching this project's own default) and XLEN=64
// (single 64-bit register access) -- so both of Phase R's write-width paths
// are independently exercised, mirroring tb_alu_wordop_unit.v's own
// side-by-side multi-parameter structure. Covers: count-up correctness,
// compare-triggers-pending correctness, read/write round trips on every
// register (including the new msip), that writing MTIMECMP re-arms the
// comparison against mtime's *current* value rather than forcing pending
// low unconditionally, and the real CLINT byte offsets themselves.
module tb_timer_unit;
    reg clk = 0;
    reg rst = 0;

    integer fails = 0;
    integer checks = 0;

    // Phase R: real CLINT byte offsets (design/riscv_defs.vh).
    localparam REG_MSIP        = 32'h0000;
    localparam REG_MTIMECMP    = 32'h4000;
    localparam REG_MTIMECMPH   = 32'h4004;
    localparam REG_MTIME       = 32'hBFF8;
    localparam REG_MTIMEH      = 32'hBFFC;

    always #5 clk = ~clk;

    task check32;
        input [31:0] actual, expected;
        input [511:0] label;
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

    task check_bit;
        input actual, expected;
        input [511:0] label;
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

    // ==========================================================================
    // XLEN=32 instance: split 32-bit-half access to the 64-bit mtime/mtimecmp.
    // ==========================================================================
    reg s32_cyc = 0, s32_stb = 0, s32_we = 0;
    reg [31:0] s32_addr = 0, s32_data_o = 0;
    reg [3:0] s32_sel = 4'b1111;
    wire [31:0] s32_data_i;
    wire s32_ack;
    wire pending32, msip_pending32;

    Timer #(.XLEN(32)) dut32(
        .clk(clk), .rst(rst),
        .s_cyc(s32_cyc), .s_stb(s32_stb), .s_we(s32_we),
        .s_addr(s32_addr), .s_data_o(s32_data_o), .s_sel(s32_sel),
        .s_data_i(s32_data_i), .s_ack(s32_ack),
        .pending(pending32), .msip_pending(msip_pending32)
    );

    task wb32_write;
        input [31:0] addr, data;
        begin
            @(posedge clk);
            s32_cyc <= 1; s32_stb <= 1; s32_we <= 1; s32_addr <= addr; s32_data_o <= data;
            @(posedge clk);
            s32_cyc <= 0; s32_stb <= 0; s32_we <= 0;
        end
    endtask

    task wb32_read;
        input [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            s32_cyc <= 1; s32_stb <= 1; s32_we <= 0; s32_addr <= addr;
            #1 data = s32_data_i;
            @(posedge clk);
            s32_cyc <= 0; s32_stb <= 0;
        end
    endtask

    // ==========================================================================
    // XLEN=64 instance: single 64-bit access to the same registers.
    // ==========================================================================
    reg s64_cyc = 0, s64_stb = 0, s64_we = 0;
    reg [63:0] s64_addr = 0, s64_data_o = 0;
    reg [3:0] s64_sel = 4'b1111;
    wire [63:0] s64_data_i;
    wire s64_ack;
    wire pending64, msip_pending64;

    Timer #(.XLEN(64)) dut64(
        .clk(clk), .rst(rst),
        .s_cyc(s64_cyc), .s_stb(s64_stb), .s_we(s64_we),
        .s_addr(s64_addr), .s_data_o(s64_data_o), .s_sel(s64_sel),
        .s_data_i(s64_data_i), .s_ack(s64_ack),
        .pending(pending64), .msip_pending(msip_pending64)
    );

    task wb64_write;
        input [63:0] addr, data;
        begin
            @(posedge clk);
            s64_cyc <= 1; s64_stb <= 1; s64_we <= 1; s64_addr <= addr; s64_data_o <= data;
            @(posedge clk);
            s64_cyc <= 0; s64_stb <= 0; s64_we <= 0;
        end
    endtask

    task wb64_read;
        input [63:0] addr;
        output [63:0] data;
        begin
            @(posedge clk);
            s64_cyc <= 1; s64_stb <= 1; s64_we <= 0; s64_addr <= addr;
            #1 data = s64_data_i;
            @(posedge clk);
            s64_cyc <= 0; s64_stb <= 0;
        end
    endtask

    reg [31:0] rdata32;
    reg [63:0] rdata64;

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // ---- XLEN=32 half: reset, far-ahead mtimecmp, free-run, reach,
        // rewrite-re-arms, msip -- mirrors the original single-DUT test. ----
        #1 check_bit(pending32, 1'b1, "XLEN=32 reset: mtime(0) >= mtimecmp(0) -- pending true immediately");

        wb32_write(REG_MTIMECMP, 32'd1000);
        #1 check_bit(pending32, 1'b0, "XLEN=32: mtimecmp set far ahead (low half): pending clears");
        wb32_read(REG_MTIMECMPH, rdata32);
        check32(rdata32, 32'd0, "XLEN=32: mtimecmp high half still 0 (never written)");

        wb32_read(REG_MTIME, rdata32);
        repeat (10) @(posedge clk);
        wb32_read(REG_MTIME, rdata32);
        checks = checks + 1;
        if (rdata32 < 32'd8) begin
            fails = fails + 1;
            $display("FAIL  XLEN=32 mtime free-runs: only reached 0x%08h after >=10 cycles", rdata32);
        end else begin
            $display("pass  XLEN=32 mtime free-runs: reached 0x%08h after >=10 cycles", rdata32);
        end

        wb32_write(REG_MTIME, 32'd997);
        #1 check_bit(pending32, 1'b0, "XLEN=32: mtime=997 < mtimecmp=1000: still not pending");
        repeat (3) @(posedge clk);  // 997 -> 998 -> 999 -> 1000
        #1 check_bit(pending32, 1'b1, "XLEN=32: mtime reached mtimecmp=1000: pending now true");

        wb32_write(REG_MTIMECMP, 32'd0);
        #1 check_bit(pending32, 1'b1, "XLEN=32: mtimecmp rewritten to 0 (<= current mtime): pending re-asserts true");
        wb32_read(REG_MTIMECMP, rdata32);
        check32(rdata32, 32'd0, "XLEN=32: MTIMECMP low half reads back the just-written value");

        // High half of a 64-bit compare: mtimecmp = {1, 0} (0x1_00000000)
        // must not be reachable by mtime's low 32 bits alone.
        wb32_write(REG_MTIMECMPH, 32'd1);
        #1 check_bit(pending32, 1'b0, "XLEN=32: mtimecmp high half set to 1 (huge): pending clears again");

        // msip: plain 32-bit R/W, bit0 -> msip_pending.
        check_bit(msip_pending32, 1'b0, "XLEN=32: msip_pending is 0 before any write");
        wb32_write(REG_MSIP, 32'd1);
        #1 check_bit(msip_pending32, 1'b1, "XLEN=32: msip_pending set once msip bit0 written");
        wb32_read(REG_MSIP, rdata32);
        check32(rdata32, 32'd1, "XLEN=32: MSIP reads back the just-written value");
        wb32_write(REG_MSIP, 32'd0);
        #1 check_bit(msip_pending32, 1'b0, "XLEN=32: msip_pending clears once msip cleared");

        // ---- XLEN=64 half: single 64-bit writes cover the whole register. ----
        #1 check_bit(pending64, 1'b1, "XLEN=64 reset: mtime(0) >= mtimecmp(0) -- pending true immediately");

        wb64_write(REG_MTIMECMP, 64'd5000);
        #1 check_bit(pending64, 1'b0, "XLEN=64: single 64-bit mtimecmp write (far ahead): pending clears");
        wb64_read(REG_MTIMECMP, rdata64);
        check32(rdata64[31:0], 32'd5000, "XLEN=64: MTIMECMP reads back the just-written 64-bit value (low 32)");

        wb64_read(REG_MTIME, rdata64);
        repeat (10) @(posedge clk);
        wb64_read(REG_MTIME, rdata64);
        checks = checks + 1;
        if (rdata64 < 64'd8) begin
            fails = fails + 1;
            $display("FAIL  XLEN=64 mtime free-runs: only reached 0x%016h after >=10 cycles", rdata64);
        end else begin
            $display("pass  XLEN=64 mtime free-runs: reached 0x%016h after >=10 cycles", rdata64);
        end

        wb64_write(REG_MTIME, 64'd4997);
        #1 check_bit(pending64, 1'b0, "XLEN=64: mtime=4997 < mtimecmp=5000: still not pending");
        repeat (3) @(posedge clk);
        #1 check_bit(pending64, 1'b1, "XLEN=64: mtime reached mtimecmp=5000: pending now true");

        // msip at XLEN=64 -- still a plain 32-bit-meaningful access.
        check_bit(msip_pending64, 1'b0, "XLEN=64: msip_pending is 0 before any write");
        wb64_write(REG_MSIP, 64'd1);
        #1 check_bit(msip_pending64, 1'b1, "XLEN=64: msip_pending set once msip bit0 written");

        if (fails == 0)
            $display("PASS  timer_unit (%0d checks)", checks);
        else
            $display("FAIL  timer_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
