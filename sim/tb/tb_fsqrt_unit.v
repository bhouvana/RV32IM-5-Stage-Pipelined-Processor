`include "FSqrt.v"

// Standalone unit test for FSqrt.v, independent of the pipeline -- mirrors
// tb_divider_unit.v/tb_fdivider_unit.v's shape (docs/adr/0009's proven
// busy/done interlock) for docs/adr/0019-f-extension.md/Phase C4. Every
// expected value computed by an independent Python reference model (exact
// Fraction arithmetic via a scaled math.isqrt, so any rounding mode can be
// checked precisely). A curated subset of a larger (~800-vector)
// randomized batch used during development but not committed, matching
// this project's convention of committing curated regression tests rather
// than bulk-generated ones.
//
// FSqrt.v has no existing precedent in this codebase (unlike FDivider.v,
// which adapts Divider.v's algorithm) -- verified from scratch in Python
// before any Verilog was written, and even so, two real bugs surfaced only
// once actually run against these vectors:
// 1. The same off-by-one FDivider.v's own development found (the final
//    iteration's packing step reading the stale, pre-this-cycle root/
//    remainder instead of this cycle's just-computed values) -- avoided
//    here from the start by applying that lesson up front, not
//    rediscovered.
// 2. A genuinely new class of bug, specific to square root: a float's
//    significand carries an implicit *odd* power-of-two scale (2^23, from
//    23 fraction bits), so computing sqrt(mantissa) directly picks up a
//    spurious factor of sqrt(2) unless the exponent's parity is folded
//    into the *radicand* itself first (see FSqrt.v's header comment for
//    the verified-correct even/odd radicand construction). Two different
//    closed-form derivations of this step were tried and found wrong (by a
//    factor of 2, then by sqrt(2)) before empirically testing against
//    known perfect squares (4.0, 16.0, ...) pinned down the correct one --
//    not found by re-reading the RTL, found by computing wrong answers for
//    specific inputs and tracing why.
module tb_fsqrt_unit;
    reg clk = 0;
    reg rst = 1;
    reg start = 0;
    reg [2:0] rm = 0;
    reg [31:0] a = 0;
    wire busy, done;
    wire [31:0] result;
    wire [4:0] flags;

    integer total_checks = 0;
    integer total_fails = 0;

    FSqrt dut(.clk(clk), .rst(rst), .start(start), .rm(rm), .a(a),
              .busy(busy), .done(done), .result(result), .flags(flags));

    always #5 clk = ~clk;

    task run_case;
        input [2:0] trm;
        input [31:0] ta;
        input [31:0] texp_result;
        input [4:0] texp_flags;
        input [1023:0] label;
        integer cyc;
        begin
            @(posedge clk);
            rm <= trm; a <= ta; start <= 1;
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

        run_case(3'b010, 32'h00000000, 32'h00000000, 5'b00000, "fsqrt.s rand#0 rm=2");
        run_case(3'b010, 32'h439A915C, 32'h418CA874, 5'b00001, "fsqrt.s rand#1 rm=2");
        run_case(3'b100, 32'h0026A26F, 32'h0026A26F, 5'b00000, "fsqrt.s rand#2 rm=4");
        run_case(3'b011, 32'hE6BE81F2, 32'h7FC00000, 5'b10000, "fsqrt.s rand#3 rm=3");
        run_case(3'b010, 32'h3F800000, 32'h3F800000, 5'b00000, "fsqrt.s rand#4 rm=2");
        run_case(3'b000, 32'hFF800000, 32'h7FC00000, 5'b10000, "fsqrt.s rand#5 rm=0");
        run_case(3'b100, 32'h7F800000, 32'h7F800000, 5'b00000, "fsqrt.s rand#6 rm=4");
        run_case(3'b000, 32'h70FC675B, 32'h5833BE4D, 5'b00001, "fsqrt.s rand#7 rm=0");
        run_case(3'b100, 32'h3CE95BB0, 32'h3E2CD436, 5'b00001, "fsqrt.s rand#8 rm=4");
        run_case(3'b010, 32'h43B94C73, 32'h419A01D9, 5'b00001, "fsqrt.s rand#9 rm=2");
        run_case(3'b001, 32'h3F800000, 32'h3F800000, 5'b00000, "fsqrt.s rand#10 rm=1");
        run_case(3'b010, 32'h80000000, 32'h80000000, 5'b00000, "fsqrt.s rand#11 rm=2");
        run_case(3'b001, 32'h3F07506C, 32'h3F3A1E8F, 5'b00001, "fsqrt.s rand#12 rm=1");
        run_case(3'b010, 32'h008A30EE, 32'h2004FF7C, 5'b00001, "fsqrt.s rand#13 rm=2");
        run_case(3'b010, 32'h7F800000, 32'h7F800000, 5'b00000, "fsqrt.s rand#14 rm=2");
        run_case(3'b010, 32'h7F800000, 32'h7F800000, 5'b00000, "fsqrt.s rand#15 rm=2");
        run_case(3'b011, 32'h8A751531, 32'h7FC00000, 5'b10000, "fsqrt.s rand#16 rm=3");
        run_case(3'b100, 32'h7F800000, 32'h7F800000, 5'b00000, "fsqrt.s rand#17 rm=4");
        run_case(3'b001, 32'h70A3E558, 32'h5810D714, 5'b00001, "fsqrt.s rand#18 rm=1");
        run_case(3'b011, 32'h3F1528B9, 32'h3F4368BC, 5'b00001, "fsqrt.s rand#19 rm=3");
        run_case(3'b000, 32'h40800000, 32'h40000000, 5'b00000, "sqrt(4.0)=2.0 exact");
        run_case(3'b000, 32'h41100000, 32'h40400000, 5'b00000, "sqrt(9.0)=3.0 exact");
        run_case(3'b000, 32'h40000000, 32'h3FB504F3, 5'b00001, "sqrt(2.0) inexact");
        run_case(3'b000, 32'h3F800000, 32'h3F800000, 5'b00000, "sqrt(1.0)=1.0 exact");
        run_case(3'b000, 32'h00000000, 32'h00000000, 5'b00000, "sqrt(+0)=+0");
        run_case(3'b000, 32'h80000000, 32'h80000000, 5'b00000, "sqrt(-0)=-0");
        run_case(3'b000, 32'hC0800000, 32'h7FC00000, 5'b10000, "sqrt(-4.0) -> NaN, NV");
        run_case(3'b000, 32'h7F800000, 32'h7F800000, 5'b00000, "sqrt(+inf)=+inf");
        run_case(3'b000, 32'hFF800000, 32'h7FC00000, 5'b10000, "sqrt(-inf) -> NaN, NV");
        run_case(3'b000, 32'h7FC00000, 32'h7FC00000, 5'b00000, "sqrt(qNaN) -> NaN, no NV");
        run_case(3'b000, 32'h7F800001, 32'h7FC00000, 5'b10000, "sqrt(sNaN) -> NaN, NV");
        run_case(3'b000, 32'h3E800000, 32'h3F000000, 5'b00000, "sqrt(0.25)=0.5 exact");
        run_case(3'b000, 32'h47800000, 32'h43800000, 5'b00000, "sqrt(65536.0)=256.0 exact");

        if (total_fails == 0)
            $display("PASS  fsqrt_unit (%0d checks)", total_checks);
        else
            $display("FAIL  fsqrt_unit (%0d/%0d checks failed)", total_fails, total_checks);
        $finish;
    end
endmodule
