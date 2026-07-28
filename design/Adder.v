`default_nettype none

module Adder #(
    parameter XLEN = 32   // docs/adr/0015-xlen-and-regcount-parameterization.md --
                            // named, not truly variable: this core is RV32I-only,
                            // so 32 is the only ISA-valid value. Threaded through
                            // for a single source of truth (matching CQ-1's
                            // riscv_defs.vh spirit) rather than scattered literals.
)(
    input signed [XLEN-1:0] a,
    input signed [XLEN-1:0] b,
    output signed [XLEN-1:0] sum
);
    // Adder computes sum = a + b
    // The module is useful for incrementing PC 

 assign sum = a + b;

endmodule

`default_nettype wire
