`default_nettype none

// IF1/IF2 relay register (docs/adr/0018-variable-pipeline-depth.md,
// docs/ROADMAP.md Phase 6: "compare pipeline depths"). Only instantiated
// under PIPELINE_PROFILE == PROFILE_6STAGE_SPLIT_FETCH -- see
// riscvpipeline.v's generate/if selection, the same elaboration-time
// pattern docs/adr/0016 established for HAZARD_STRATEGY (the unselected
// branch isn't even instantiated, so PROFILE_5STAGE stays zero-cost).
//
// Carries only the PC, not an instruction -- InstructionMemory.v hasn't
// been read yet at this point in the pipe. Under the split-fetch profile,
// PC.v's output is registered here first; InstructionMemory.v then reads
// THIS register's output (one cycle later than PROFILE_5STAGE), and
// reg1.v (today's IF/ID register, unchanged) registers the resulting
// instruction one cycle after that. Net effect: one extra cycle of fetch
// latency between PC generation and instruction-memory access, decoupling
// the two -- the actual point of a split-fetch stage (e.g. groundwork for
// a future synchronous-read instruction memory, the same BRAM-retiming
// gap docs/adr/0013's Future Improvements already flagged for
// InstructionMemory.v specifically).
//
// Same freeze/squash semantics as reg1.v, applied to the PC alone: a taken
// branch or any unconditional redirect (jal/jalr/trap/mret, see
// riscvpipeline.v's `jump` port -- actually `unconditional_redirect`)
// squashes to PC 0 (matching reg1.v's squash value; there is no
// instruction field here to also reset to a nop), and `stall` (the same
// pc_stall wire PC.v and reg1.v already take) freezes in place.
module reg1a #(
    parameter XLEN = 32
)(
    input clk,
    input rst,
    input stall,
    input [XLEN-1:0] pc_o,
    input branch_regde,
    input zero,
    input jump,       // unconditional redirect (jal/jalr/trap/mret), same squash as a taken branch
    output reg [XLEN-1:0] pc_o_reg1a
);

always@(posedge clk)
begin
    if(~rst)
    begin
        pc_o_reg1a <= 0;
    end
    else
        begin
            if((branch_regde & zero) | jump)
            begin
                pc_o_reg1a <= 0;
            end
            else if(stall)
            begin
                pc_o_reg1a <= pc_o_reg1a;
            end
            else
            begin
                pc_o_reg1a <= pc_o;
            end
    end
end

endmodule

`default_nettype wire
