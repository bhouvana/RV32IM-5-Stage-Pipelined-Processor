`include "FMADDUnit.v"

// Standalone unit test for FMADDUnit.v, independent of the pipeline --
// mirrors tb_falu_unit.v's shape for docs/adr/0019-f-extension.md/Phase C5.
// Every expected value computed by an independent Python reference model
// (exact Fraction arithmetic on rs1*rs2 and the addend separately, summed
// exactly before rounding once -- the actual point of "fused" multiply-
// add). A curated subset of a larger (~3000-vector random + 2000-vector
// extreme-exponent) batch used during development but not committed,
// matching this project's convention of committing curated regression
// tests rather than bulk-generated ones.
//
// Unlike every other new FPU module this phase, FMADDUnit.v's design
// passed its full development-scale vector batch (3013/3013, then a
// further 2000/2000 extreme-exponent-targeted batch) on the very first
// run -- worth noting explicitly rather than silently, since every other
// module here found real bugs and it would be easy to assume this one
// just wasn't tested as hard. It wasn't spared complexity: it reuses
// FALU.v's FADD/FSUB swap-for-subtraction technique and fp_round.vh's
// round_and_pack, widened to a 112-bit alignment frame so the full,
// unrounded 48-bit product survives intact until the single final
// rounding step (see the module's own header comment for the frame
// layout). Applying the stale-register-on-the-last-iteration lesson
// FDivider.v's and FSqrt.v's own development already found (this module
// is combinational, so that specific bug class doesn't apply here, but
// the FADD-style swap/subtraction-sign logic and the wide sticky-shift
// were both built carefully from already-verified patterns rather than
// from scratch) is the most likely reason nothing new turned up.
module tb_fmaddunit_unit;
    reg [1:0] op = 0;
    reg [2:0] rm = 0;
    reg [31:0] a = 0, b = 0, c = 0;
    wire [31:0] result;
    wire [4:0] flags;

    integer total_checks = 0;
    integer total_fails = 0;

    FMADDUnit dut(.op(op), .rm(rm), .a(a), .b(b), .c(c), .result(result), .flags(flags));

    task run_case;
        input [1:0] top;
        input [2:0] trm;
        input [31:0] ta, tb, tc;
        input [31:0] texp_result;
        input [4:0] texp_flags;
        input [1023:0] label;
        begin
            op = top; rm = trm; a = ta; b = tb; c = tc;
            #1;
            total_checks = total_checks + 1;
            if (result !== texp_result || flags !== texp_flags) begin
                total_fails = total_fails + 1;
                $display("  FAIL  %0s: result=0x%08h flags=%05b, expected result=0x%08h flags=%05b",
                    label, result, flags, texp_result, texp_flags);
            end
        end
    endtask

    initial begin
        run_case(2'b10, 3'b000, 32'hD85D6A96, 32'h00000000, 32'hD804B82F, 32'hD804B82F, 5'b00000, "fma rand#0 op=2 rm=0");
        run_case(2'b10, 3'b001, 32'h3B4CACB0, 32'h44236A60, 32'hFF800000, 32'hFF800000, 5'b00000, "fma rand#1 op=2 rm=1");
        run_case(2'b00, 3'b001, 32'h3A43D692, 32'h3A5B477F, 32'hBF0C1387, 32'hBF0C137C, 5'b00001, "fma rand#2 op=0 rm=1");
        run_case(2'b10, 3'b010, 32'hBE7834B7, 32'hC3A09F41, 32'h5724D6C8, 32'h5724D6C7, 5'b00001, "fma rand#3 op=2 rm=2");
        run_case(2'b10, 3'b000, 32'h80362431, 32'h00000000, 32'hBA6FE204, 32'hBA6FE204, 5'b00000, "fma rand#4 op=2 rm=0");
        run_case(2'b00, 3'b001, 32'h0084E178, 32'hFF800000, 32'hBF800000, 32'hFF800000, 5'b00000, "fma rand#5 op=0 rm=1");
        run_case(2'b10, 3'b011, 32'h80000000, 32'h00AA1FD4, 32'h0025855D, 32'h00000000, 5'b00000, "fma rand#6 op=2 rm=3");
        run_case(2'b01, 3'b001, 32'hFF800000, 32'h00000000, 32'h80931157, 32'h7FC00000, 5'b10000, "fma rand#7 op=1 rm=1");
        run_case(2'b11, 3'b000, 32'h3F30BFBF, 32'h00000000, 32'h20B237C0, 32'hA0B237C0, 5'b00000, "fma rand#8 op=3 rm=0");
        run_case(2'b01, 3'b011, 32'h5623E334, 32'hB97A115E, 32'h3EC1B29A, 32'hD02016FF, 5'b00001, "fma rand#9 op=1 rm=3");
        run_case(2'b11, 3'b001, 32'h80000000, 32'h00000000, 32'h7F800000, 32'hFF800000, 5'b00000, "fma rand#10 op=3 rm=1");
        run_case(2'b11, 3'b001, 32'h43E85AEF, 32'hBD7921EB, 32'hD7AF3848, 32'h57AF3848, 5'b00001, "fma rand#11 op=3 rm=1");
        run_case(2'b01, 3'b011, 32'h00000000, 32'hC34461EB, 32'h00772989, 32'h80000000, 5'b00000, "fma rand#12 op=1 rm=3");
        run_case(2'b10, 3'b000, 32'h805791EE, 32'h3A70210B, 32'h7F800000, 32'h7F800000, 5'b00000, "fma rand#13 op=2 rm=0");
        run_case(2'b01, 3'b011, 32'hD819EFD9, 32'h80000000, 32'h57EED384, 32'hD7EED384, 5'b00000, "fma rand#14 op=1 rm=3");
        run_case(2'b00, 3'b010, 32'h00000000, 32'hD7330437, 32'h80000000, 32'h80000000, 5'b00000, "fma rand#15 op=0 rm=2");
        run_case(2'b10, 3'b011, 32'hBF08BB48, 32'hBF146C6D, 32'hC4325AB8, 32'hC4326E89, 5'b00001, "fma rand#16 op=2 rm=3");
        run_case(2'b01, 3'b100, 32'h3A5F653F, 32'h3F800000, 32'hBF800000, 32'h3F801BED, 5'b00001, "fma rand#17 op=1 rm=4");
        run_case(2'b00, 3'b100, 32'hFF800000, 32'h00000000, 32'h39D39B0A, 32'h7FC00000, 5'b10000, "fma rand#18 op=0 rm=4");
        run_case(2'b00, 3'b010, 32'h29E3D125, 32'h80000000, 32'hBF7F7DDF, 32'hBF7F7DDF, 5'b00000, "fma rand#19 op=0 rm=2");
        run_case(2'b00, 3'b000, 32'h585B86A2, 32'hD7DAA74F, 32'h3A830BCE, 32'hF0BB801F, 5'b00001, "fma rand#20 op=0 rm=0");
        run_case(2'b10, 3'b000, 32'h805EB04B, 32'hBF050D57, 32'h80000000, 32'h80000000, 5'b00000, "fma rand#21 op=2 rm=0");
        run_case(2'b00, 3'b011, 32'h80A8CBF2, 32'hFF800000, 32'hBF800000, 32'h7F800000, 5'b00000, "fma rand#22 op=0 rm=3");
        run_case(2'b01, 3'b011, 32'h80000000, 32'h00000000, 32'h3F800000, 32'hBF800000, 5'b00000, "fma rand#23 op=1 rm=3");
        run_case(2'b10, 3'b001, 32'hBE5CF4BA, 32'h39A52510, 32'h3F800000, 32'h3F80023A, 5'b00001, "fma rand#24 op=2 rm=1");
        run_case(2'b10, 3'b010, 32'hBF800000, 32'hFF800000, 32'h7F800000, 32'h7FC00000, 5'b10000, "fma rand#25 op=2 rm=2");
        run_case(2'b11, 3'b100, 32'h802677F8, 32'hBF42EC0B, 32'hBF800000, 32'h3F800000, 5'b00000, "fma rand#26 op=3 rm=4");
        run_case(2'b01, 3'b001, 32'h3F800000, 32'h00000000, 32'h8099A6A4, 32'h0099A6A4, 5'b00000, "fma rand#27 op=1 rm=1");
        run_case(2'b01, 3'b000, 32'h802E873A, 32'h3F5A3E11, 32'hFF800000, 32'h7F800000, 5'b00000, "fma rand#28 op=1 rm=0");
        run_case(2'b00, 3'b100, 32'hBE3BC9FE, 32'hBF800000, 32'h80000000, 32'h3E3BC9FE, 5'b00000, "fma rand#29 op=0 rm=4");
        run_case(2'b10, 3'b011, 32'h3F422414, 32'hFF800000, 32'h8016F5ED, 32'h7F800000, 5'b00000, "fma rand#30 op=2 rm=3");
        run_case(2'b01, 3'b001, 32'hFF800000, 32'hD78CA149, 32'h005649CB, 32'h7F800000, 5'b00000, "fma rand#31 op=1 rm=1");
        run_case(2'b10, 3'b000, 32'h3F800000, 32'h80000000, 32'h80000000, 32'h00000000, 5'b00000, "fma rand#32 op=2 rm=0");
        run_case(2'b00, 3'b100, 32'hBF6E6CCC, 32'h801B7686, 32'h7F800000, 32'h7F800000, 5'b00000, "fma rand#33 op=0 rm=4");
        run_case(2'b10, 3'b011, 32'hBF800000, 32'h582DA8E8, 32'hD7071E05, 32'h580BE167, 5'b00001, "fma rand#34 op=2 rm=3");
        run_case(2'b10, 3'b000, 32'h80000000, 32'hBF262B82, 32'h00000000, 32'h00000000, 5'b00000, "fma rand#35 op=2 rm=0");
        run_case(2'b00, 3'b001, 32'h7F800000, 32'hBF797456, 32'h3775755D, 32'hFF800000, 5'b00000, "fma rand#36 op=0 rm=1");
        run_case(2'b10, 3'b000, 32'h80000000, 32'h575028A9, 32'hD8602136, 32'hD8602136, 5'b00000, "fma rand#37 op=2 rm=0");
        run_case(2'b00, 3'b010, 32'h3F800000, 32'h3F6B4EAF, 32'h3F800000, 32'h3FF5A757, 5'b00001, "fma rand#38 op=0 rm=2");
        run_case(2'b10, 3'b011, 32'h7F800000, 32'h6EEF9553, 32'h5F8A58E9, 32'hFF800000, 5'b00000, "fma rand#39 op=2 rm=3");
        run_case(2'b00, 3'b011, 32'h80000000, 32'h00132942, 32'h00000000, 32'h00000000, 5'b00000, "fma rand#40 op=0 rm=3");
        run_case(2'b11, 3'b000, 32'h584F39AF, 32'hBF800000, 32'hB9C0D8C4, 32'h584F39AF, 5'b00001, "fma rand#41 op=3 rm=0");
        run_case(2'b01, 3'b001, 32'h4BC66FAF, 32'hB8179AB7, 32'h43001299, 32'hC4858620, 5'b00001, "fma rand#42 op=1 rm=1");
        run_case(2'b01, 3'b000, 32'h80D72C13, 32'h382EAB39, 32'h00980425, 32'h80980670, 5'b00001, "fma rand#43 op=1 rm=0");
        run_case(2'b10, 3'b011, 32'h8026BBEE, 32'h3F71C7A2, 32'hBF800000, 32'hBF800000, 5'b00000, "fma rand#44 op=2 rm=3");
        run_case(2'b00, 3'b010, 32'hBF4094E0, 32'hC472C915, 32'h58545E23, 32'h58545E23, 5'b00001, "fma rand#45 op=0 rm=2");
        run_case(2'b11, 3'b000, 32'h3F3251B3, 32'h3D838781, 32'hBF800000, 32'h3F748C3A, 5'b00001, "fma rand#46 op=3 rm=0");
        run_case(2'b01, 3'b000, 32'hBE976BEA, 32'hBE37FFBD, 32'hBF800000, 32'h3F86CD57, 5'b00001, "fma rand#47 op=1 rm=0");
        run_case(2'b10, 3'b100, 32'hD804DB53, 32'h3F800000, 32'h00000000, 32'h5804DB53, 5'b00000, "fma rand#48 op=2 rm=4");
        run_case(2'b10, 3'b010, 32'h3A3F7CF9, 32'h7F800000, 32'hBF4AD047, 32'hFF800000, 5'b00000, "fma rand#49 op=2 rm=2");
        run_case(2'b01, 3'b100, 32'h895438B1, 32'h00000000, 32'hDEA7B4B5, 32'h5EA7B4B5, 5'b00000, "fma rand#50 op=1 rm=4");
        run_case(2'b11, 3'b010, 32'hD6813E60, 32'h00000000, 32'h00000000, 32'h80000000, 5'b00000, "fma rand#51 op=3 rm=2");
        run_case(2'b00, 3'b000, 32'hBF800000, 32'hBF800000, 32'hE7DB0870, 32'hE7DB0870, 5'b00001, "fma rand#52 op=0 rm=0");
        run_case(2'b00, 3'b000, 32'h3F800000, 32'h7F800000, 32'h7F800000, 32'h7F800000, 5'b00000, "fma rand#53 op=0 rm=0");
        run_case(2'b11, 3'b000, 32'h3A584490, 32'h7F800000, 32'hFF800000, 32'h7FC00000, 5'b10000, "fma rand#54 op=3 rm=0");
        run_case(2'b00, 3'b100, 32'hFF800000, 32'hBE9F5102, 32'h00239E62, 32'h7F800000, 5'b00000, "fma rand#55 op=0 rm=4");
        run_case(2'b11, 3'b010, 32'h00000000, 32'h3F6F5006, 32'h804D1AB3, 32'h80000000, 5'b00000, "fma rand#56 op=3 rm=2");
        run_case(2'b01, 3'b000, 32'h76D1F89F, 32'hBA1294D2, 32'hBA7FA2B0, 32'hF17073B5, 5'b00001, "fma rand#57 op=1 rm=0");
        run_case(2'b11, 3'b001, 32'hD8383FEC, 32'h5817646E, 32'h00000000, 32'h70D9EBF8, 5'b00001, "fma rand#58 op=3 rm=1");
        run_case(2'b00, 3'b100, 32'h7F800000, 32'hBEAFDA53, 32'h8097F3E6, 32'hFF800000, 5'b00000, "fma rand#59 op=0 rm=4");
        run_case(2'b00, 3'b000, 32'h40000000, 32'h40400000, 32'h3F800000, 32'h40E00000, 5'b00000, "fmadd(2,3,1)=7");
        run_case(2'b01, 3'b000, 32'h40000000, 32'h40400000, 32'h3F800000, 32'h40A00000, 5'b00000, "fmsub(2,3,1)=5");
        run_case(2'b10, 3'b000, 32'h40000000, 32'h40400000, 32'h3F800000, 32'hC0A00000, 5'b00000, "fnmsub(2,3,1)=-5");
        run_case(2'b11, 3'b000, 32'h40000000, 32'h40400000, 32'h3F800000, 32'hC0E00000, 5'b00000, "fnmadd(2,3,1)=-7");
        run_case(2'b00, 3'b000, 32'h7FC00000, 32'h3F800000, 32'h3F800000, 32'h7FC00000, 5'b00000, "fmadd(qNaN,1,1)->NaN no NV");
        run_case(2'b00, 3'b000, 32'h7F800001, 32'h3F800000, 32'h3F800000, 32'h7FC00000, 5'b10000, "fmadd(sNaN,1,1)->NaN NV");
        run_case(2'b00, 3'b000, 32'h00000000, 32'h7F800000, 32'h3F800000, 32'h7FC00000, 5'b10000, "fmadd(0,inf,1)->invalid");
        run_case(2'b00, 3'b000, 32'h7F800000, 32'h40000000, 32'hFF800000, 32'h7FC00000, 5'b10000, "fmadd(inf,2,-inf)->invalid");
        run_case(2'b00, 3'b000, 32'h7F800000, 32'h40000000, 32'h40400000, 32'h7F800000, 5'b00000, "fmadd(inf,2,3)->+inf");
        run_case(2'b00, 3'b000, 32'h60AD78EC, 32'h60AD78EC, 32'h3F800000, 32'h7F800000, 5'b00101, "fmadd huge*huge+tiny (product dominates)");
        run_case(2'b00, 3'b000, 32'h3F800000, 32'h3F800000, 32'h60AD78EC, 32'h60AD78EC, 5'b00001, "fmadd 1*1+huge (addend dominates)");
        run_case(2'b00, 3'b000, 32'h40400000, 32'h40800000, 32'hC1400000, 32'h00000000, 5'b00000, "fmadd(3,4,-12)=0 exact cancellation");
        run_case(2'b00, 3'b010, 32'h40400000, 32'h40800000, 32'hC1400000, 32'h80000000, 5'b00000, "fmadd(3,4,-12)=-0 (RDN)");

        if (total_fails == 0)
            $display("PASS  fmaddunit_unit (%0d checks)", total_checks);
        else
            $display("FAIL  fmaddunit_unit (%0d/%0d checks failed)", total_fails, total_checks);
        $finish;
    end
endmodule
