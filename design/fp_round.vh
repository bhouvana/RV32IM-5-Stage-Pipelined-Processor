// Shared single-precision rounding/normalization helpers (docs/adr/0019-
// f-extension.md, Phase C). Extracted out of FALU.v once FDivider.v/FSqrt.v
// needed the exact same "normalize a raw significand, round it per rm,
// pack it into IEEE 754 bits" logic -- mirrors this project's own
// disasm.py-extraction precedent (a second/third consumer of previously
// FALU.v-local logic is what justified pulling it out, not speculation
// that it might be reused someday). `` `include``d directly (Verilog-2005 has
// no function-library/package mechanism to import from), so whichever file
// includes this gets its own private copy of these functions -- fine, since
// functions have no state of their own.

// ==========================================================================
// Shared normalize-and-round: takes an unrounded, non-negative significand
// (25 bits: bit24 is a possible carry-out from addition/rounding, bit23 is
// the implicit leading 1 once normalized, bits22:0 are the kept fraction
// bits) plus 2 extra rounding bits (guard, round) and a sticky bit, and
// produces the final packed, correctly-rounded float plus OF/UF/NX (NV is
// the caller's concern -- it's about operation validity, not rounding).
// `exp_unbiased` is the *unbiased* exponent of the bit-23 position BEFORE
// any renormalization this function itself performs.
// ==========================================================================
function [34:0] round_and_pack;  // {OF, UF, NX, result[31:0]}
    input sign;
    input signed [9:0] exp_unbiased;
    input [24:0] sig;      // {carry, implicit-1, 23 fraction bits}
    input guard;
    input round_bit;
    input sticky;
    input [2:0] rm;

    reg signed [9:0] e;
    reg [24:0] s;
    reg g, r, st;
    reg round_up;
    reg [7:0] biased;
    reg of_flag, uf_flag, nx_flag;
    begin
        e = exp_unbiased;
        s = sig;
        g = guard; r = round_bit; st = sticky;

        // Renormalize a carry-out from addition (bit24 set) by shifting
        // right one place. The kept significand narrows from s[24:0] to
        // s[24:1] -- s[0] (the one bit that just fell out of the kept
        // window) becomes the new guard bit; the caller's original guard
        // (one binary place further down than the new window's boundary)
        // becomes the new round bit; the original round bit folds into
        // sticky along with whatever sticky already was (nothing silently
        // dropped, nothing double-counted).
        if (s[24]) begin
            st = st | r;
            r = g;
            g = s[0];
            s = s >> 1;
            e = e + 1;
        end

        // Round per mode. A tie (guard=1, round=0, sticky=0) is the only
        // case RNE/RMM must distinguish from a non-tie (guard=1 and
        // (round|sticky)=1, which both treat as "definitely round up").
        case (rm)
            `RM_RNE: round_up = g && (r || st || s[0]);
            `RM_RTZ: round_up = 1'b0;
            `RM_RDN: round_up = sign  && (g || r || st);
            `RM_RUP: round_up = !sign && (g || r || st);
            `RM_RMM: round_up = g;
            default: round_up = g && (r || st || s[0]);  // defensive RNE fallback, see module header
        endcase

        nx_flag = g || r || st;

        if (round_up) begin
            s = s + 1;
            // Rounding itself can carry the mantissa out (e.g. all-1s
            // fraction rounding up to the next power of two) -- one more
            // renormalize.
            if (s[24]) begin
                s = s >> 1;
                e = e + 1;
            end
        end

        // Pack, handling exponent-range special cases. Overflow does NOT
        // always produce infinity: RTZ always truncates to the largest
        // finite value on overflow, and RDN/RUP only produce infinity in
        // the direction they round toward -- otherwise they too saturate
        // to the largest finite value instead (a genuinely easy-to-get-
        // wrong IEEE 754 rule, verified against Python/numpy reference
        // vectors specifically for this).
        of_flag = 1'b0; uf_flag = 1'b0;
        if (e > 127) begin
            of_flag = 1'b1;
            nx_flag = 1'b1;
            if (rm == `RM_RTZ || (rm == `RM_RDN && !sign) || (rm == `RM_RUP && sign))
                round_and_pack = {of_flag, uf_flag, nx_flag, sign, 8'hFE, 23'h7FFFFF};  // largest finite
            else
                round_and_pack = {of_flag, uf_flag, nx_flag, sign, 8'hFF, 23'h000000};  // +/-infinity
        end
        else if (e < -126 || s[23:0] == 0) begin
            // True result is zero, or its magnitude underflows below the
            // smallest normal -- flush to a correctly-signed zero (this
            // core's documented subnormal deviation) rather than producing
            // a real subnormal encoding.
            uf_flag = (e < -126) && (s[23:0] != 0);
            round_and_pack = {of_flag, uf_flag, nx_flag, sign, 8'h00, 23'h000000};
        end
        else begin
            biased = e[7:0] + 8'd127;
            round_and_pack = {of_flag, uf_flag, nx_flag, sign, biased, s[22:0]};
        end
    end
endfunction

// ==========================================================================
// Shift a {24-bit significand, 3'b000} value right by `amt`, OR-ing every
// bit shifted past the kept window into the LSB (sticky) position instead
// of discarding it. Originally the FADD/FSUB alignment step's helper; also
// reused by FDivider.v/FSqrt.v's own post-iteration normalization.
// ==========================================================================
function [26:0] shift_right_sticky;
    input [26:0] sig;
    input signed [9:0] amt;
    reg [26:0] shifted;
    reg sticky_acc;
    integer k;
    begin
        if (amt <= 0) begin
            shift_right_sticky = sig;
        end
        else if (amt >= 27) begin
            shift_right_sticky = {26'b0, |sig};
        end
        else begin
            sticky_acc = 1'b0;
            for (k = 0; k < amt; k = k + 1)
                sticky_acc = sticky_acc | sig[k];
            shifted = sig >> amt;
            shifted[0] = shifted[0] | sticky_acc;
            shift_right_sticky = shifted;
        end
    end
endfunction
