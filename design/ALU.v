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

endcase
            zero = branch_zero;
end

    // ALU has two operands, executes a different operation based on ALUCtl.
    // `zero` (really "branch condition true") feeds the fetch-stage redirect mux.

endmodule
