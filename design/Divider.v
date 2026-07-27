`default_nettype none

// 32-cycle shift-subtract restoring divider (docs/adr/0009-multicycle-divider.md).
// Replaces the single-cycle `/`/`%`-based div/rem from docs/adr/0006 with a
// genuine iterative multi-cycle unit, and is the counterpart interlock logic
// (busy/done) that riscvpipeline.v uses to stall the pipeline while a
// division is in flight -- a different, longer-duration stall than
// Hazard.v's existing 1-cycle load-use stall.
module Divider (
    input clk,
    input rst,
    input start,          // level: caller ties this to "the instruction currently
                           // presented is a div/rem whose result isn't ready yet"
                           // (see riscvpipeline.v's isDivRem) -- held asserted for
                           // the instruction's entire stay in EX, not a one-shot pulse
    input isSigned,        // 1 = div/rem (signed), 0 = divu/remu (unsigned)
    input [31:0] dividend,
    input [31:0] divisor,
    output reg busy,       // computation in progress (deasserts the same cycle `done` pulses)
    output reg done,       // one-cycle pulse: quotient/remainder valid this cycle
    output reg [31:0] quotient,
    output reg [31:0] remainder
);

    reg [31:0] R, Q, D;        // working remainder/quotient/divisor (unsigned magnitudes)
    reg [4:0] count;           // 0..31, one bit of the algorithm per cycle
    reg neg_quotient, neg_remainder;
    reg [31:0] R_shifted, new_R, new_Q;  // this step's result, computed once and reused

    wire [31:0] abs_dividend = (isSigned && dividend[31]) ? (~dividend + 32'b1) : dividend;
    wire [31:0] abs_divisor  = (isSigned && divisor[31])  ? (~divisor  + 32'b1) : divisor;

    always @(posedge clk) begin
        if (~rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            quotient <= 32'b0;
            remainder <= 32'b0;
        end
        else begin
            done <= 1'b0;  // default: one-cycle pulse, cleared unless set below

            // `start` is a level tied to "the div/rem instruction presented
            // this cycle hasn't been resolved yet" (see the port comment
            // above), so it stays asserted through the exact cycle `done`
            // pulses -- the caller's pipeline hold only releases the cycle
            // *after* done, since reg3 needs this instruction's fields one
            // more cycle to latch the result. Without `&& !done` here,
            // busy==0 on the done cycle would look identical to "idle,
            // ready for a new request" and immediately restart a second,
            // bogus division on the same (stale, not-yet-replaced) operands
            // before the real result could be consumed.
            if (start && !busy && !done) begin
                if (divisor == 32'b0) begin
                    // Divide by zero: spec-mandated result, no iteration needed.
                    quotient <= 32'hFFFFFFFF;
                    remainder <= dividend;
                    done <= 1'b1;
                end
                else if (isSigned && dividend == 32'h80000000 && divisor == 32'hFFFFFFFF) begin
                    // Signed overflow (INT_MIN / -1): spec-mandated result.
                    quotient <= dividend;
                    remainder <= 32'b0;
                    done <= 1'b1;
                end
                else begin
                    R <= 32'b0;
                    Q <= abs_dividend;
                    D <= abs_divisor;
                    neg_quotient <= isSigned && (dividend[31] ^ divisor[31]);
                    neg_remainder <= isSigned && dividend[31];
                    count <= 5'd0;
                    busy <= 1'b1;
                end
            end
            else if (busy) begin
                // One shift-subtract-restore step of the combined {R,Q} 64-bit
                // register: shift left by 1, then subtract D from the new R
                // if it fits (restoring division -- always subtract-and-check,
                // never subtract-then-add-back). Computed once into
                // new_R/new_Q (blocking, local to this step) and reused below
                // for both the running R/Q update and the final-cycle output.
                R_shifted = {R[30:0], Q[31]};
                if (R_shifted >= D) begin
                    new_R = R_shifted - D;
                    new_Q = {Q[30:0], 1'b1};
                end
                else begin
                    new_R = R_shifted;
                    new_Q = {Q[30:0], 1'b0};
                end
                R <= new_R;
                Q <= new_Q;

                if (count == 5'd31) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    quotient  <= neg_quotient  ? (~new_Q + 32'b1) : new_Q;
                    remainder <= neg_remainder ? (~new_R + 32'b1) : new_R;
                end
                count <= count + 5'd1;
            end
        end
    end

endmodule

`default_nettype wire
