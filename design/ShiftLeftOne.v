`default_nettype none

// `imm << 1`: branch/jal immediates are counted in multiples of 2 bytes per
// RV32I's encoding (bit 0 is implicit 0), so this recovers the real byte
// offset before it reaches the target-address adder. jalr does NOT use
// this -- its immediate is a plain, unshifted I-type value (see
// riscvpipeline.v's target_off mux).
module ShiftLeftOne (
    input signed [31:0] i,
    output signed [31:0] o
);

   assign o = i << 1;

endmodule

`default_nettype wire
