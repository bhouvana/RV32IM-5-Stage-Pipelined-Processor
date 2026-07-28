`default_nettype none

`include "riscv_defs.vh"

module ALU #(
    parameter XLEN = 32   // docs/adr/0015-xlen-and-regcount-parameterization.md
)(
    input [4:0] ALUCtl,
    input [XLEN-1:0] A,B,
    output reg [XLEN-1:0] ALUOut,
    output reg zero,
    output reg branch_zero
);

// Register-register shift amounts (sll/srl/sra) use only the low
// $clog2(XLEN) bits of B, per spec -- see the SLL case below.
localparam SHAMT_WIDTH = $clog2(XLEN);

integer i;
integer count;
integer done;

// RV32M scratch (docs/adr/0006-rv32m.md). Widened to 2*XLEN bits *before*
// multiplying (not after) so the product is computed at full precision
// regardless of how a given tool self-determines `*`'s result width.
reg signed [2*XLEN-1:0] mul_ss;  // signed x signed  (mul, mulh)
reg signed [2*XLEN-1:0] mul_su;  // signed x unsigned (mulhsu)
reg        [2*XLEN-1:0] mul_uu;  // unsigned x unsigned (mulhu)

always@(*)
begin
    ALUOut = 0;
    branch_zero =0;
case(ALUCtl)
    `ALUCTL_ADD:
    ALUOut = A + B;//simply adding
    `ALUCTL_SUB:
    ALUOut = A - B;//just subtracting
    `ALUCTL_SLL:
    // Per spec, register-register shifts only use the low $clog2(XLEN) bits
    // of rs2 as the shift amount -- rs2 holds a full XLEN-bit value, and B
    // here is that whole register for R-type sll/srl/sra (I-type
    // slli/srli/srai are unaffected: ImmGen.v already encodes their shamt as
    // a 5-bit zero-extended immediate, so B is already <=31 by construction
    // on that path). Without
    // masking, `A << B`/`A >> B` treat B as the *literal* shift count, and
    // Verilog shifts by >=32 discard every bit -- e.g. `sll rd,rs1,rs2` with
    // rs2 holding any value >=32 (utterly ordinary, rs2 is just a register)
    // silently produced 0 instead of a real shift. Found by constrained-
    // random testing (docs/ROADMAP.md V-4) hitting `srl x5,x25,x25`, not by
    // any directed test -- every hand-written shift test happened to use a
    // shift-amount register already holding a small value.
    ALUOut = (A << B[SHAMT_WIDTH-1:0]);//logical shift left
    `ALUCTL_SLT:
    // A/B are plain (unsigned) ports -- $signed() is required here, the same
    // way it is for SRA below, or this "signed" comparison would silently
    // run unsigned (e.g. slt with A=-1 would wrongly read as A > any
    // positive B). See docs/adr/0004-signed-arithmetic-casts.md.
    ALUOut = ($signed(A) < $signed(B)) ? 1 :0;//set less than
    `ALUCTL_SLTU:
    ALUOut = ($unsigned(A) < $unsigned(B)) ? 1 : 0;//set less than unsigned
    `ALUCTL_XOR:
    ALUOut = A ^ B;//xor
    `ALUCTL_SRL:
    ALUOut = (A >> B[SHAMT_WIDTH-1:0]);//shift right logical -- see SLL's comment on the shift-amount width
    `ALUCTL_SRA:
    // See docs/adr/0004-signed-arithmetic-casts.md -- >>> only sign-extends
    // when the operand's *type* is signed, which A/B are not by default.
    // See SLL's comment above on the shift-amount width.
    ALUOut = ($signed(A) >>> B[SHAMT_WIDTH-1:0]);//shift right arithmetic
    `ALUCTL_OR:
    ALUOut = ( A | B ) ;//OR
    `ALUCTL_AND:
    ALUOut = ( A & B );//AND
    `ALUCTL_BEQ:
        begin
            branch_zero = ( A == B ) ? 1 : 0;
            ALUOut = A & B;// beq
        end
    `ALUCTL_BNE:
        begin
            branch_zero = ( A != B ) ? 1 : 0;
            ALUOut = A & B;//bne
        end
    `ALUCTL_BLT:
        begin
            branch_zero = ( $signed(A) < $signed(B) ) ? 1 : 0;
            ALUOut = A & B;//blt (signed, per RV32I)
        end
    `ALUCTL_BGE:
        begin
            branch_zero = ( $signed(A) >= $signed(B) ) ? 1 : 0;
            ALUOut = A & B;//bge (signed, per RV32I)
        end
    `ALUCTL_BLE:
        begin
            branch_zero = ( $signed(A) <= $signed(B) ) ? 1 : 0;
            ALUOut = A & B;//ble (custom; signed, consistent with blt/bge)
        end
    `ALUCTL_BGT:
        begin
            branch_zero = ( $signed(A) > $signed(B) ) ? 1 : 0;
            ALUOut = A & B;//bgt (custom; signed, consistent with blt/bge)
        end
    `ALUCTL_BLTU:
        begin
            branch_zero = ( $unsigned(A) < $unsigned(B) ) ? 1 : 0;
            ALUOut = A & B;//bltu
        end
    `ALUCTL_BGEU:
        begin
            branch_zero = ( $unsigned(A) >= $unsigned(B) ) ? 1 : 0;
            ALUOut = A & B;//bgeu
        end
    `ALUCTL_CTZ:
        begin

            count = 0;
            done =0;
            for(i =0 ; i<XLEN-1 ; i=i+1)
            begin
                if(A[i] == 0 && done ==0)
                    count = count + 1;
                else
                done =1;
            end
            ALUOut = count;

        end

    // RV32M multiply -- single-cycle is a reasonable simplification for
    // multiply (real FPGA/ASIC flows commonly do support single- or
    // few-cycle pipelined multipliers). Division is NOT single-cycle-
    // friendly in real hardware and is handled by the dedicated multi-cycle
    // Divider.v unit + pipeline interlock in riscvpipeline.v instead --
    // ALUCtl never actually reaches this case block for div/rem (see
    // riscvpipeline.v's isDivRem), so there is deliberately no
    // `ALUCTL_DIV`/`ALUCTL_DIVU`/`ALUCTL_REM`/`ALUCTL_REMU` case here. See
    // docs/adr/0009-multicycle-divider.md.
    `ALUCTL_MUL:
        ALUOut = A * B;  // low 32 bits of the true product -- correct
                          // regardless of signedness, so no cast needed
    `ALUCTL_MULH:
        begin
            mul_ss = $signed({{XLEN{A[XLEN-1]}}, A}) * $signed({{XLEN{B[XLEN-1]}}, B});
            ALUOut = mul_ss[2*XLEN-1:XLEN];
        end
    `ALUCTL_MULHSU:
        begin
            mul_su = $signed({{XLEN{A[XLEN-1]}}, A}) * $signed({{XLEN{1'b0}}, B});
            ALUOut = mul_su[2*XLEN-1:XLEN];
        end
    `ALUCTL_MULHU:
        begin
            mul_uu = {{XLEN{1'b0}}, A} * {{XLEN{1'b0}}, B};
            ALUOut = mul_uu[2*XLEN-1:XLEN];
        end

endcase
            zero = branch_zero;
end

    // ALU has two operands, executes a different operation based on ALUCtl.
    // `zero` (really "branch condition true") feeds the fetch-stage redirect mux.

endmodule

`default_nettype wire
