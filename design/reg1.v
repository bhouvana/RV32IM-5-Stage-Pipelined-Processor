`default_nettype none

// IF/ID pipeline register: latches the fetched instruction and its PC.
// Squashes to a real nop (not a literal 0, see the reset comment below) on
// a taken branch or unconditional jump/redirect; holds on a stall. Under
// PROFILE_6STAGE_SPLIT_FETCH (docs/adr/0018), this register's own squash
// window is extended one extra cycle (riscvpipeline.v's
// redirect_squash_extend_r) instead of reg1a squashing itself.
module reg1 #(
    parameter XLEN = 32   // docs/adr/0015-xlen-and-regcount-parameterization.md --
                            // applies to inst/inst_regfd too, same simplification
                            // ImmGen.v already made (RV32I's instruction word
                            // happens to be XLEN bits wide, coincidentally, only
                            // because both are 32 for this ISA).
)(
    input clk,
    input rst,
    input stall,
    input [XLEN-1:0] inst,
    input [XLEN-1:0] pc_o,
    input branch_regde,
    input zero,
    input jump,       // unconditional redirect (jal) resolved in EX, same squash as a taken branch
    // docs/adr/0021-branch-prediction.md (Phase E4). The branch predictor's
    // guess for THIS specific fetch (queried at the same address `inst`
    // itself was fetched from), latched alongside it with exactly the same
    // squash/hold/fresh-latch priority as inst/pc_o above -- never a
    // second, independent squash source (see reg1a.v's own header for why
    // that distinction matters). Always 0/don't-care under
    // PREDICTOR_STATIC -- riscvpipeline.v ties them off there, and folds
    // the branch/jump redirect condition entirely into `jump` above instead
    // of this module's own branch_regde/zero ports in that case too (see
    // riscvpipeline.v's own comment at the reg1 instantiation).
    input predict_taken,
    input [XLEN-1:0] predict_target,
    output reg [XLEN-1:0] inst_regfd,
    output reg [XLEN-1:0] pc_o_regfd,
    output reg predict_taken_regfd,
    output reg [XLEN-1:0] predict_target_regfd
);

always@(posedge clk)
begin
    if(~rst)
    begin
    // A nop (0x13), not a literal 0 -- opcode 0000000 is a real illegal-
    // instruction trap since docs/adr/0011 (see squash below, which already
    // knew this). Reset didn't get the same treatment: for the one cycle
    // between reset releasing and the first real fetch reaching inst_regfd,
    // Control.v would otherwise decode this register's raw reset value as
    // opcode 0000000 and spuriously trap, corrupting mcause/mepc before any
    // real instruction ever executes (docs/adr/0013's random-testing pass,
    // once it started generating CSR reads, was the first thing to ever
    // read those registers early enough to notice).
    inst_regfd <= 32'h00000013;
    pc_o_regfd <= 0;
    predict_taken_regfd <= 0;
    predict_target_regfd <= 0;
    end
    else
        begin
            if((branch_regde & zero) | jump)
            begin

                inst_regfd <= 32'h00000013;
                pc_o_regfd <= 0;
                predict_taken_regfd <= 0;
                predict_target_regfd <= 0;
            end
            else if(stall)
            begin
                inst_regfd <= inst_regfd;
                pc_o_regfd <= pc_o_regfd;
                predict_taken_regfd <= predict_taken_regfd;
                predict_target_regfd <= predict_target_regfd;
            end
            else
            begin
                inst_regfd <= inst;
                pc_o_regfd <= pc_o;
                predict_taken_regfd <= predict_taken;
                predict_target_regfd <= predict_target;
            end
    end
end

endmodule

`default_nettype wire
