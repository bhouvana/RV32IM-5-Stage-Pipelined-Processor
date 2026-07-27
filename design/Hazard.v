`default_nettype none

module Hazard (

    input [4:0] readReg1_fd,
    input [4:0] readReg2_fd,
    input [4:0] write_to_Reg_regde,
    input memRead_regde,
    output flush,
    output stall
);
assign flush = ( memRead_regde && ((write_to_Reg_regde ==readReg1_fd) || (write_to_Reg_regde == readReg2_fd))) ? 1'b1 : 1'b0;
assign stall = flush;

// Compiled in only with -DASSERT_ON (see sim/run_tests.sh). stall/flush are
// assigned identically above by construction; this makes that an explicitly
// checked invariant instead of something a future edit could quietly break
// (e.g. if load-use handling ever needs to diverge stall from flush).
`ifdef ASSERT_ON
always @(*) begin
    if (stall !== flush)
        begin $display("ASSERTION FAILED @t=%0t: Hazard.v stall(%b) != flush(%b), expected equal", $time, stall, flush); $finish; end
end
`endif

endmodule

//"C:\Users\samar\Downloads\TEST_INSTRUCTIONS_2.txt"

`default_nettype wire
