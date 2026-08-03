// docs/adr/0027-formal-verification.md (Phase L4). Dummy stub -- only
// used by sim/formal/pipeline_formal.sby, never by real simulation or
// synthesis. The real design/FALU.v's own fp_round.vh-based for-loop trips
// Yosys's read_verilog frontend ("2nd expression of procedural for-loop is
// not constant"), and a genuine `(* blackbox *)` version of this module
// tripped a SEPARATE Yosys issue (its own loop-detection pass errors when
// a detected combinational-loop cone-of-influence passes through an opaque
// blackbox it can't see into -- confirmed by running, unrelated to FALU's
// own real behavior). FALU's real output only ever feeds fflags/
// FRegister.v, never the integer regWrite/valid commit path this
// property checks, so a trivial concrete (non-blackbox) always-0 body is
// exactly as valid for this property as a truly free/unconstrained one,
// and avoids the whole blackbox-vs-loop-detection interaction.
module FALU (
    input [4:0] funct5,
    input [2:0] funct3,
    input [4:0] rs2_sel,
    input [31:0] a,
    input [31:0] b,
    output [31:0] result,
    output [4:0] flags
);
    assign result = 32'b0;
    assign flags = 5'b0;
endmodule
