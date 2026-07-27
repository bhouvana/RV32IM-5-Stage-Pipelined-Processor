`default_nettype none

`include "riscv_defs.vh"

module ALU (
    input [4:0] ALUCtl,
    input [31:0] A,B,
    output reg [31:0] ALUOut,
    output reg zero,
    output reg branch_zero
);

integer i;
integer count;
integer done;

// RV32M scratch (docs/adr/0006-rv32m.md). Widened to 64 bits *before*
// multiplying (not after) so the product is computed at full precision
// regardless of how a given tool self-determines `*`'s result width.
reg signed [63:0] mul_ss;  // signed x signed  (mul, mulh)
reg signed [63:0] mul_su;  // signed x unsigned (mulhsu)
reg        [63:0] mul_uu;  // unsigned x unsigned (mulhu)

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
    ALUOut = (A << B);//logical shift left
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
    ALUOut = (A >> B);//shift right logical
    `ALUCTL_SRA:
    // See docs/adr/0004-signed-arithmetic-casts.md -- >>> only sign-extends
    // when the operand's *type* is signed, which A/B are not by default.
    ALUOut = ($signed(A) >>> B);//shift right arithmetic
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
            for(i =0 ; i<31 ; i=i+1)
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
            mul_ss = $signed({{32{A[31]}}, A}) * $signed({{32{B[31]}}, B});
            ALUOut = mul_ss[63:32];
        end
    `ALUCTL_MULHSU:
        begin
            mul_su = $signed({{32{A[31]}}, A}) * $signed({32'b0, B});
            ALUOut = mul_su[63:32];
        end
    `ALUCTL_MULHU:
        begin
            mul_uu = {32'b0, A} * {32'b0, B};
            ALUOut = mul_uu[63:32];
        end

endcase
            zero = branch_zero;
end

    // ALU has two operands, executes a different operation based on ALUCtl.
    // `zero` (really "branch condition true") feeds the fetch-stage redirect mux.

endmodule

`default_nettype wire
