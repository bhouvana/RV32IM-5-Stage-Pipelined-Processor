`default_nettype none

`include "wb_defs.vh"

// docs/adr/0020-soc-integration.md (Phase D6). Free-running machine-timer
// peripheral (RISC-V's standard CLINT mtime/mtimecmp shape), native
// Wishbone slave. Deliberately 32-bit mtime/mtimecmp, not the real spec's
// 64-bit pair split across two 32-bit halves -- a documented
// simplification for this single-hart, simulation-focused core (the same
// "minimal, not maximal" spirit as this phase's PLIC-lite decision):
// avoids the real complexity of a 64-bit compare split across two
// separately-writable 32-bit registers for no payoff this phase's actual
// verification needs.
//
// Register map (word-aligned, s_addr[2]):
//   0x0 MTIME    (read/write): free-running counter, increments every
//                cycle it isn't itself being written. Writable so
//                software/tests can set a known starting point (matches
//                the real CLINT mtime's own read/write convention, used
//                for calibration).
//   0x4 MTIMECMP (read/write): compare value. `pending` asserts
//                combinationally whenever mtime >= mtimecmp -- since
//                mtimecmp is a plain register, a write takes effect the
//                cycle after it's issued (same latency as every other
//                register in this core, e.g. CSR.v), not the same cycle;
//                `pending` re-evaluates automatically once it does. A
//                write to MTIMECMP re-arms the comparison the standard
//                CLINT way: it doesn't force `pending` low, it just
//                changes what `pending` is computed against, so a write
//                that leaves the new value already <= mtime simply keeps
//                (or immediately re-asserts) `pending` -- expected, not a
//                special case.
module Timer #(
    parameter XLEN = 32
)(
    input clk,
    input rst,

    input                          s_cyc,
    input                          s_stb,
    input                          s_we,
    input      [XLEN-1:0]          s_addr,
    input      [XLEN-1:0]          s_data_o,
    input      [`WB_SEL_WIDTH-1:0] s_sel,
    output reg [XLEN-1:0]          s_data_i,
    output                         s_ack,

    output pending  // mtime >= mtimecmp -- D8's mip.MTIP source
);

wire bus_write = s_cyc && s_stb && s_we;
assign s_ack = s_cyc && s_stb;  // this slave always completes in the same cycle it's addressed

wire reg_sel = s_addr[2];  // 0=MTIME, 1=MTIMECMP

reg [XLEN-1:0] mtime;
reg [XLEN-1:0] mtimecmp;

always @(posedge clk) begin
    if (~rst) begin
        mtime <= {XLEN{1'b0}};
        mtimecmp <= {XLEN{1'b0}};
    end else begin
        if (bus_write && (reg_sel == 1'b0))
            mtime <= s_data_o;
        else
            mtime <= mtime + 1'b1;

        if (bus_write && (reg_sel == 1'b1))
            mtimecmp <= s_data_o;
    end
end

assign pending = (mtime >= mtimecmp);

always @(*) begin
    case (reg_sel)
        1'b0: s_data_i = mtime;
        1'b1: s_data_i = mtimecmp;
    endcase
end

endmodule

`default_nettype wire
