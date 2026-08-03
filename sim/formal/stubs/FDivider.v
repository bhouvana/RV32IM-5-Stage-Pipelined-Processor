// docs/adr/0027-formal-verification.md (Phase L4). Dummy stub -- see
// stubs/FALU.v's own header comment for why. `done` tied high (never
// `busy`) so `fp_stall` never gets artificially stuck -- irrelevant to
// this property either way (FDivider's real output only feeds fflags/
// FRegister.v), but avoids introducing an unrelated dummy-induced stall.
module FDivider #(
    parameter XLEN = 32
)(
    input clk,
    input rst,
    input start,
    input [2:0] rm,
    input [XLEN-1:0] a,
    input [XLEN-1:0] b,
    output busy,
    output done,
    output [XLEN-1:0] result,
    output [4:0] flags
);
    assign busy = 1'b0;
    assign done = start;
    assign result = {XLEN{1'b0}};
    assign flags = 5'b0;
endmodule
