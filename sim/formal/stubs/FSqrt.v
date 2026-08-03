// docs/adr/0027-formal-verification.md (Phase L4). Dummy stub -- see
// stubs/FALU.v's own header comment for why; see stubs/FDivider.v's own
// comment for the `done`-tied-high reasoning.
module FSqrt #(
    parameter XLEN = 32
)(
    input clk,
    input rst,
    input start,
    input [2:0] rm,
    input [XLEN-1:0] a,
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
