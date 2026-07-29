// docs/adr/0020-soc-integration.md (Phase D1). Naming convention and shared
// width constants for this core's classic (non-pipelined) Wishbone-style
// bus -- every module that speaks this bus (WbDecoder.v, and later
// RamWishboneAdapter.v/Uart.v/Timer.v) uses this exact signal shape:
//
//   cyc     -- transaction in progress (asserted for the whole request)
//   stb     -- this cycle's request is valid (classic Wishbone keeps cyc/stb
//               distinct even though a single-master bus like this one
//               always asserts them together; kept as two signals anyway
//               since that's the real protocol, not a simplification of it)
//   we      -- 1=write, 0=read
//   addr    -- byte address (XLEN-wide, matching every other address bus
//               in this core -- see docs/adr/0015)
//   data_o  -- write data (master-to-slave)
//   sel     -- byte-enable lanes (4 bits for a 32-bit bus, one per byte)
//   data_i  -- read data (slave-to-master), valid the cycle `ack` is high
//   ack     -- this transaction is complete (the generalized replacement
//               for today's single-BRAM-shaped `mem_stall`: "freeze while
//               `!ack`" reduces to today's exact 1-cycle timing against a
//               registered-read RAM, but composes with variable-latency
//               peripherals too)
//
// Signals are prefixed `m_` (master-side, i.e. what riscvpipeline.v's LSU
// adapter drives/reads) or `s_` (slave-side, i.e. what each peripheral
// drives/reads) at any module boundary where both exist (WbDecoder.v).
// A peripheral's own testbench-facing ports (e.g. Uart.v's tx/rx pins)
// are unrelated to this bus convention and named on their own terms.
`ifndef WB_DEFS_VH
`define WB_DEFS_VH

`define WB_SEL_WIDTH 4  // one byte-enable bit per byte of a 32-bit data bus

`endif
