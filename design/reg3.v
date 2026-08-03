`default_nettype none

// EX/MEM pipeline register: latches the ALU/branch/CSR result and
// memory-access control signals for MEM/WB. `hold` freezes it during the
// MEM-stage load-latency interlock (docs/adr/0013's `mem_stall`).
module reg3 #(
    parameter XLEN = 32,       // docs/adr/0015-xlen-and-regcount-parameterization.md
    parameter NUM_REGS = 32
) (
    input clk,
    input rst,
    // docs/adr/0025-hpc-performance-csrs.md (Phase J3). Plain passthrough/
    // hold/reset, same shape as every other field here -- the call site
    // (riscvpipeline.v) pre-computes `valid_regde && !reg3_bubble` before
    // wiring it in, the same `_to_reg3` treatment `regWrite_to_reg3` etc.
    // already get, so this module itself needs no bubble-awareness of its
    // own. `instret_pulse = valid_regem && !mem_stall` (computed at the
    // call site, not here) is minstret's own increment condition.
    input valid_regde,
    input memtoReg_regde,
    input regWrite_regde,
    input fRegWrite_regde,  // docs/adr/0019-f-extension.md: writes FRegister.v, not Register.v
    input memRead_regde,
    input memWrite_regde,
    input [XLEN-1:0] ALUOut,
    input [XLEN-1:0] readData2_regde,
    input [$clog2(NUM_REGS)-1:0] write_to_Reg_regde,
    input jump_regde,
    input [XLEN-1:0] pc_plus4_regde,   // rd = PC+4 link value for jal, computed in EX
    input [2:0] funct3_regde,      // load/store access width+signedness, for DataMemory
    input hold,   // MEM-stage interlock (docs/adr/0013-mem-stage-retiming.md):
                  // freeze every field exactly as-is while a load sitting in
                  // *this* register's own output hasn't come back from
                  // DataMemoryBRAM yet. Same empty-branch idiom as reg2's
                  // `hold` (docs/adr/0009) -- highest priority, no field-
                  // assignment logic needed.

    output reg valid_regem,
    output reg memtoReg_regem,
    output reg regWrite_regem,
    output reg fRegWrite_regem,
    output reg memRead_regem,
    output reg memWrite_regem,
    output reg [XLEN-1:0] ALUOut_regem,
    output reg [XLEN-1:0] readData2_regem,
    output reg [$clog2(NUM_REGS)-1:0] write_to_Reg_regem,
    output reg jump_regem,
    output reg [XLEN-1:0] pc_plus4_regem,
    output reg [2:0] funct3_regem
);

always@(posedge clk)
begin
if(~rst)
    begin
    valid_regem <=0;
    memtoReg_regem <=0;
    regWrite_regem <=0;
    fRegWrite_regem <=0;
    memRead_regem <=0;
    memWrite_regem <=0;
    ALUOut_regem <=0;
    readData2_regem <=0;
    write_to_Reg_regem <=0;
    jump_regem <=0;
    pc_plus4_regem <=0;
    funct3_regem <=0;
    end
else if(hold)
    begin
    // Deliberately empty -- see the `hold` port comment above.
    end
else
    begin
    valid_regem <=valid_regde;
    memtoReg_regem <=memtoReg_regde;
    regWrite_regem <=regWrite_regde;
    fRegWrite_regem <=fRegWrite_regde;
    memRead_regem <=memRead_regde;
    memWrite_regem <=memWrite_regde;
    ALUOut_regem <=ALUOut;
    readData2_regem <=readData2_regde;
    write_to_Reg_regem <=write_to_Reg_regde;
    jump_regem <=jump_regde;
    pc_plus4_regem <=pc_plus4_regde;
    funct3_regem <=funct3_regde;
    end
end
endmodule

`default_nettype wire
