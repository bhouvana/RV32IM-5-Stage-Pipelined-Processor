`include "Btb.v"

// docs/adr/0021-branch-prediction.md (Phase E3). Standalone unit test for
// Btb.v, independent of the pipeline. Covers: cold-miss reset state
// (`hit=0` for every entry before any training), a store/lookup/overwrite
// round trip, and index aliasing between two different PCs mapping to the
// same entry (confirming the second write simply overwrites the shared
// slot -- no crash, no corruption of an unrelated entry).
module tb_btb_unit;
    reg clk = 0;
    reg rst = 0;
    reg [31:0] query_pc = 0;
    wire hit;
    wire [31:0] target;
    reg update_valid = 0;
    reg [31:0] update_pc = 0;
    reg [31:0] update_target = 0;

    integer fails = 0;
    integer checks = 0;

    // Same NUM_ENTRIES=4 (index = pc[3:2]) convention as tb_bht_unit.v, for
    // the same reason: small enough to pick aliasing PCs by hand.
    Btb #(.XLEN(32), .NUM_ENTRIES(4)) dut(
        .clk(clk), .rst(rst),
        .query_pc(query_pc), .hit(hit), .target(target),
        .update_valid(update_valid), .update_pc(update_pc), .update_target(update_target)
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

    task train;
        input [31:0] pc;
        input [31:0] tgt;
        begin
            @(posedge clk);
            update_valid <= 1; update_pc <= pc; update_target <= tgt;
            @(posedge clk);
            update_valid <= 0;
        end
    endtask

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Cold reset: every entry misses.
        query_pc = 32'd0;
        #1 check_bit(hit, 1'b0, "reset: pc=0 cold-misses (no valid entry yet)");
        query_pc = 32'd4;
        #1 check_bit(hit, 1'b0, "reset: pc=4 (different index) also cold-misses");

        // Store/lookup round trip.
        train(32'd0, 32'h0000_0100);
        query_pc = 32'd0;
        #1 check_bit(hit, 1'b1, "pc=0 after training: now hits");
        #0 check_word(target, 32'h0000_0100, "pc=0 target reads back the trained value");

        // Overwrite: retraining the same PC with a new target replaces it,
        // not accumulates/corrupts it.
        train(32'd0, 32'h0000_0200);
        query_pc = 32'd0;
        #1 check_word(target, 32'h0000_0200, "pc=0 target after overwrite reflects the new value");

        // Independent entries: training pc=4 (index 1) must not disturb
        // pc=0 (index 0)'s own entry.
        train(32'd4, 32'h0000_0300);
        query_pc = 32'd4;
        #1 check_bit(hit, 1'b1, "pc=4 (index 1) after training: hits");
        #0 check_word(target, 32'h0000_0300, "pc=4 target reads back its own trained value");
        query_pc = 32'd0;
        #1 check_word(target, 32'h0000_0200, "pc=0 (index 0) unaffected by pc=4's training: still its own value");

        // Aliasing: pc=0 and pc=16 share index 0. Training pc=16 overwrites
        // the same shared entry pc=0 reads -- no crash, no corruption of
        // pc=4's independent (index 1) entry.
        train(32'd16, 32'h0000_0400);
        query_pc = 32'd0;
        #1 check_bit(hit, 1'b1, "pc=0 still hits after pc=16's training (shared entry, now overwritten)");
        #0 check_word(target, 32'h0000_0400, "pc=0 reads pc=16's target (shared index 0, untagged aliasing)");
        query_pc = 32'd16;
        #1 check_word(target, 32'h0000_0400, "pc=16 itself reads back its own just-trained value");
        query_pc = 32'd4;
        #1 check_word(target, 32'h0000_0300, "pc=4 (index 1) still unaffected by the index-0 aliasing above");

        if (fails == 0)
            $display("PASS  btb_unit (%0d checks)", checks);
        else
            $display("FAIL  btb_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
