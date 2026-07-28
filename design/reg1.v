`default_nettype none

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
    output reg [XLEN-1:0] inst_regfd,
    output reg [XLEN-1:0] pc_o_regfd
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
    end
    else
        begin
            if((branch_regde & zero) | jump)
            begin
                
                inst_regfd <= 32'h00000013;
                pc_o_regfd <= 0;
            end
            else if(stall)
            begin
                inst_regfd <= inst_regfd;
                pc_o_regfd <= pc_o_regfd;
            end
            else
            begin
                inst_regfd <= inst;
                pc_o_regfd <= pc_o;
            end
    end
end

endmodule

`default_nettype wire
