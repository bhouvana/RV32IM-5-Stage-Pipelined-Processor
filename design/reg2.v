`default_nettype none

// ID/EX pipeline register: latches every control signal and operand
// Control.v/ImmGen.v/Register.v produced in ID for EX/MEM/WB to consume
// downstream. Squashes to nop-equivalent control fields on a redirect or a
// load-use bubble (docs/adr/0009's convention -- bubble the *control*
// signals, not the data); `hold` freezes it during a multi-cycle EX
// operation or the MEM-stage load-latency interlock (docs/adr/0009,
// docs/adr/0013).
//
// Field-assignment macros factor out what was previously ~90 lines of
// near-identical repetition across the four arms below (docs/ARCHITECTURE.md
// sec 12 flagged this as the most duplicative code in the repository).
// Verilog-2001 has no struct/typedef to reach for here, so this uses plain
// `` `define`` text macros -- a portable, toolchain-agnostic way to get the
// same "assign this named group of fields" effect.
`define ZERO_CONTROL_FIELDS \
    branch_regde <= 0; \
    memRead_regde <= 0; \
    memtoReg_regde <= 0; \
    memWrite_regde <= 0; \
    ALUSrc_regde <= 0; \
    regWrite_regde <= 0; \
    ALUOp_regde <= 0; \
    write_to_Reg_regde <= 0; \
    jump_regde <= 0; \
    jalr_regde <= 0; \
    lui_regde <= 0; \
    auipc_regde <= 0; \
    isCsr_regde <= 0; \
    isEcall_regde <= 0; \
    isEbreak_regde <= 0; \
    isMret_regde <= 0; \
    illegalOpcode_regde <= 0;

`define ZERO_DECODE_CONTEXT \
    pc_o_regde <= 0; \
    readData1_regde <= 0; \
    readData2_regde <= 0; \
    imm_regde <= 0; \
    funct7_regde <= 0; \
    funct3_regde <= 0; \
    readReg1_regde <= 0; \
    readReg2_regde <= 0;

`define PASS_DECODE_CONTEXT \
    pc_o_regde <= pc_o_regfd; \
    readData1_regde <= readData1; \
    readData2_regde <= readData2; \
    imm_regde <= imm; \
    funct7_regde <= funct7; \
    funct3_regde <= funct3; \
    readReg1_regde <= readReg1; \
    readReg2_regde <= readReg2;

module reg2 #(
    parameter XLEN = 32,       // docs/adr/0015-xlen-and-regcount-parameterization.md
    parameter NUM_REGS = 32
) (
    input clk,
    input rst,
    input branch,
    input memRead,
    input memtoReg,
    input memWrite,
    input ALUSrc,
    input regWrite,
    input [$clog2(NUM_REGS)-1:0] writeReg,
    input [6:0] funct7,
    input [2:0] funct3,
    input [1:0] ALUOp,
    input [XLEN-1:0] pc_o_regfd,
    input [XLEN-1:0] readData1,
    input [XLEN-1:0] readData2,
    input [XLEN-1:0] imm,
    input [XLEN-1:0] inst_regfd,
    input flush,
    input branch_taken,
    input hold,   // multi-cycle divide interlock (docs/adr/0009): freeze every
                  // field exactly as-is while a div/rem's result isn't ready
                  // yet. Distinct from `flush`: flush *bubbles* (zeros
                  // control, keeps decode context); hold changes nothing at
                  // all, because the div/rem instruction itself must stay
                  // put in EX until the divider finishes with it.
    input [$clog2(NUM_REGS)-1:0] readReg1,
    input [$clog2(NUM_REGS)-1:0] readReg2,
    input jump,
    input jalr,
    input lui,
    input auipc,
    input isCsr,
    input isEcall,
    input isEbreak,
    input isMret,
    input illegalOpcode,

    output reg branch_regde,
    output reg memRead_regde,
    output reg memtoReg_regde,
    output reg memWrite_regde,
    output reg ALUSrc_regde,
    output reg regWrite_regde,
    output reg [1:0] ALUOp_regde,
    output reg [$clog2(NUM_REGS)-1:0] write_to_Reg_regde,
    output reg [XLEN-1:0] pc_o_regde,
    output reg [XLEN-1:0] readData1_regde,
    output reg [XLEN-1:0] readData2_regde,
    output reg [XLEN-1:0] imm_regde,
    output reg [XLEN-1:0] inst_regde,
    output reg [6:0] funct7_regde,
    output reg [2:0] funct3_regde,
    output reg [$clog2(NUM_REGS)-1:0] readReg1_regde,
    output reg [$clog2(NUM_REGS)-1:0] readReg2_regde,
    output reg jump_regde,
    output reg jalr_regde,
    output reg lui_regde,
    output reg auipc_regde,
    output reg isCsr_regde,
    output reg isEcall_regde,
    output reg isEbreak_regde,
    output reg isMret_regde,
    output reg illegalOpcode_regde

);

always@(posedge clk)
begin
    if(~rst)
    begin
        // Power-on reset: every field, including decode context, starts at 0.
        `ZERO_CONTROL_FIELDS
        `ZERO_DECODE_CONTEXT
        inst_regde <= 0;
    end

    else if(hold)
    begin
        // Deliberately empty: assigning nothing to a `reg` in one branch of
        // a clocked if-else chain means it keeps its current value -- an
        // enable-gated flip-flop, synthesizable as-is, not a fall-through
        // bug. Checked before branch_taken/flush on the (today, unreachable
        // in practice) grounds that a held div/rem instruction can't also
        // be a branch/load -- see the `hold` port comment above.
    end

    else if(branch_taken)
    begin
        // Taken branch/jal resolved in EX: squash to a bubble. Decode
        // context is discarded (there's no real instruction here anymore),
        // same as reset, except inst_regde becomes an explicit nop rather
        // than 0 -- downstream stages (e.g. Control) decode 0 as a
        // (harmless) R-type op, but an explicit nop is clearer to read in
        // a trace/waveform and matches reg1.v's own squash value.
        `ZERO_CONTROL_FIELDS
        `ZERO_DECODE_CONTEXT
        inst_regde <= 32'h00000013;
    end

    else if(flush)
    begin
        // Load-use stall bubble: control fields squash (this cycle does
        // nothing architecturally), but decode context passes through --
        // unlike branch_taken, there's a real (stalled) instruction sitting
        // in IF/ID that will re-enter next cycle once the stall clears.
        `ZERO_CONTROL_FIELDS
        `PASS_DECODE_CONTEXT
        inst_regde <= inst_regfd;
    end

    else
    begin
        // Normal cycle: control fields take their real decoded values;
        // decode context passes straight through same as the flush arm.
        branch_regde <= branch;
        memRead_regde <= memRead;
        memtoReg_regde <= memtoReg;
        memWrite_regde <= memWrite;
        ALUSrc_regde <= ALUSrc;
        regWrite_regde <= regWrite;
        ALUOp_regde <= ALUOp;
        write_to_Reg_regde <= writeReg;
        jump_regde <= jump;
        jalr_regde <= jalr;
        lui_regde <= lui;
        auipc_regde <= auipc;
        isCsr_regde <= isCsr;
        isEcall_regde <= isEcall;
        isEbreak_regde <= isEbreak;
        isMret_regde <= isMret;
        illegalOpcode_regde <= illegalOpcode;
        `PASS_DECODE_CONTEXT
        inst_regde <= inst_regfd;
    end
end

`undef ZERO_CONTROL_FIELDS
`undef ZERO_DECODE_CONTEXT
`undef PASS_DECODE_CONTEXT

endmodule

`default_nettype wire
