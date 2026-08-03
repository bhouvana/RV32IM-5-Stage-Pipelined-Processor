`include "Register.v"

// docs/adr/0027-formal-verification.md (Phase L). Formal harness for
// design/Register.v -- a real BMC proof target (32-flop array, no
// submodules, tiny combinational read/write logic). Two properties:
// (1) x0 always reads 0 (docs/adr/0007's own original invariant,
// unbounded now via k-induction, not just "checked on whatever cycles
// simulation happened to reach"); (2) the write-first bypass
// (docs/adr/0002-register-file-write-first-bypass.md) returns exactly
// the write data on a same-cycle write/read of the same nonzero
// register, not the stale stored value.
module register_formal (
    input clk,
    input rst,
    input regWrite,
    input [4:0] readReg1,
    input [4:0] readReg2,
    input [4:0] writeReg,
    input [31:0] writeData,
    output [31:0] readData1,
    output [31:0] readData2
);

    Register #(.XLEN(32), .NUM_REGS(32), .SP_INIT(32'd128)) dut (.*);

    // `rst` here is active-LOW (Register.v's own convention, mirroring
    // riscvpipeline.v's `start`) -- `reset_done` tracks "a real reset has
    // happened at least once," the standard formal-harness way to bound
    // an otherwise-unconstrained initial register state, matching how a
    // real reset pulse is always assumed at boot.
    reg reset_done;
    initial reset_done = 1'b0;
    always @(posedge clk) begin
        if (~rst) reset_done <= 1'b1;
    end

    // x0's "hardwired to 0" invariant is checked at the module's own
    // architecturally-visible read ports (readData1/readData2 below), not
    // via a direct `dut.regs[0]` hierarchical peek -- Yosys's read_verilog
    // can't resolve that kind of cross-scope dot-reference the way
    // iverilog's simulator can (confirmed by running: it silently becomes
    // an implicitly-declared, permanently-undefined stand-in signal,
    // producing a spurious counterexample unrelated to any real RTL bug).
    // The read-port check below is what real software can ever actually
    // observe anyway, so it's the more meaningful property regardless.

    always @(*) begin
        if (reset_done) begin
            if (readReg1 == 5'd0)
                assert (readData1 == 32'd0);
            else if (regWrite && writeReg == readReg1)
                assert (readData1 == writeData);

            if (readReg2 == 5'd0)
                assert (readData2 == 32'd0);
            else if (regWrite && writeReg == readReg2)
                assert (readData2 == writeData);
        end
    end

endmodule
