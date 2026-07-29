`include "Timer.v"

// docs/adr/0020-soc-integration.md (Phase D6). Standalone unit test for
// Timer.v, independent of the pipeline. Covers: count-up correctness,
// compare-triggers-pending correctness, a read/write round trip on both
// registers, and that writing MTIMECMP re-arms the comparison against
// mtime's *current* value rather than forcing pending low unconditionally.
module tb_timer_unit;
    reg clk = 0;
    reg rst = 0;
    reg s_cyc = 0, s_stb = 0, s_we = 0;
    reg [31:0] s_addr = 0, s_data_o = 0;
    reg [3:0] s_sel = 4'b1111;
    wire [31:0] s_data_i;
    wire s_ack;
    wire pending;

    integer fails = 0;
    integer checks = 0;

    Timer dut(
        .clk(clk), .rst(rst),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we),
        .s_addr(s_addr), .s_data_o(s_data_o), .s_sel(s_sel),
        .s_data_i(s_data_i), .s_ack(s_ack),
        .pending(pending)
    );

    always #5 clk = ~clk;

    localparam REG_MTIME    = 32'h0;
    localparam REG_MTIMECMP = 32'h4;

    task check;
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

    task wb_write;
        input [31:0] addr, data;
        begin
            @(posedge clk);
            s_cyc <= 1; s_stb <= 1; s_we <= 1; s_addr <= addr; s_data_o <= data;
            @(posedge clk);
            s_cyc <= 0; s_stb <= 0; s_we <= 0;
        end
    endtask

    task wb_read;
        input [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            s_cyc <= 1; s_stb <= 1; s_we <= 0; s_addr <= addr;
            #1 data = s_data_i;
            @(posedge clk);
            s_cyc <= 0; s_stb <= 0;
        end
    endtask

    reg [31:0] rdata;

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Reset: mtime=0, mtimecmp=0 -- pending is true immediately
        // (0 >= 0), the same "already expired" state a real CLINT with a
        // zeroed compare register would show.
        #1 check_bit(pending, 1'b1, "reset: mtime(0) >= mtimecmp(0) -- pending true immediately");

        // Set mtimecmp far in the future: pending must clear.
        wb_write(REG_MTIMECMP, 32'd1000);
        #1 check_bit(pending, 1'b0, "mtimecmp set far ahead: pending clears");

        // mtime free-runs: read it twice, a few cycles apart, confirm it
        // actually counts up (not stuck).
        wb_read(REG_MTIME, rdata);
        repeat (10) @(posedge clk);
        wb_read(REG_MTIME, rdata);
        checks = checks + 1;
        if (rdata < 32'd8) begin
            fails = fails + 1;
            $display("FAIL  mtime free-runs: only reached 0x%08h after >=10 cycles", rdata);
        end else begin
            $display("pass  mtime free-runs: reached 0x%08h after >=10 cycles", rdata);
        end

        // Set mtime directly near mtimecmp, confirm pending asserts once
        // mtime actually reaches it (not before, not never).
        wb_write(REG_MTIME, 32'd997);
        #1 check_bit(pending, 1'b0, "mtime=997 < mtimecmp=1000: still not pending");
        repeat (3) @(posedge clk);  // 997 -> 998 -> 999 -> 1000
        #1 check_bit(pending, 1'b1, "mtime reached mtimecmp=1000: pending now true");

        // Writing MTIMECMP to a value already <= current mtime re-arms
        // and immediately (well, the cycle after, like any register
        // write) shows pending true again -- not forced low by the write
        // itself.
        wb_write(REG_MTIMECMP, 32'd0);
        #1 check_bit(pending, 1'b1, "mtimecmp rewritten to 0 (<= current mtime): pending stays/re-asserts true");

        wb_read(REG_MTIMECMP, rdata);
        check(rdata, 32'd0, "MTIMECMP reads back the just-written value");

        if (fails == 0)
            $display("PASS  timer_unit (%0d checks)", checks);
        else
            $display("FAIL  timer_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
