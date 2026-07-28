`default_nettype none

// MEM/WB pipeline register: latches the final writeback value and its
// destination register. `hold` freezes it during the MEM-stage
// load-latency interlock (docs/adr/0013's `mem_stall`) -- unlike reg3,
// this register is also the sole source of MEM/WB forwarding, so it must
// never be *bubbled* by a stall that doesn't concern its own occupant (see
// docs/adr/0013's Lessons: bubbling reg4 the same way reg3 is bubbled
// evicts a still-needed forwardable result one cycle early).
module reg4 #(
    parameter XLEN = 32,       // docs/adr/0015-xlen-and-regcount-parameterization.md
    parameter NUM_REGS = 32
) (
    input clk,
    input rst,
    input memtoReg_regem,
    input regWrite_regem,
    input [XLEN-1:0] readData,
    input [XLEN-1:0] ALUOut_regem,
    input [$clog2(NUM_REGS)-1:0] write_to_Reg_regem,
    input jump_regem,
    input [XLEN-1:0] pc_plus4_regem,
    input hold,   // MEM-stage interlock (docs/adr/0013-mem-stage-retiming.md):
                  // freeze every field exactly as-is while a load sitting in
                  // reg3 (this register's own source) hasn't come back from
                  // DataMemoryBRAM yet. Same empty-branch idiom as reg2/reg3's
                  // `hold` -- NOT a bubble: whatever reg4 is currently holding
                  // (e.g. an instruction still within its MEM/WB forwarding
                  // window) must stay visible to Forward.v for exactly as long
                  // as reg2/reg3 are also held, or a completely unrelated
                  // instruction waiting behind the load can lose a forwarding
                  // match it would otherwise have had (see the ADR).
    output reg memtoReg_regwb,
    output reg regWrite_regwb,
    output reg [XLEN-1:0] readData_regwb,
    output reg [XLEN-1:0] ALUOut_regwb,
    output reg [$clog2(NUM_REGS)-1:0] write_to_Reg_regwb,
    output reg jump_regwb,
    output reg [XLEN-1:0] pc_plus4_regwb
);

always@(posedge clk)
begin
    if(~rst)
    begin
    memtoReg_regwb <= 0;
    regWrite_regwb <= 0;
    readData_regwb <= 0;
    ALUOut_regwb <= 0;
    write_to_Reg_regwb <=0;
    jump_regwb <= 0;
    pc_plus4_regwb <= 0;

    end
    else if(hold)
    begin
    // Deliberately empty -- see the `hold` port comment above.
    end
    else
    begin
    memtoReg_regwb <= memtoReg_regem;
    regWrite_regwb <= regWrite_regem;
    readData_regwb <= readData;
    ALUOut_regwb <= ALUOut_regem;
    write_to_Reg_regwb <= write_to_Reg_regem;
    jump_regwb <= jump_regem;
    pc_plus4_regwb <= pc_plus4_regem;
    end
end
endmodule

`default_nettype wire
