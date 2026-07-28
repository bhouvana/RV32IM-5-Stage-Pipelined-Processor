`default_nettype none

`include "riscv_defs.vh"

// Main decoder: opcode (+funct3/funct7 pass-through, +the CSR/SYSTEM
// funct12 field) -> every control signal the rest of the pipeline
// conditions on. One `case` arm per opcode; an opcode with no arm here
// falls to `default`, asserting illegalOpcode -- a real trap
// (docs/adr/0011), not a silent no-op.
module Control (
    input [6:0] opcode,
    //
    input [6:0] funt7,   // full funct7 field (inst[31:25]) -- was 1 bit (inst[30]
                          // only), just enough to tell add from sub. RV32M needs
                          // funct7=0000001 distinguished from add/sub's 0/0100000,
                          // which the single-bit version couldn't represent.
    input [2:0] funt3,
    input [11:0] csr_imm12,  // inst[31:20]: a CSR address for real csrrX ops,
                              // or the funct12 that distinguishes ecall/ebreak/mret
                              // when opcode=SYSTEM and funt3=000 (docs/adr/0011)
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
    output reg auipc,  // ALU A operand forced to PC (result = PC+imm)
    output reg isCsr,      // genuine csrrw/csrrs/csrrc(+i variants) -- rd gets the CSR's old value
    output reg isEcall,
    output reg isEbreak,
    output reg isMret,
    output reg illegalOpcode  // opcode itself unrecognized -- see riscvpipeline.v for the
                               // other exception source (ALUCtl==ILLEGAL, a recognized
                               // opcode with an unrecognized funct7/funct3)
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
    isCsr     = 0;
    isEcall   = 0;
    isEbreak  = 0;
    isMret    = 0;
    illegalOpcode = 0;


case(opcode)
    `OPCODE_CUSTOM:
    begin// custom R-type opcode (currently just ctz, see ALUCtrl.v's FUNCT7_ALT/111 arm)

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

    `OPCODE_SYSTEM:
    begin
        if (funt3 == `CSR_F3_NONE)
        begin
            // Not a csrrX read/write at all -- inst[31:20] (csr_imm12 here)
            // picks which of the three funct3=000 instructions this is.
            // Anything else in this position is a reserved/unallocated
            // SYSTEM encoding -- illegalOpcode below, same exception
            // riscvpipeline.v raises for any other unrecognized instruction.
            case (csr_imm12)
                `CSR_IMM12_ECALL:  isEcall  = 1;
                `CSR_IMM12_EBREAK: isEbreak = 1;
                `CSR_IMM12_MRET:   isMret   = 1;
                default: illegalOpcode = 1;  // SYSTEM/funct3=0 but not ecall/ebreak/mret
            endcase
        end
        else
        begin
            isCsr = 1;
            regWrite = 1;  // rd <- CSR's old value (see riscvpipeline.v's ex_result override)
        end
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
    illegalOpcode = 1;

    end
endcase

 funct3 = funt3;
 funct7 = funt7;


end
endmodule

`default_nettype wire
