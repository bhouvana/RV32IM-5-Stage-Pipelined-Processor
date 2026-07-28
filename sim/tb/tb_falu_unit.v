`include "FALU.v"

// Standalone unit test for FALU.v, independent of the pipeline -- mirrors
// tb_divider_unit.v/tb_reg1a_unit.v's shape (verify a new numerically
// nontrivial unit before wiring it into the live pipeline, docs/adr/0018's
// staging convention, continued here for docs/adr/0019-f-extension.md/
// Phase C). Picked up by sim/run_tests.sh's plain `tb_*.v` glob like every
// other standalone unit test.
//
// Every expected result/flags value below was computed by an independent
// Python reference model (exact rational (Fraction) arithmetic, so any
// rounding mode can be checked precisely, not just round-to-nearest -- the
// same "don't hand-compute expected values" discipline docs/adr/0006 used
// for RV32M), explicitly modeling FALU.v's own documented deviations
// (flush-to-zero subnormals, no NaN-boxing) rather than strict IEEE 754.
// This is a curated, representative subset (~230 checks spanning every op,
// all 5 rounding modes, and the edge cases that actually found real bugs
// during development -- see docs/adr/0019) of a much larger (~4700-vector)
// randomized batch used during development but not committed, matching
// this project's convention of committing directed/curated regression
// tests rather than bulk generated ones.
//
// Three real bugs were found and fixed by this exact process before any of
// this passed: (1) FMUL double-counted its own carry-out exponent
// adjustment (once explicitly, once again via round_and_pack's carry
// handling) -- a systematic 2x-too-large result. (2) fcvt.w.s/fcvt.wu.s's
// shift-amount/bit-window arithmetic was simply wrong (extracting the
// integer part from the wrong bit position entirely). (3) round_and_pack's
// own carry-renormalization mislabeled which bit becomes the new guard vs.
// round vs. sticky bit after an addition carry-out, corrupting the NX flag
// (and, in more extreme cases, the rounding decision itself) for exact or
// near-exact sums that happened to carry. See docs/adr/0019 for the full
// story -- none of these were found by reasoning about the RTL statically,
// all three were found by exactly this kind of vector-by-vector testing.
module tb_falu_unit;
    reg [4:0] funct5;
    reg [2:0] funct3;
    reg [4:0] rs2_sel;
    reg [31:0] a, b;
    wire [31:0] result;
    wire [4:0] flags;

    integer total_checks = 0;
    integer total_fails = 0;

    FALU dut(.funct5(funct5), .funct3(funct3), .rs2_sel(rs2_sel), .a(a), .b(b), .result(result), .flags(flags));

    task check_op;
        input [4:0] tfunct5;
        input [2:0] tfunct3;
        input [4:0] trs2;
        input [31:0] ta, tb;
        input [31:0] texpected_result;
        input [4:0] texpected_flags;
        input [1023:0] label;
        begin
            funct5 = tfunct5; funct3 = tfunct3; rs2_sel = trs2; a = ta; b = tb;
            #1;
            total_checks = total_checks + 1;
            if (result !== texpected_result || flags !== texpected_flags) begin
                total_fails = total_fails + 1;
                $display("  FAIL  %0s: result=0x%08h flags=%05b, expected result=0x%08h flags=%05b",
                    label, result, flags, texpected_result, texpected_flags);
            end
        end
    endtask

    initial begin
        check_op(5'b00000, 3'b001, 5'b00000, 32'hF13FD8BD, 32'h3F800000, 32'hF13FD8BC, 5'b00001, "fadd.s rand#0 rm=1");
        check_op(5'b00000, 3'b000, 5'b00000, 32'hFF800000, 32'h00000000, 32'hFF800000, 5'b00000, "fadd.s rand#1 rm=0");
        check_op(5'b00000, 3'b001, 5'b00000, 32'h393DC6CC, 32'hBF70BE6B, 32'hBF70B28E, 5'b00001, "fadd.s rand#2 rm=1");
        check_op(5'b00000, 3'b100, 5'b00000, 32'hFF800000, 32'h42F4FAF2, 32'hFF800000, 5'b00000, "fadd.s rand#3 rm=4");
        check_op(5'b00000, 3'b000, 5'b00000, 32'h00B97FAE, 32'h3F800000, 32'h3F800000, 5'b00001, "fadd.s rand#4 rm=0");
        check_op(5'b00000, 3'b001, 5'b00000, 32'h80000000, 32'h00A39149, 32'h00A39149, 5'b00000, "fadd.s rand#5 rm=1");
        check_op(5'b00000, 3'b000, 5'b00000, 32'h7F800000, 32'h1A2A73ED, 32'h7F800000, 5'b00000, "fadd.s rand#6 rm=0");
        check_op(5'b00000, 3'b000, 5'b00000, 32'h7EADF309, 32'hFF21DBD1, 32'hFE95C499, 5'b00000, "fadd.s rand#7 rm=0");
        check_op(5'b00000, 3'b010, 5'b00000, 32'h810FFA4D, 32'h7EC6A944, 32'h7EC6A943, 5'b00001, "fadd.s rand#8 rm=2");
        check_op(5'b00000, 3'b001, 5'b00000, 32'hFF189CE9, 32'hBA6E1E6B, 32'hFF189CE9, 5'b00001, "fadd.s rand#9 rm=1");
        check_op(5'b00000, 3'b000, 5'b00000, 32'hBF800000, 32'h3A3A49F0, 32'hBF7FD16E, 5'b00001, "fadd.s rand#10 rm=0");
        check_op(5'b00000, 3'b010, 5'b00000, 32'h7EBA0959, 32'h7F2F6217, 32'h7F7FFFFF, 5'b00101, "fadd.s rand#11 rm=2");
        check_op(5'b00000, 3'b000, 5'b00000, 32'h7F800000, 32'h3F800000, 32'h7F800000, 5'b00000, "fadd.s rand#12 rm=0");
        check_op(5'b00000, 3'b001, 5'b00000, 32'h80000000, 32'hFF800000, 32'hFF800000, 5'b00000, "fadd.s rand#13 rm=1");
        check_op(5'b00000, 3'b010, 5'b00000, 32'h01228DA6, 32'hFF800000, 32'hFF800000, 5'b00000, "fadd.s rand#14 rm=2");
        check_op(5'b00000, 3'b011, 5'b00000, 32'hBF0ABA36, 32'h3F1C2EF7, 32'h3D8BA608, 5'b00000, "fadd.s rand#15 rm=3");
        check_op(5'b00000, 3'b100, 5'b00000, 32'h3F800000, 32'hBA17873A, 32'h3F7FDA1E, 5'b00001, "fadd.s rand#16 rm=4");
        check_op(5'b00000, 3'b011, 5'b00000, 32'h366EB16F, 32'h00713D4C, 32'h366EB16F, 5'b00000, "fadd.s rand#17 rm=3");
        check_op(5'b00000, 3'b001, 5'b00000, 32'h00000000, 32'h3F800000, 32'h3F800000, 5'b00000, "fadd.s rand#18 rm=1");
        check_op(5'b00000, 3'b100, 5'b00000, 32'hFF800000, 32'h3F800000, 32'hFF800000, 5'b00000, "fadd.s rand#19 rm=4");
        check_op(5'b00001, 3'b001, 5'b00000, 32'h80CAB134, 32'h7E9C12B3, 32'hFE9C12B3, 5'b00001, "fsub.s rand#0 rm=1");
        check_op(5'b00001, 3'b001, 5'b00000, 32'h0060BD78, 32'h3F38E27B, 32'hBF38E27B, 5'b00000, "fsub.s rand#1 rm=1");
        check_op(5'b00001, 3'b011, 5'b00000, 32'h80000000, 32'h808821AD, 32'h008821AD, 5'b00000, "fsub.s rand#2 rm=3");
        check_op(5'b00001, 3'b100, 5'b00000, 32'hFEFF80E7, 32'h81202E56, 32'hFEFF80E7, 5'b00001, "fsub.s rand#3 rm=4");
        check_op(5'b00001, 3'b100, 5'b00000, 32'h43B4488E, 32'h7092C8D3, 32'hF092C8D3, 5'b00001, "fsub.s rand#4 rm=4");
        check_op(5'b00001, 3'b010, 5'b00000, 32'h3F800000, 32'h1C8EAEE9, 32'h3F7FFFFF, 5'b00001, "fsub.s rand#5 rm=2");
        check_op(5'b00001, 3'b010, 5'b00000, 32'h00BA139E, 32'h4462E870, 32'hC462E870, 5'b00001, "fsub.s rand#6 rm=2");
        check_op(5'b00001, 3'b010, 5'b00000, 32'h80000000, 32'h7115A6B9, 32'hF115A6B9, 5'b00000, "fsub.s rand#7 rm=2");
        check_op(5'b00001, 3'b010, 5'b00000, 32'h7F800000, 32'h00000000, 32'h7F800000, 5'b00000, "fsub.s rand#8 rm=2");
        check_op(5'b00001, 3'b011, 5'b00000, 32'h80000000, 32'h4345E3A1, 32'hC345E3A1, 5'b00000, "fsub.s rand#9 rm=3");
        check_op(5'b00001, 3'b010, 5'b00000, 32'hC44210EE, 32'hFF7E1F02, 32'h7F7E1F01, 5'b00001, "fsub.s rand#10 rm=2");
        check_op(5'b00001, 3'b100, 5'b00000, 32'hFF800000, 32'hBF04AC7B, 32'hFF800000, 5'b00000, "fsub.s rand#11 rm=4");
        check_op(5'b00001, 3'b100, 5'b00000, 32'hBA593CA7, 32'h8008DBF4, 32'hBA593CA7, 5'b00000, "fsub.s rand#12 rm=4");
        check_op(5'b00001, 3'b011, 5'b00000, 32'h00000000, 32'h00000000, 32'h00000000, 5'b00000, "fsub.s rand#13 rm=3");
        check_op(5'b00001, 3'b100, 5'b00000, 32'h80000000, 32'h3F800000, 32'hBF800000, 5'b00000, "fsub.s rand#14 rm=4");
        check_op(5'b00001, 3'b010, 5'b00000, 32'h809B1C34, 32'h7F800000, 32'hFF800000, 5'b00000, "fsub.s rand#15 rm=2");
        check_op(5'b00001, 3'b100, 5'b00000, 32'hFED5F9D6, 32'h7F73268D, 32'hFF800000, 5'b00101, "fsub.s rand#16 rm=4");
        check_op(5'b00001, 3'b000, 5'b00000, 32'h011FBB5F, 32'hFF800000, 32'h7F800000, 5'b00000, "fsub.s rand#17 rm=0");
        check_op(5'b00001, 3'b100, 5'b00000, 32'h05628059, 32'hFF800000, 32'h7F800000, 5'b00000, "fsub.s rand#18 rm=4");
        check_op(5'b00001, 3'b000, 5'b00000, 32'hFF800000, 32'hC45680E3, 32'hFF800000, 5'b00000, "fsub.s rand#19 rm=0");
        check_op(5'b00010, 3'b010, 5'b00000, 32'hFF800000, 32'h3A548E8E, 32'hFF800000, 5'b00000, "fmul.s rand#0 rm=2");
        check_op(5'b00010, 3'b011, 5'b00000, 32'h37ED8012, 32'h3F800000, 32'h37ED8012, 5'b00000, "fmul.s rand#1 rm=3");
        check_op(5'b00010, 3'b100, 5'b00000, 32'h7F800000, 32'h00000000, 32'h7FC00000, 5'b10000, "fmul.s rand#2 rm=4");
        check_op(5'b00010, 3'b001, 5'b00000, 32'h00646E68, 32'h80341A8A, 32'h80000000, 5'b00000, "fmul.s rand#3 rm=1");
        check_op(5'b00010, 3'b011, 5'b00000, 32'hF122CC61, 32'h00B637D3, 32'hB267C19A, 5'b00001, "fmul.s rand#4 rm=3");
        check_op(5'b00010, 3'b000, 5'b00000, 32'h815D525B, 32'h3EB1867A, 32'h80997A33, 5'b00001, "fmul.s rand#5 rm=0");
        check_op(5'b00010, 3'b000, 5'b00000, 32'hBE476E7E, 32'hCCF3A171, 32'h4BBDCBA6, 5'b00001, "fmul.s rand#6 rm=0");
        check_op(5'b00010, 3'b001, 5'b00000, 32'hFF800000, 32'h7F800000, 32'hFF800000, 5'b00000, "fmul.s rand#7 rm=1");
        check_op(5'b00010, 3'b010, 5'b00000, 32'h01360037, 32'h80000000, 32'h80000000, 5'b00000, "fmul.s rand#8 rm=2");
        check_op(5'b00010, 3'b100, 5'b00000, 32'h016FEF27, 32'hB8EE86E6, 32'h80000000, 5'b00011, "fmul.s rand#9 rm=4");
        check_op(5'b00010, 3'b001, 5'b00000, 32'hF1358414, 32'h446A7F85, 32'hF6264525, 5'b00001, "fmul.s rand#10 rm=1");
        check_op(5'b00010, 3'b001, 5'b00000, 32'h80000000, 32'h00BD9D27, 32'h80000000, 5'b00000, "fmul.s rand#11 rm=1");
        check_op(5'b00010, 3'b011, 5'b00000, 32'hFE87815D, 32'h80000000, 32'h00000000, 5'b00000, "fmul.s rand#12 rm=3");
        check_op(5'b00010, 3'b011, 5'b00000, 32'h4472A788, 32'h3F800000, 32'h4472A788, 5'b00000, "fmul.s rand#13 rm=3");
        check_op(5'b00010, 3'b100, 5'b00000, 32'hBF800000, 32'h80FA8962, 32'h00FA8962, 5'b00000, "fmul.s rand#14 rm=4");
        check_op(5'b00010, 3'b001, 5'b00000, 32'h00184E92, 32'hBF800000, 32'h80000000, 5'b00000, "fmul.s rand#15 rm=1");
        check_op(5'b00010, 3'b000, 5'b00000, 32'h3E222947, 32'h3EFDED4E, 32'h3DA0D91D, 5'b00001, "fmul.s rand#16 rm=0");
        check_op(5'b00010, 3'b000, 5'b00000, 32'h3E2C654D, 32'h80000000, 32'h80000000, 5'b00000, "fmul.s rand#17 rm=0");
        check_op(5'b00010, 3'b001, 5'b00000, 32'h3A383466, 32'h39474D96, 32'h340F688E, 5'b00001, "fmul.s rand#18 rm=1");
        check_op(5'b00010, 3'b100, 5'b00000, 32'h7EF88638, 32'hFF800000, 32'hFF800000, 5'b00000, "fmul.s rand#19 rm=4");
        check_op(5'b00000, 3'b000, 5'b00000, 32'h3F800000, 32'h7FC00000, 32'h7FC00000, 5'b00000, "1.0 + qNaN -> canonical NaN, no NV (quiet)");
        check_op(5'b00000, 3'b000, 5'b00000, 32'h3F800000, 32'h7F800001, 32'h7FC00000, 5'b10000, "1.0 + sNaN -> canonical NaN, NV set");
        check_op(5'b00000, 3'b000, 5'b00000, 32'h7F800000, 32'hFF800000, 32'h7FC00000, 5'b10000, "inf + (-inf) -> invalid");
        check_op(5'b00000, 3'b000, 5'b00000, 32'h7F800000, 32'h3F800000, 32'h7F800000, 5'b00000, "inf + 1.0 -> inf");
        check_op(5'b00000, 3'b000, 5'b00000, 32'h3F800000, 32'hBF800000, 32'h00000000, 5'b00000, "1.0 + (-1.0) -> +0 (RNE)");
        check_op(5'b00000, 3'b010, 5'b00000, 32'h3F800000, 32'hBF800000, 32'h80000000, 5'b00000, "1.0 + (-1.0) -> -0 (RDN)");
        check_op(5'b00000, 3'b000, 5'b00000, 32'h80000000, 32'h00000000, 32'h00000000, 5'b00000, "-0 + +0 -> +0 (RNE)");
        check_op(5'b00000, 3'b010, 5'b00000, 32'h80000000, 32'h00000000, 32'h80000000, 5'b00000, "-0 + +0 -> -0 (RDN)");
        check_op(5'b00000, 3'b000, 5'b00000, 32'h80000000, 32'h80000000, 32'h80000000, 5'b00000, "-0 + -0 -> -0");
        check_op(5'b00010, 3'b000, 5'b00000, 32'h00000000, 32'h7F800000, 32'h7FC00000, 5'b10000, "0 * inf -> invalid");
        check_op(5'b00010, 3'b000, 5'b00000, 32'hC0000000, 32'h40400000, 32'hC0C00000, 5'b00000, "-2.0 * 3.0 = -6.0");
        check_op(5'b00010, 3'b000, 5'b00000, 32'h7F800000, 32'hBF800000, 32'hFF800000, 5'b00000, "inf * -1.0 -> -inf");
        check_op(5'b00000, 3'b000, 5'b00000, 32'h7F7FC99E, 32'h7F7FC99E, 32'h7F800000, 5'b00101, "overflow -> +inf (RNE), OF+NX");
        check_op(5'b00000, 3'b001, 5'b00000, 32'h7F7FC99E, 32'h7F7FC99E, 32'h7F7FFFFF, 5'b00101, "overflow -> largest finite (RTZ), OF+NX");
        check_op(5'b00100, 3'b000, 5'b00000, 32'h40400000, 32'hC0A00000, 32'hC0400000, 5'b00000, "fsgnj.s: |3.0| with sign of -5.0");
        check_op(5'b00100, 3'b001, 5'b00000, 32'hC0400000, 32'hC0A00000, 32'h40400000, 5'b00000, "fsgnjn.s: |3.0| with ~sign of -5.0");
        check_op(5'b00100, 3'b010, 5'b00000, 32'h40400000, 32'hC0A00000, 32'hC0400000, 5'b00000, "fsgnjx.s: sign_a ^ sign_b (0^1=1) applied to |3.0|");
        check_op(5'b00100, 3'b010, 5'b00000, 32'hC0400000, 32'hC0A00000, 32'h40400000, 5'b00000, "fsgnjx.s: sign_a ^ sign_b (1^1=0) applied to |3.0|");
        check_op(5'b00101, 3'b000, 5'b00000, 32'h3F800000, 32'h40000000, 32'h3F800000, 5'b00000, "fmin(1.0,2.0)=1.0");
        check_op(5'b00101, 3'b001, 5'b00000, 32'h3F800000, 32'h40000000, 32'h40000000, 5'b00000, "fmax(1.0,2.0)=2.0");
        check_op(5'b00101, 3'b000, 5'b00000, 32'h80000000, 32'h00000000, 32'h80000000, 5'b00000, "fmin(-0,+0)=-0");
        check_op(5'b00101, 3'b001, 5'b00000, 32'h80000000, 32'h00000000, 32'h00000000, 5'b00000, "fmax(-0,+0)=+0");
        check_op(5'b00101, 3'b000, 5'b00000, 32'h7FC00000, 32'h40A00000, 32'h40A00000, 5'b00000, "fmin(qNaN,5.0)=5.0, no NV");
        check_op(5'b00101, 3'b000, 5'b00000, 32'h7F800001, 32'h40A00000, 32'h40A00000, 5'b10000, "fmin(sNaN,5.0)=5.0, NV set");
        check_op(5'b00101, 3'b000, 5'b00000, 32'h7FC00000, 32'h7FC00000, 32'h7FC00000, 5'b00000, "fmin(qNaN,qNaN)=canonical NaN, no NV");
        check_op(5'b10100, 3'b010, 5'b00000, 32'h3F800000, 32'h3F800000, 32'h00000001, 5'b00000, "feq(1.0,1.0)=1");
        check_op(5'b10100, 3'b010, 5'b00000, 32'h80000000, 32'h00000000, 32'h00000001, 5'b00000, "feq(-0,+0)=1");
        check_op(5'b10100, 3'b001, 5'b00000, 32'h3F800000, 32'h40000000, 32'h00000001, 5'b00000, "flt(1.0,2.0)=1");
        check_op(5'b10100, 3'b000, 5'b00000, 32'h3F800000, 32'h3F800000, 32'h00000001, 5'b00000, "fle(1.0,1.0)=1");
        check_op(5'b10100, 3'b010, 5'b00000, 32'h7FC00000, 32'h3F800000, 32'h00000000, 5'b00000, "feq(qNaN,1.0)=0, no NV");
        check_op(5'b10100, 3'b010, 5'b00000, 32'h7F800001, 32'h3F800000, 32'h00000000, 5'b10000, "feq(sNaN,1.0)=0, NV set");
        check_op(5'b10100, 3'b001, 5'b00000, 32'h7FC00000, 32'h3F800000, 32'h00000000, 5'b10000, "flt(qNaN,1.0)=0, NV set (unlike feq)");
        check_op(5'b10100, 3'b000, 5'b00000, 32'h7FC00000, 32'h3F800000, 32'h00000000, 5'b10000, "fle(qNaN,1.0)=0, NV set (unlike feq)");
        check_op(5'b11100, 3'b001, 5'b00000, 32'hFF800000, 32'h00000000, 32'h00000001, 5'b00000, "fclass(-inf) = bit0");
        check_op(5'b11100, 3'b001, 5'b00000, 32'hBF800000, 32'h00000000, 32'h00000002, 5'b00000, "fclass(-1.0) = bit1 (-normal)");
        check_op(5'b11100, 3'b001, 5'b00000, 32'h80000001, 32'h00000000, 32'h00000004, 5'b00000, "fclass(-subnormal) = bit2");
        check_op(5'b11100, 3'b001, 5'b00000, 32'h80000000, 32'h00000000, 32'h00000008, 5'b00000, "fclass(-0) = bit3");
        check_op(5'b11100, 3'b001, 5'b00000, 32'h00000000, 32'h00000000, 32'h00000010, 5'b00000, "fclass(+0) = bit4");
        check_op(5'b11100, 3'b001, 5'b00000, 32'h00000001, 32'h00000000, 32'h00000020, 5'b00000, "fclass(+subnormal) = bit5");
        check_op(5'b11100, 3'b001, 5'b00000, 32'h3F800000, 32'h00000000, 32'h00000040, 5'b00000, "fclass(+1.0) = bit6 (+normal)");
        check_op(5'b11100, 3'b001, 5'b00000, 32'h7F800000, 32'h00000000, 32'h00000080, 5'b00000, "fclass(+inf) = bit7");
        check_op(5'b11100, 3'b001, 5'b00000, 32'h7F800001, 32'h00000000, 32'h00000100, 5'b00000, "fclass(sNaN) = bit8");
        check_op(5'b11100, 3'b001, 5'b00000, 32'h7FC00000, 32'h00000000, 32'h00000200, 5'b00000, "fclass(qNaN) = bit9");
        check_op(5'b11100, 3'b000, 5'b00000, 32'hDEADBEEF, 32'h00000000, 32'hDEADBEEF, 5'b00000, "fmv.x.w: raw bit passthrough");
        check_op(5'b11110, 3'b000, 5'b00000, 32'hCAFEBABE, 32'h00000000, 32'hCAFEBABE, 5'b00000, "fmv.w.x: raw bit passthrough");
        check_op(5'b11000, 3'b000, 5'b00000, 32'h3F800000, 32'h00000000, 32'h00000001, 5'b00000, "fcvt.w.s(1.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'h3F800000, 32'h00000000, 32'h00000001, 5'b00000, "fcvt.w.s(1.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'h3F800000, 32'h00000000, 32'h00000001, 5'b00000, "fcvt.wu.s(1.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'h3F800000, 32'h00000000, 32'h00000001, 5'b00000, "fcvt.wu.s(1.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'hBF800000, 32'h00000000, 32'hFFFFFFFF, 5'b00000, "fcvt.w.s(-1.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'hBF800000, 32'h00000000, 32'hFFFFFFFF, 5'b00000, "fcvt.w.s(-1.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'hBF800000, 32'h00000000, 32'h00000000, 5'b10000, "fcvt.wu.s(-1.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'hBF800000, 32'h00000000, 32'h00000000, 5'b10000, "fcvt.wu.s(-1.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'h3FC00000, 32'h00000000, 32'h00000002, 5'b00001, "fcvt.w.s(1.5) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'h3FC00000, 32'h00000000, 32'h00000001, 5'b00001, "fcvt.w.s(1.5) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'h3FC00000, 32'h00000000, 32'h00000002, 5'b00001, "fcvt.wu.s(1.5) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'h3FC00000, 32'h00000000, 32'h00000001, 5'b00001, "fcvt.wu.s(1.5) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'hBFC00000, 32'h00000000, 32'hFFFFFFFE, 5'b00001, "fcvt.w.s(-1.5) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'hBFC00000, 32'h00000000, 32'hFFFFFFFF, 5'b00001, "fcvt.w.s(-1.5) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'hBFC00000, 32'h00000000, 32'h00000000, 5'b10000, "fcvt.wu.s(-1.5) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'hBFC00000, 32'h00000000, 32'h00000000, 5'b10000, "fcvt.wu.s(-1.5) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'h40200000, 32'h00000000, 32'h00000002, 5'b00001, "fcvt.w.s(2.5) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'h40200000, 32'h00000000, 32'h00000002, 5'b00001, "fcvt.w.s(2.5) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'h40200000, 32'h00000000, 32'h00000002, 5'b00001, "fcvt.wu.s(2.5) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'h40200000, 32'h00000000, 32'h00000002, 5'b00001, "fcvt.wu.s(2.5) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'hC0200000, 32'h00000000, 32'hFFFFFFFE, 5'b00001, "fcvt.w.s(-2.5) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'hC0200000, 32'h00000000, 32'hFFFFFFFE, 5'b00001, "fcvt.w.s(-2.5) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'hC0200000, 32'h00000000, 32'h00000000, 5'b10000, "fcvt.wu.s(-2.5) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'hC0200000, 32'h00000000, 32'h00000000, 5'b10000, "fcvt.wu.s(-2.5) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'h3ECCCCCD, 32'h00000000, 32'h00000000, 5'b00001, "fcvt.w.s(0.4) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'h3ECCCCCD, 32'h00000000, 32'h00000000, 5'b00001, "fcvt.w.s(0.4) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'h3ECCCCCD, 32'h00000000, 32'h00000000, 5'b00001, "fcvt.wu.s(0.4) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'h3ECCCCCD, 32'h00000000, 32'h00000000, 5'b00001, "fcvt.wu.s(0.4) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'hBECCCCCD, 32'h00000000, 32'h00000000, 5'b00001, "fcvt.w.s(-0.4) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'hBECCCCCD, 32'h00000000, 32'h00000000, 5'b00001, "fcvt.w.s(-0.4) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'hBECCCCCD, 32'h00000000, 32'h00000000, 5'b00001, "fcvt.wu.s(-0.4) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'hBECCCCCD, 32'h00000000, 32'h00000000, 5'b00001, "fcvt.wu.s(-0.4) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'h3F19999A, 32'h00000000, 32'h00000001, 5'b00001, "fcvt.w.s(0.6) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'h3F19999A, 32'h00000000, 32'h00000000, 5'b00001, "fcvt.w.s(0.6) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'h3F19999A, 32'h00000000, 32'h00000001, 5'b00001, "fcvt.wu.s(0.6) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'h3F19999A, 32'h00000000, 32'h00000000, 5'b00001, "fcvt.wu.s(0.6) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'hBF19999A, 32'h00000000, 32'hFFFFFFFF, 5'b00001, "fcvt.w.s(-0.6) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'hBF19999A, 32'h00000000, 32'h00000000, 5'b00001, "fcvt.w.s(-0.6) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'hBF19999A, 32'h00000000, 32'h00000000, 5'b10000, "fcvt.wu.s(-0.6) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'hBF19999A, 32'h00000000, 32'h00000000, 5'b00001, "fcvt.wu.s(-0.6) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'h40400000, 32'h00000000, 32'h00000003, 5'b00000, "fcvt.w.s(3.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'h40400000, 32'h00000000, 32'h00000003, 5'b00000, "fcvt.w.s(3.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'h40400000, 32'h00000000, 32'h00000003, 5'b00000, "fcvt.wu.s(3.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'h40400000, 32'h00000000, 32'h00000003, 5'b00000, "fcvt.wu.s(3.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'h4F000000, 32'h00000000, 32'h7FFFFFFF, 5'b10000, "fcvt.w.s(2147483647.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'h4F000000, 32'h00000000, 32'h7FFFFFFF, 5'b10000, "fcvt.w.s(2147483647.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'h4F000000, 32'h00000000, 32'h80000000, 5'b00000, "fcvt.wu.s(2147483647.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'h4F000000, 32'h00000000, 32'h80000000, 5'b00000, "fcvt.wu.s(2147483647.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'hCF000000, 32'h00000000, 32'h80000000, 5'b00000, "fcvt.w.s(-2147483648.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'hCF000000, 32'h00000000, 32'h80000000, 5'b00000, "fcvt.w.s(-2147483648.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'hCF000000, 32'h00000000, 32'h00000000, 5'b10000, "fcvt.wu.s(-2147483648.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'hCF000000, 32'h00000000, 32'h00000000, 5'b10000, "fcvt.wu.s(-2147483648.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'h501502F9, 32'h00000000, 32'h7FFFFFFF, 5'b10000, "fcvt.w.s(10000000000.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'h501502F9, 32'h00000000, 32'h7FFFFFFF, 5'b10000, "fcvt.w.s(10000000000.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'h501502F9, 32'h00000000, 32'hFFFFFFFF, 5'b10000, "fcvt.wu.s(10000000000.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'h501502F9, 32'h00000000, 32'hFFFFFFFF, 5'b10000, "fcvt.wu.s(10000000000.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'hD01502F9, 32'h00000000, 32'h80000000, 5'b10000, "fcvt.w.s(-10000000000.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'hD01502F9, 32'h00000000, 32'h80000000, 5'b10000, "fcvt.w.s(-10000000000.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'hD01502F9, 32'h00000000, 32'h00000000, 5'b10000, "fcvt.wu.s(-10000000000.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'hD01502F9, 32'h00000000, 32'h00000000, 5'b10000, "fcvt.wu.s(-10000000000.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'h4F800000, 32'h00000000, 32'h7FFFFFFF, 5'b10000, "fcvt.w.s(4294967295.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'h4F800000, 32'h00000000, 32'h7FFFFFFF, 5'b10000, "fcvt.w.s(4294967295.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'h4F800000, 32'h00000000, 32'hFFFFFFFF, 5'b10000, "fcvt.wu.s(4294967295.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'h4F800000, 32'h00000000, 32'hFFFFFFFF, 5'b10000, "fcvt.wu.s(4294967295.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'h00000000, 32'h00000000, 32'h00000000, 5'b00000, "fcvt.w.s(0.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'h00000000, 32'h00000000, 32'h00000000, 5'b00000, "fcvt.w.s(0.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'h00000000, 32'h00000000, 32'h00000000, 5'b00000, "fcvt.wu.s(0.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'h00000000, 32'h00000000, 32'h00000000, 5'b00000, "fcvt.wu.s(0.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'h80000000, 32'h00000000, 32'h00000000, 5'b00000, "fcvt.w.s(-0.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00000, 32'h80000000, 32'h00000000, 32'h00000000, 5'b00000, "fcvt.w.s(-0.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00001, 32'h80000000, 32'h00000000, 32'h00000000, 5'b00000, "fcvt.wu.s(-0.0) rm=0");
        check_op(5'b11000, 3'b001, 5'b00001, 32'h80000000, 32'h00000000, 32'h00000000, 5'b00000, "fcvt.wu.s(-0.0) rm=1");
        check_op(5'b11000, 3'b000, 5'b00000, 32'h7FC00000, 32'h00000000, 32'h7FFFFFFF, 5'b10000, "fcvt.w.s(qNaN)");
        check_op(5'b11000, 3'b000, 5'b00001, 32'h7FC00000, 32'h00000000, 32'hFFFFFFFF, 5'b10000, "fcvt.wu.s(qNaN)");
        check_op(5'b11000, 3'b000, 5'b00000, 32'h7F800001, 32'h00000000, 32'h7FFFFFFF, 5'b10000, "fcvt.w.s(sNaN)");
        check_op(5'b11000, 3'b000, 5'b00001, 32'h7F800001, 32'h00000000, 32'hFFFFFFFF, 5'b10000, "fcvt.wu.s(sNaN)");
        check_op(5'b11000, 3'b000, 5'b00000, 32'h7F800000, 32'h00000000, 32'h7FFFFFFF, 5'b10000, "fcvt.w.s(+inf)");
        check_op(5'b11000, 3'b000, 5'b00001, 32'h7F800000, 32'h00000000, 32'hFFFFFFFF, 5'b10000, "fcvt.wu.s(+inf)");
        check_op(5'b11000, 3'b000, 5'b00000, 32'hFF800000, 32'h00000000, 32'h80000000, 5'b10000, "fcvt.w.s(-inf)");
        check_op(5'b11000, 3'b000, 5'b00001, 32'hFF800000, 32'h00000000, 32'h00000000, 5'b10000, "fcvt.wu.s(-inf)");
        check_op(5'b11010, 3'b000, 5'b00000, 32'h00000000, 32'h00000000, 32'h00000000, 5'b00000, "fcvt.s.w(0) rm=0");
        check_op(5'b11010, 3'b001, 5'b00000, 32'h00000000, 32'h00000000, 32'h00000000, 5'b00000, "fcvt.s.w(0) rm=1");
        check_op(5'b11010, 3'b000, 5'b00001, 32'h00000000, 32'h00000000, 32'h00000000, 5'b00000, "fcvt.s.wu(0) rm=0");
        check_op(5'b11010, 3'b001, 5'b00001, 32'h00000000, 32'h00000000, 32'h00000000, 5'b00000, "fcvt.s.wu(0) rm=1");
        check_op(5'b11010, 3'b000, 5'b00000, 32'h00000001, 32'h00000000, 32'h3F800000, 5'b00000, "fcvt.s.w(1) rm=0");
        check_op(5'b11010, 3'b001, 5'b00000, 32'h00000001, 32'h00000000, 32'h3F800000, 5'b00000, "fcvt.s.w(1) rm=1");
        check_op(5'b11010, 3'b000, 5'b00001, 32'h00000001, 32'h00000000, 32'h3F800000, 5'b00000, "fcvt.s.wu(1) rm=0");
        check_op(5'b11010, 3'b001, 5'b00001, 32'h00000001, 32'h00000000, 32'h3F800000, 5'b00000, "fcvt.s.wu(1) rm=1");
        check_op(5'b11010, 3'b000, 5'b00000, 32'hFFFFFFFF, 32'h00000000, 32'hBF800000, 5'b00000, "fcvt.s.w(-1) rm=0");
        check_op(5'b11010, 3'b001, 5'b00000, 32'hFFFFFFFF, 32'h00000000, 32'hBF800000, 5'b00000, "fcvt.s.w(-1) rm=1");
        check_op(5'b11010, 3'b000, 5'b00001, 32'hFFFFFFFF, 32'h00000000, 32'h4F800000, 5'b00001, "fcvt.s.wu(-1) rm=0");
        check_op(5'b11010, 3'b001, 5'b00001, 32'hFFFFFFFF, 32'h00000000, 32'h4F7FFFFF, 5'b00001, "fcvt.s.wu(-1) rm=1");
        check_op(5'b11010, 3'b000, 5'b00000, 32'h00000064, 32'h00000000, 32'h42C80000, 5'b00000, "fcvt.s.w(100) rm=0");
        check_op(5'b11010, 3'b001, 5'b00000, 32'h00000064, 32'h00000000, 32'h42C80000, 5'b00000, "fcvt.s.w(100) rm=1");
        check_op(5'b11010, 3'b000, 5'b00001, 32'h00000064, 32'h00000000, 32'h42C80000, 5'b00000, "fcvt.s.wu(100) rm=0");
        check_op(5'b11010, 3'b001, 5'b00001, 32'h00000064, 32'h00000000, 32'h42C80000, 5'b00000, "fcvt.s.wu(100) rm=1");
        check_op(5'b11010, 3'b000, 5'b00000, 32'hFFFFFF9C, 32'h00000000, 32'hC2C80000, 5'b00000, "fcvt.s.w(-100) rm=0");
        check_op(5'b11010, 3'b001, 5'b00000, 32'hFFFFFF9C, 32'h00000000, 32'hC2C80000, 5'b00000, "fcvt.s.w(-100) rm=1");
        check_op(5'b11010, 3'b000, 5'b00001, 32'hFFFFFF9C, 32'h00000000, 32'h4F800000, 5'b00001, "fcvt.s.wu(-100) rm=0");
        check_op(5'b11010, 3'b001, 5'b00001, 32'hFFFFFF9C, 32'h00000000, 32'h4F7FFFFF, 5'b00001, "fcvt.s.wu(-100) rm=1");
        check_op(5'b11010, 3'b000, 5'b00000, 32'h7FFFFFFF, 32'h00000000, 32'h4F000000, 5'b00001, "fcvt.s.w(2147483647) rm=0");
        check_op(5'b11010, 3'b001, 5'b00000, 32'h7FFFFFFF, 32'h00000000, 32'h4EFFFFFF, 5'b00001, "fcvt.s.w(2147483647) rm=1");
        check_op(5'b11010, 3'b000, 5'b00001, 32'h7FFFFFFF, 32'h00000000, 32'h4F000000, 5'b00001, "fcvt.s.wu(2147483647) rm=0");
        check_op(5'b11010, 3'b001, 5'b00001, 32'h7FFFFFFF, 32'h00000000, 32'h4EFFFFFF, 5'b00001, "fcvt.s.wu(2147483647) rm=1");
        check_op(5'b11010, 3'b000, 5'b00000, 32'h80000000, 32'h00000000, 32'hCF000000, 5'b00000, "fcvt.s.w(-2147483648) rm=0");
        check_op(5'b11010, 3'b001, 5'b00000, 32'h80000000, 32'h00000000, 32'hCF000000, 5'b00000, "fcvt.s.w(-2147483648) rm=1");
        check_op(5'b11010, 3'b000, 5'b00001, 32'h80000000, 32'h00000000, 32'h4F000000, 5'b00000, "fcvt.s.wu(-2147483648) rm=0");
        check_op(5'b11010, 3'b001, 5'b00001, 32'h80000000, 32'h00000000, 32'h4F000000, 5'b00000, "fcvt.s.wu(-2147483648) rm=1");
        check_op(5'b11010, 3'b000, 5'b00000, 32'h01000000, 32'h00000000, 32'h4B800000, 5'b00000, "fcvt.s.w(16777216) rm=0");
        check_op(5'b11010, 3'b001, 5'b00000, 32'h01000000, 32'h00000000, 32'h4B800000, 5'b00000, "fcvt.s.w(16777216) rm=1");
        check_op(5'b11010, 3'b000, 5'b00001, 32'h01000000, 32'h00000000, 32'h4B800000, 5'b00000, "fcvt.s.wu(16777216) rm=0");
        check_op(5'b11010, 3'b001, 5'b00001, 32'h01000000, 32'h00000000, 32'h4B800000, 5'b00000, "fcvt.s.wu(16777216) rm=1");
        check_op(5'b11010, 3'b000, 5'b00000, 32'h01000001, 32'h00000000, 32'h4B800000, 5'b00001, "fcvt.s.w(16777217) rm=0");
        check_op(5'b11010, 3'b001, 5'b00000, 32'h01000001, 32'h00000000, 32'h4B800000, 5'b00001, "fcvt.s.w(16777217) rm=1");
        check_op(5'b11010, 3'b000, 5'b00001, 32'h01000001, 32'h00000000, 32'h4B800000, 5'b00001, "fcvt.s.wu(16777217) rm=0");
        check_op(5'b11010, 3'b001, 5'b00001, 32'h01000001, 32'h00000000, 32'h4B800000, 5'b00001, "fcvt.s.wu(16777217) rm=1");
        check_op(5'b11010, 3'b000, 5'b00000, 32'hFEFFFFFF, 32'h00000000, 32'hCB800000, 5'b00001, "fcvt.s.w(-16777217) rm=0");
        check_op(5'b11010, 3'b001, 5'b00000, 32'hFEFFFFFF, 32'h00000000, 32'hCB800000, 5'b00001, "fcvt.s.w(-16777217) rm=1");
        check_op(5'b11010, 3'b000, 5'b00001, 32'hFEFFFFFF, 32'h00000000, 32'h4F7F0000, 5'b00001, "fcvt.s.wu(-16777217) rm=0");
        check_op(5'b11010, 3'b001, 5'b00001, 32'hFEFFFFFF, 32'h00000000, 32'h4F7EFFFF, 5'b00001, "fcvt.s.wu(-16777217) rm=1");
        check_op(5'b11010, 3'b000, 5'b00000, 32'hFFFFFFFF, 32'h00000000, 32'hBF800000, 5'b00000, "fcvt.s.w(4294967295) rm=0");
        check_op(5'b11010, 3'b001, 5'b00000, 32'hFFFFFFFF, 32'h00000000, 32'hBF800000, 5'b00000, "fcvt.s.w(4294967295) rm=1");
        check_op(5'b11010, 3'b000, 5'b00001, 32'hFFFFFFFF, 32'h00000000, 32'h4F800000, 5'b00001, "fcvt.s.wu(4294967295) rm=0");
        check_op(5'b11010, 3'b001, 5'b00001, 32'hFFFFFFFF, 32'h00000000, 32'h4F7FFFFF, 5'b00001, "fcvt.s.wu(4294967295) rm=1");

        if (total_fails == 0)
            $display("PASS  falu_unit (%0d checks)", total_checks);
        else
            $display("FAIL  falu_unit (%0d/%0d checks failed)", total_fails, total_checks);
        $finish;
    end
endmodule
