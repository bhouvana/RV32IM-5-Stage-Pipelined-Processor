`include "Forward.v"

// docs/adr/0027-formal-verification.md (Phase L). Formal harness for
// design/Forward.v -- purely combinational, no state at all, the easiest
// possible BMC target (k=1 suffices; `mode prove` still used for
// consistency). Two properties: (1) docs/adr/0007's own original
// invariant (forwardA/forwardB never select an out-of-range source);
// (2) the real semantic correctness property that invariant was only ever
// a proxy for -- forwardA/forwardB select exactly the NEAREST valid
// source whose destination matches (higher index = nearer producer, per
// Forward.v's own header comment), and select "no forward" (0) whenever
// no source matches.
module forward_formal (
    input [4:0] readReg1_regde,
    input [4:0] readReg2_regde,
    input [1:0] fwd_valid,
    input [9:0] fwd_dest,
    output [1:0] forwardA,
    output [1:0] forwardB
);

    Forward #(.NUM_REGS(32), .NUM_FWD_SRC(2)) dut (.*);

    wire [4:0] dest0 = fwd_dest[4:0];
    wire [4:0] dest1 = fwd_dest[9:5];

    // docs/adr/0007's own original invariant.
    always @(*) begin
        assert (forwardA <= 2);
        assert (forwardB <= 2);
    end

    // Real selection-correctness property: source 1 (nearer, EX/MEM) wins
    // over source 0 (farther, MEM/WB) whenever both match, matching
    // Forward.v's own "nearer source overwrites a farther match" priority.
    always @(*) begin
        if (fwd_valid[1] && dest1 != 5'd0 && dest1 == readReg1_regde)
            assert (forwardA == 2'd2);
        else if (fwd_valid[0] && dest0 != 5'd0 && dest0 == readReg1_regde)
            assert (forwardA == 2'd1);
        else
            assert (forwardA == 2'd0);

        if (fwd_valid[1] && dest1 != 5'd0 && dest1 == readReg2_regde)
            assert (forwardB == 2'd2);
        else if (fwd_valid[0] && dest0 != 5'd0 && dest0 == readReg2_regde)
            assert (forwardB == 2'd1);
        else
            assert (forwardB == 2'd0);
    end

endmodule
