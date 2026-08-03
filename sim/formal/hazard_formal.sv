`include "Hazard.v"

// docs/adr/0027-formal-verification.md (Phase L). Formal harness for
// design/Hazard.v -- purely combinational. Two properties: (1) docs/adr/
// 0007's own original invariant (stall === flush, always); (2) the real
// semantic correctness property -- stall/flush assert iff the lookahead
// slot is a load (la_memRead) whose destination matches either source
// register being read.
module hazard_formal (
    input [4:0] readReg1_fd,
    input [4:0] readReg2_fd,
    input la_memRead,
    input [4:0] la_dest,
    output flush,
    output stall
);

    Hazard #(.NUM_REGS(32), .NUM_LOOKAHEAD(1)) dut (.*);

    always @(*) begin
        assert (stall === flush);

        // Note: unlike Forward.v, Hazard.v's own hazard_per_slot does NOT
        // exclude la_dest==0 -- a load-use hazard against x0 still stalls
        // in the real RTL (a harmless, if slightly imprecise, extra stall
        // cycle since writing x0 is architecturally a no-op anyway). The
        // property below matches the real RTL exactly, not an idealized
        // "should" behavior.
        if (la_memRead &&
            (la_dest == readReg1_fd || la_dest == readReg2_fd))
            assert (stall == 1'b1);
        else
            assert (stall == 1'b0);
    end

endmodule
