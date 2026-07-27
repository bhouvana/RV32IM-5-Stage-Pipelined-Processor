`include "riscv_defs.vh"

module Control (
    input [6:0] opcode,
    //
    input [6:0] funt7,   // full funct7 field (inst[31:25]) -- was 1 bit (inst[30]
                          // only), just enough to tell add from sub. RV32M needs
                          // funct7=0000001 distinguished from add/sub's 0/0100000,
                          // which the single-bit version couldn't represent.
    input [2:0] funt3,
    //
    output reg branch,
    output reg memRead,
    output reg memtoReg,
    output reg [1:0] ALUOp,
    output reg memWrite,
    output reg ALUSrc,
    output reg regWrite,
    output reg [2:0] funct3,
    output reg [6:0] funct7,
    output reg jump,   // unconditional control transfer (jal/jalr); target computed in EX, link = PC+4
    output reg jalr,   // target = rs1+imm (vs. jal's PC+imm) -- see riscvpipeline.v's target-address mux
    output reg lui,    // ALU A operand forced to 0 (result = imm)
    output reg auipc   // ALU A operand forced to PC (result = PC+imm)
    );

always@(*)begin

    branch    = 0;
    memRead   = 0;
    memtoReg  = 0;
    ALUOp     = `ALUOP_LOAD_STORE;
    memWrite  = 0;
    ALUSrc    = 0;
    regWrite  = 0;
    jump      = 0;
    jalr      = 0;
    lui       = 0;
    auipc     = 0;


case(opcode)
    `OPCODE_CUSTOM:
    begin// the new instruction that u people asked for

        ALUOp =`ALUOP_RTYPE;
        regWrite =1;

    end

    `OPCODE_LOAD:
    begin//load inst

        memRead =1;
        memtoReg =1;
        ALUSrc =1;
        regWrite =1;

    end
    `OPCODE_STORE://store inst
    begin
        memWrite =1;
        ALUSrc =1;

    end

    `OPCODE_I://immediate inst
    begin
        ALUOp =`ALUOP_ITYPE;
        ALUSrc =1;
        regWrite =1;

    end

    `OPCODE_R://add and sub R type inst
    begin
        ALUOp =`ALUOP_RTYPE;
        regWrite =1;

    end

    `OPCODE_BRANCH:
    begin
        branch =1;
        ALUOp =`ALUOP_BRANCH;

    end

    `OPCODE_JAL://jump and link (jal): target = PC+imm, link = PC+4
    begin
        ALUSrc =0;   // ALU result is unused for jal (target/link computed on dedicated adders)
        regWrite =1;
        jump = 1;

    end

    `OPCODE_JALR://jump and link register (jalr): target = rs1+imm, link = PC+4
    begin
        ALUSrc =0;
        regWrite =1;
        jump = 1;
        jalr = 1;

    end

    `OPCODE_LUI://load upper immediate (lui): rd = imm (ALU computes 0+imm)
    begin
        ALUOp = `ALUOP_LOAD_STORE;  // ALUCtl=ADD
        ALUSrc =1;
        regWrite =1;
        lui = 1;

    end

    `OPCODE_AUIPC://add upper immediate to pc (auipc): rd = PC+imm (ALU computes PC+imm)
    begin
        ALUOp = `ALUOP_LOAD_STORE;  // ALUCtl=ADD
        ALUSrc =1;
        regWrite =1;
        auipc = 1;

    end

    default:
    begin

    branch    = 0;
    memRead   = 0;
    memtoReg  = 0;
    ALUOp     = `ALUOP_LOAD_STORE;
    memWrite  = 0;
    ALUSrc    = 0;
    regWrite  = 0;
    jump      = 0;
    jalr      = 0;
    lui       = 0;
    auipc     = 0;

    end
endcase

 funct3 = funt3;
 funct7 = funt7;


end
endmodule
