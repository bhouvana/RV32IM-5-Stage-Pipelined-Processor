`include "riscv_defs.vh"

module ALUCtrl (
    input [1:0] ALUOp,

    input funct7_c,    //funct7 = funct7[5] 6th bit of the 7 bit number funct7 taken from the instruction
    input [2:0] funct3_c,
    output reg [4:0] ALUCtl
);
wire [2:0] funct3   = funct3_c;
wire       funct7 = funct7_c;
wire [5:0] concat1;
wire [4:0] concat2;

assign concat2 = {ALUOp,funct3};
assign concat1 = {ALUOp,funct7,funct3};
always@(*)
begin
if(ALUOp == `ALUOP_LOAD_STORE)
    begin
        ALUCtl = `ALUCTL_ADD;
    end
else if(ALUOp == `ALUOP_RTYPE)
    begin
    case(concat1)
        6'b100000: // add
        ALUCtl = `ALUCTL_ADD;
        6'b101000: //subtract
        ALUCtl = `ALUCTL_SUB;
        6'b100001://shift left logical
        ALUCtl = `ALUCTL_SLL;
        6'b100010://set less than
        ALUCtl = `ALUCTL_SLT;
        6'b100011://set less than unsigned
        ALUCtl = `ALUCTL_SLTU;
        6'b100100://xor
        ALUCtl = `ALUCTL_XOR;
        6'b100101://srl
        ALUCtl = `ALUCTL_SRL;
        6'b101101://sra
        ALUCtl = `ALUCTL_SRA;
        6'b100110:
        ALUCtl = `ALUCTL_OR;
        6'b100111:
        ALUCtl = `ALUCTL_AND;
        6'b101111:
        ALUCtl = `ALUCTL_CTZ;//new instruction calculating number of trailing zeroes
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
            if(funct7 ==1)
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
