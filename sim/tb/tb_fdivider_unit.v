`include "FDivider.v"

// Standalone unit test for FDivider.v, independent of the pipeline --
// mirrors tb_divider_unit.v's shape (drive busy/done directly with a task,
// docs/adr/0009's proven interlock signature) for docs/adr/0019-f-
// extension.md/Phase C4. Every expected value computed by an independent
// Python reference model (exact Fraction arithmetic, so any rounding mode
// can be checked precisely), same discipline as tb_falu_unit.v. A curated
// subset of a larger (~800-vector) randomized batch used during
// development but not committed, matching this project's convention of
// committing curated regression tests rather than bulk-generated ones.
//
// Two real bugs were found and fixed by this exact process, both in the
// iterative shift-subtract division, not in the special-case handling
// (which passed immediately):
// 1. The final iteration's packing step read the quotient/remainder shift
//    registers' *stale* (pre-this-cycle) values instead of the
//    just-computed ones -- nonblocking assignments don't land until the
//    next clock edge, one cycle too late for the very last iteration. This
//    silently used only N-1 of the N needed iterations, exactly halving
//    every result (e.g. 6.0/3.0 computed 1.0). Fixed by computing the new
//    quotient/remainder into blocking-assigned locals the same cycle's
//    packing step can read immediately.
// 2. The divide-by-zero flag was only ever driven high (in the
//    divide-by-zero special case) and never explicitly driven low again
//    when a *different*, later division entered the general iterative
//    path -- a stale DZ from an earlier divide-by-zero silently persisted
//    into an unrelated later result. Fixed by explicitly clearing all
//    flags when the general path is entered.
module tb_fdivider_unit;
    reg clk = 0;
    reg rst = 1;
    reg start = 0;
    reg [2:0] rm = 0;
    reg [31:0] a = 0, b = 0;
    wire busy, done;
    wire [31:0] result;
    wire [4:0] flags;

    integer total_checks = 0;
    integer total_fails = 0;

    FDivider dut(.clk(clk), .rst(rst), .start(start), .rm(rm), .a(a), .b(b),
                 .busy(busy), .done(done), .result(result), .flags(flags));

    always #5 clk = ~clk;

    task run_case;
        input [2:0] trm;
        input [31:0] ta, tb;
        input [31:0] texp_result;
        input [4:0] texp_flags;
        input [1023:0] label;
        integer cyc;
        begin
            @(posedge clk);
            rm <= trm; a <= ta; b <= tb; start <= 1;
            @(posedge clk);
            start <= 0;
            cyc = 0;
            while (!done && cyc < 80) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
            total_checks = total_checks + 1;
            if (!done) begin
                total_fails = total_fails + 1;
                $display("  FAIL  %0s: never completed", label);
            end else if (result !== texp_result || flags !== texp_flags) begin
                total_fails = total_fails + 1;
                $display("  FAIL  %0s: result=0x%08h flags=%05b, expected result=0x%08h flags=%05b (%0d cyc)",
                    label, result, flags, texp_result, texp_flags, cyc);
            end
            @(posedge clk);
        end
    endtask

    initial begin
        @(posedge clk); rst = 0;
        @(posedge clk); rst = 1;

        run_case(3'b000, 32'hF0B61F01, 32'h3900649A, 32'hF735904E, 5'b00001, "fdiv.s rand#0 rm=0");
        run_case(3'b010, 32'hBA003A7C, 32'h6F9C0266, 32'h89D269DF, 5'b00001, "fdiv.s rand#1 rm=2");
        run_case(3'b000, 32'hBF800000, 32'hFF800000, 32'h00000000, 5'b00000, "fdiv.s rand#2 rm=0");
        run_case(3'b011, 32'h004A8C62, 32'h44408300, 32'h00000000, 5'b00000, "fdiv.s rand#3 rm=3");
        run_case(3'b010, 32'hC44532D7, 32'h000AF05B, 32'hFF800000, 5'b01000, "fdiv.s rand#4 rm=2");
        run_case(3'b011, 32'hBF800000, 32'hBF800000, 32'h3F800000, 5'b00000, "fdiv.s rand#5 rm=3");
        run_case(3'b010, 32'hBF800000, 32'h00000000, 32'hFF800000, 5'b01000, "fdiv.s rand#6 rm=2");
        run_case(3'b100, 32'h3A1FC589, 32'h1F248AFE, 32'h5A7893A0, 5'b00001, "fdiv.s rand#7 rm=4");
        run_case(3'b001, 32'hFF07EE73, 32'h3F800000, 32'hFF07EE73, 5'b00000, "fdiv.s rand#8 rm=1");
        run_case(3'b010, 32'h00000000, 32'h00000000, 32'h7FC00000, 5'b10000, "fdiv.s rand#9 rm=2");
        run_case(3'b010, 32'h39EB4E59, 32'h3A193BAF, 32'h3F448ECE, 5'b00001, "fdiv.s rand#10 rm=2");
        run_case(3'b100, 32'h8008E278, 32'hF12B25CC, 32'h00000000, 5'b00000, "fdiv.s rand#11 rm=4");
        run_case(3'b010, 32'hF0A897B1, 32'hDE343E85, 32'h51EF7380, 5'b00001, "fdiv.s rand#12 rm=2");
        run_case(3'b001, 32'h00000000, 32'h7F800000, 32'h00000000, 5'b00000, "fdiv.s rand#13 rm=1");
        run_case(3'b100, 32'hBEE603C4, 32'hFF800000, 32'h00000000, 5'b00000, "fdiv.s rand#14 rm=4");
        run_case(3'b100, 32'hF0EA0096, 32'h52E9ADBC, 32'hDD802D62, 5'b00001, "fdiv.s rand#15 rm=4");
        run_case(3'b011, 32'h80FE8C26, 32'h00000000, 32'hFF800000, 5'b01000, "fdiv.s rand#16 rm=3");
        run_case(3'b011, 32'h7F800000, 32'h435480B6, 32'h7F800000, 5'b00000, "fdiv.s rand#17 rm=3");
        run_case(3'b100, 32'hFF3F9E29, 32'h438CFA88, 32'hFB2DFA2F, 5'b00001, "fdiv.s rand#18 rm=4");
        run_case(3'b010, 32'hBF800000, 32'hF0B28187, 32'h0E37916E, 5'b00001, "fdiv.s rand#19 rm=2");
        run_case(3'b011, 32'h0E7F20FB, 32'h7F800000, 32'h00000000, 5'b00000, "fdiv.s rand#20 rm=3");
        run_case(3'b010, 32'h005E0803, 32'h7F695F4A, 32'h00000000, 5'b00000, "fdiv.s rand#21 rm=2");
        run_case(3'b100, 32'hF11E91CA, 32'h7F800000, 32'h80000000, 5'b00000, "fdiv.s rand#22 rm=4");
        run_case(3'b100, 32'h711D335A, 32'h0048603C, 32'h7F800000, 5'b01000, "fdiv.s rand#23 rm=4");
        run_case(3'b001, 32'hFF800000, 32'hB9F9B6D6, 32'h7F800000, 5'b00000, "fdiv.s rand#24 rm=1");
        run_case(3'b000, 32'h40C00000, 32'h40400000, 32'h40000000, 5'b00000, "6/3=2 exact");
        run_case(3'b000, 32'h3F800000, 32'h40400000, 32'h3EAAAAAB, 5'b00001, "1/3 inexact");
        run_case(3'b000, 32'h3F800000, 32'h00000000, 32'h7F800000, 5'b01000, "1/0 -> +inf, DZ");
        run_case(3'b000, 32'hBF800000, 32'h00000000, 32'hFF800000, 5'b01000, "-1/0 -> -inf, DZ");
        run_case(3'b000, 32'h00000000, 32'h00000000, 32'h7FC00000, 5'b10000, "0/0 -> NaN, NV");
        run_case(3'b000, 32'h7F800000, 32'h7F800000, 32'h7FC00000, 5'b10000, "inf/inf -> NaN, NV");
        run_case(3'b000, 32'h7F800000, 32'h40000000, 32'h7F800000, 5'b00000, "inf/2 -> inf");
        run_case(3'b000, 32'h40000000, 32'h7F800000, 32'h00000000, 5'b00000, "2/inf -> 0");
        run_case(3'b000, 32'h3F800000, 32'h7FC00000, 32'h7FC00000, 5'b00000, "1/qNaN -> NaN, no NV");
        run_case(3'b000, 32'h3F800000, 32'h7F800001, 32'h7FC00000, 5'b10000, "1/sNaN -> NaN, NV");

        if (total_fails == 0)
            $display("PASS  fdivider_unit (%0d checks)", total_checks);
        else
            $display("FAIL  fdivider_unit (%0d/%0d checks failed)", total_fails, total_checks);
        $finish;
    end
endmodule
