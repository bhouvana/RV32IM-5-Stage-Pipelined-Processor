`default_nettype none

`include "wb_defs.vh"

// docs/adr/0020-soc-integration.md (Phase D2). Thin Wishbone slave wrapper
// around the existing, already-verified DataMemoryBRAM.v -- deliberately
// does NOT modify that module at all, keeping its proven 1-cycle
// registered-read timing and existing test coverage completely
// undisturbed (the same "wrap, don't touch a verified module" pattern
// this project used repeatedly in Phase C, e.g. keeping FALU.v unmodified
// when C7 added forwarding around it).
//
// One deliberate, documented deviation from "pure" Wishbone: `funct3` is
// an extra, out-of-band port beyond the standard cyc/stb/we/addr/data_o/
// sel/data_i/ack set (see wb_defs.vh). DataMemoryBRAM.v bakes load width
// *and signedness* together into its funct3 input (lb vs lbu both
// address a single byte -- the same `sel` byte-enable pattern either way
// -- but need different sign-extension behavior); a pure byte-enable
// `sel` mask alone cannot distinguish them. Rather than either (a)
// modifying DataMemoryBRAM.v to move sign-extension out to the bus
// master, or (b) losing lb/lh's sign-extension correctness, this module
// takes `funct3` directly as a side-band tag, wired point-to-point from
// riscvpipeline.v's LSU in D3 (bypassing WbDecoder.v's generic broadcast
// entirely -- no other slave needs it, so WbDecoder.v itself needed no
// changes for this). A real vendor-neutral Wishbone bus with a
// width-and-signedness-aware slave would define this as a TGD (tag) signal
// in the same spirit; this is that idea without inventing generality
// nothing here yet needs.
module RamWishboneAdapter #(
    parameter SIZE_BYTES = 128,
    parameter XLEN = 32,
    parameter DATA_INIT_FILE = "",
    parameter ZERO_INIT_LIMIT_OVERRIDE = 0  // docs/adr/0036 -- threaded straight through to DataMemoryBRAM.v
)(
    input clk,
    input rst,

    input                          s_cyc,
    input                          s_stb,
    input                          s_we,
    input      [XLEN-1:0]          s_addr,
    input      [XLEN-1:0]          s_data_o,
    input      [`WB_SEL_WIDTH-1:0] s_sel,   // unused: funct3 already carries width (see header)
    input      [2:0]               funct3,  // side-band width+signedness tag
    output     [XLEN-1:0]          s_data_i,
    output                         s_ack
);

wire mem_write = s_cyc && s_stb && s_we;
wire mem_read  = s_cyc && s_stb && !s_we;

DataMemoryBRAM #(.SIZE_BYTES(SIZE_BYTES), .XLEN(XLEN), .DATA_INIT_FILE(DATA_INIT_FILE), .ZERO_INIT_LIMIT_OVERRIDE(ZERO_INIT_LIMIT_OVERRIDE)) m_ram(
    .clk(clk), .rst(rst),
    .memWrite(mem_write), .memRead(mem_read),
    .address(s_addr), .writeData(s_data_o), .funct3(funct3),
    .readData(s_data_i)
);

// A write commits on the same clock edge DataMemoryBRAM.v samples
// memWrite (a plain synchronous register write, same as this core's
// existing memWrite_regem wiring already assumed with no stall at all --
// mem_stall today gates only on memRead) -- ack combinationally, so the
// master never waits an extra cycle beyond what it already didn't wait
// for. A read is registered one cycle later inside DataMemoryBRAM.v
// itself (docs/adr/0013); mem_read_pending_r mirrors that exact same
// one-cycle delay so s_ack lands on precisely the cycle s_data_i
// (DataMemoryBRAM's own readData) actually becomes valid.
reg mem_read_pending_r;
always @(posedge clk) begin
    if (~rst)
        mem_read_pending_r <= 1'b0;
    else
        mem_read_pending_r <= mem_read;
end
assign s_ack = mem_write || mem_read_pending_r;

endmodule

`default_nettype wire
