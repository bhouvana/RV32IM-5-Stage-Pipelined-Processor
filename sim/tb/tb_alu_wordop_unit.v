`include "ALU.v"

// Generation 2 (Phase M, docs/adr/0028-rv64-migration-phase-m.md). Standalone
// unit test for ALU.v's new `wordOp` input at XLEN=64: addw/subw/sllw/srlw/
// sraw/mulw must compute on the low 32 bits of A/B only and sign-extend the
// 32-bit result to 64 bits, independent of the full pipeline/ALUCtrl.v/
// riscvpipeline.v's own EX-stage classification.
module tb_alu_wordop_unit;
    reg [4:0] ALUCtl = 0;
    reg [63:0] A = 0, B = 0;
    reg wordOp = 0;
    wire [63:0] ALUOut;
    wire zero, branch_zero;

    ALU #(.XLEN(64)) dut(.ALUCtl(ALUCtl), .A(A), .B(B), .wordOp(wordOp),
                          .ALUOut(ALUOut), .zero(zero), .branch_zero(branch_zero));

    integer checks = 0;
    integer fails = 0;

    task check;
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

    initial begin
        wordOp = 1;

        // addw: 32-bit overflow boundary (0x7FFFFFFF+1 -> 0x80000000,
        // negative as a 32-bit result, must sign-extend, NOT match what a
        // full 64-bit add of the same operands would give).
        ALUCtl = `ALUCTL_ADD; A = 64'h000000007FFFFFFF; B = 64'h0000000000000001;
        #1 check(ALUOut, 64'hFFFFFFFF80000000, "addw: 0x7FFFFFFF+1 sign-extends to negative");

        // subw: 0-1 -> 0xFFFFFFFF (32-bit), sign-extends to all-1s.
        ALUCtl = `ALUCTL_SUB; A = 64'h0; B = 64'h1;
        #1 check(ALUOut, 64'hFFFFFFFFFFFFFFFF, "subw: 0-1 sign-extends to -1");

        // sllw: shift amount must be exactly B[4:0] (8), not B itself (40) --
        // if the full SHAMT_WIDTH were used instead, this would wrongly
        // shift by a different amount than a real 5-bit-shamt hardware
        // would.
        ALUCtl = `ALUCTL_SLL; A = 64'h1; B = 64'd40;  // B[4:0] = 8
        #1 check(ALUOut, 64'h0000000000000100, "sllw: shift amount is B[4:0]=8, not B=40");

        // srlw: logical (zero-fill) right shift of the low 32 bits only,
        // sign-extends the (positive, bit31=0) 32-bit result.
        ALUCtl = `ALUCTL_SRL; A = 64'h00000000FFFFFFFF; B = 64'd40;  // B[4:0] = 8
        #1 check(ALUOut, 64'h0000000000FFFFFF, "srlw: logical shift, zero-extends result");

        // sraw: arithmetic (sign-fill) right shift of the low 32 bits,
        // result's own bit31 stays 1 -- sign-extends to all-1s in the top.
        ALUCtl = `ALUCTL_SRA; A = 64'h0000000080000000; B = 64'd40;  // B[4:0] = 8
        #1 check(ALUOut, 64'hFFFFFFFFFF800000, "sraw: arithmetic shift, sign-extends result");

        // mulw: truncation, not just coincidental agreement with a full
        // 64-bit multiply -- 0x80000000*2 = 0x100000000 at full width, but
        // mulw must truncate to the low 32 bits (0) before sign-extending.
        ALUCtl = `ALUCTL_MUL; A = 64'h0000000080000000; B = 64'h0000000000000002;
        #1 check(ALUOut, 64'h0000000000000000, "mulw: truncates to low 32 bits before sign-extending");

        // wordOp=0 must be completely unaffected (regression: the non-"w"
        // ALUCtl arms' original full-width behavior).
        wordOp = 0;
        ALUCtl = `ALUCTL_ADD; A = 64'h000000007FFFFFFF; B = 64'h0000000000000001;
        #1 check(ALUOut, 64'h0000000080000000, "wordOp=0: plain add is full 64-bit, no truncation");

        if (fails == 0)
            $display("PASS  alu_wordop_unit (%0d checks)", checks);
        else
            $display("FAIL  alu_wordop_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
