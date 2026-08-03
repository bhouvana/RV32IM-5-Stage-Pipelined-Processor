// docs/adr/0027-formal-verification.md (Phase L4). Dummy stub -- see
// stubs/FALU.v's own header comment for why.
module FMADDUnit (
    input [1:0] op,
    input [2:0] rm,
    input [31:0] a,
    input [31:0] b,
    input [31:0] c,
    output [31:0] result,
    output [4:0] flags
);
    assign result = 32'b0;
    assign flags = 5'b0;
endmodule
