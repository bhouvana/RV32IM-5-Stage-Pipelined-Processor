`include "HazardNoForward.v"

// docs/adr/0027-formal-verification.md (Phase L). Formal harness for
// design/HazardNoForward.v. Three properties: (1) docs/adr/0007's own
// original invariant (stall === flush); (2) full semantic correctness
// (stall asserts iff a real gap=1/2 RAW hazard against a nonzero
// destination, AND branch_taken is not also resolving this cycle); (3) an
// explicit restatement of the real bug docs/adr/0016 found and fixed --
// branch_taken always wins, unconditionally, over any hazard this module
// would otherwise raise.
module hazard_noforward_formal (
    input [4:0] readReg1_fd,
    input [4:0] readReg2_fd,
    input regWrite_regde,
    input [4:0] write_to_Reg_regde,
    input regWrite_regem,
    input [4:0] write_to_Reg_regem,
    input branch_taken,
    output flush,
    output stall
);

    HazardNoForward #(.NUM_REGS(32)) dut (.*);

    wire hazard_ex = regWrite_regde && write_to_Reg_regde != 5'd0 &&
        (write_to_Reg_regde == readReg1_fd || write_to_Reg_regde == readReg2_fd);
    wire hazard_mem = regWrite_regem && write_to_Reg_regem != 5'd0 &&
        (write_to_Reg_regem == readReg1_fd || write_to_Reg_regem == readReg2_fd);

    always @(*) begin
        assert (stall === flush);
        assert (stall == ((hazard_ex | hazard_mem) & !branch_taken));

        // docs/adr/0016's own real bug, restated as a formal property:
        // branch_taken must never coexist with a stall from this module.
        if (branch_taken)
            assert (!stall);
    end

endmodule
