`include "riscv_defs.vh"

module ALUCtrl (
    input [1:0] ALUOp,

    input [6:0] funct7_c,  // full funct7 field (inst[31:25]) -- widened from a
                            // single bit (inst[30]) to make room for RV32M's
                            // funct7=0000001, see docs/adr/0006-rv32m.md
    input [2:0] funct3_c,
    output reg [4:0] ALUCtl
);
wire [2:0] funct3 = funct3_c;
wire [6:0] funct7 = funct7_c;
wire [4:0] concat2;

assign concat2 = {ALUOp,funct3};
always@(*)
begin
if(ALUOp == `ALUOP_LOAD_STORE)
    begin
        ALUCtl = `ALUCTL_ADD;
    end
else if(ALUOp == `ALUOP_RTYPE)
    begin
    case({funct7, funct3})
        {`FUNCT7_BASE, 3'b000}: ALUCtl = `ALUCTL_ADD;
        {`FUNCT7_ALT,  3'b000}: ALUCtl = `ALUCTL_SUB;
        {`FUNCT7_BASE, 3'b001}: ALUCtl = `ALUCTL_SLL;
        {`FUNCT7_BASE, 3'b010}: ALUCtl = `ALUCTL_SLT;
        {`FUNCT7_BASE, 3'b011}: ALUCtl = `ALUCTL_SLTU;
        {`FUNCT7_BASE, 3'b100}: ALUCtl = `ALUCTL_XOR;
        {`FUNCT7_BASE, 3'b101}: ALUCtl = `ALUCTL_SRL;
        {`FUNCT7_ALT,  3'b101}: ALUCtl = `ALUCTL_SRA;
        {`FUNCT7_BASE, 3'b110}: ALUCtl = `ALUCTL_OR;
        {`FUNCT7_BASE, 3'b111}: ALUCtl = `ALUCTL_AND;
        {`FUNCT7_ALT,  3'b111}: ALUCtl = `ALUCTL_CTZ;    //custom: number of trailing zeroes
        // RV32M (docs/adr/0006-rv32m.md)
        {`FUNCT7_MULDIV, 3'b000}: ALUCtl = `ALUCTL_MUL;
        {`FUNCT7_MULDIV, 3'b001}: ALUCtl = `ALUCTL_MULH;
        {`FUNCT7_MULDIV, 3'b010}: ALUCtl = `ALUCTL_MULHSU;
        {`FUNCT7_MULDIV, 3'b011}: ALUCtl = `ALUCTL_MULHU;
        {`FUNCT7_MULDIV, 3'b100}: ALUCtl = `ALUCTL_DIV;
        {`FUNCT7_MULDIV, 3'b101}: ALUCtl = `ALUCTL_DIVU;
        {`FUNCT7_MULDIV, 3'b110}: ALUCtl = `ALUCTL_REM;
        {`FUNCT7_MULDIV, 3'b111}: ALUCtl = `ALUCTL_REMU;
        default:
        ALUCtl = `ALUCTL_ILLEGAL;//jaathre
    endcase
    end


else if(ALUOp == `ALUOP_BRANCH)
    begin
    case(concat2)
        5'b01000: //beq
        ALUCtl = `ALUCTL_BEQ;
        5'b01001: //bne
        ALUCtl = `ALUCTL_BNE;
        5'b01010: //blt
        ALUCtl = `ALUCTL_BLT;
        5'b01011: //bge
        ALUCtl = `ALUCTL_BGE;
        5'b01100: //ble (custom)
        ALUCtl = `ALUCTL_BLE;
        5'b01101: // bgt (custom)
        ALUCtl = `ALUCTL_BGT;
        5'b01110: //bltu
        ALUCtl = `ALUCTL_BLTU;
        5'b01111: //bgeu
        ALUCtl = `ALUCTL_BGEU;
        default:
        ALUCtl = `ALUCTL_ILLEGAL;//jaathre
    endcase
    end
else if(ALUOp == `ALUOP_ITYPE)
    begin
    case(concat2)
        5'b11000: // add imm
        ALUCtl = `ALUCTL_ADD;
        5'b11001://shift left logical imm
        ALUCtl = `ALUCTL_SLL;
        5'b11010://set less than imm
        ALUCtl = `ALUCTL_SLT;
        5'b11011://set less than unsigned imm
        ALUCtl = `ALUCTL_SLTU;
        5'b11100://xor imm
        ALUCtl = `ALUCTL_XOR;
        5'b11101://srl imm and sra imm
        begin
            if(funct7 == `FUNCT7_ALT)
            ALUCtl = `ALUCTL_SRA;
            else
            ALUCtl = `ALUCTL_SRL;
        end
        5'b11110:
        ALUCtl = `ALUCTL_OR;//OR imm
        5'b11111:
        ALUCtl = `ALUCTL_AND;//AND imm
        default:
        ALUCtl = `ALUCTL_ILLEGAL;//jaathre
    endcase
    end

end
endmodule
