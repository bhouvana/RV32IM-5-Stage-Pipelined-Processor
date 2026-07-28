`default_nettype none

// Synchronous-read data memory (docs/ROADMAP.md Phase 7, docs/adr/0012-fpga-
// readiness.md). Wired into PIPELINED as of docs/adr/0013-mem-stage-retiming.md,
// which added the MEM-stage interlock (riscvpipeline.v's `mem_stall`) needed
// to accommodate the one-cycle-later load result this module's registered
// read produces relative to the old combinational DataMemory.v. That
// interlock tracks readiness itself (per reg3's occupant, not via a port on
// this module) -- see the ADR for why a raw "was memRead asserted last
// cycle" signal from here can't distinguish a fresh load's first cycle from
// a residual assertion left by an immediately preceding load's own stall.
//
// The read idiom below -- indexing the memory array directly into a
// register on `posedge clk`, with any further combinational logic (here,
// funct3-based sign/zero-extension) applied to that *registered* value, not
// used to re-index the array a second time -- is the standard pattern
// synthesis tools recognize as single-port block RAM, on Xilinx/Intel/
// Lattice alike.
module DataMemoryBRAM #(
    parameter SIZE_BYTES = 128,
    // docs/adr/0015-xlen-and-regcount-parameterization.md -- only the port
    // widths, not the access-width logic below: lb/lh/lw/sb/sh/sw are a
    // fixed byte/halfword/(4-byte)word set in RV32I's own encoding,
    // independent of XLEN (RV64I keeps the same three and adds a separate
    // ld/sd for the 8-byte case) -- that's an ISA-behavior axis, not a
    // width/depth one, so it stays literal here same as Control.v/ALUCtrl.v's
    // opcode/funct3 decoding does.
    parameter XLEN = 32,
    // Optional pre-load of initial data contents (docs/ROADMAP.md Phase 10
    // -- compiled-C programs' .data section needs its initial values
    // present before main() runs, unlike every hand-written .s test so
    // far, which only ever wrote to memory itself at runtime). Empty
    // string (default) disables this entirely, matching every existing
    // test's assumption -- mirrors InstructionMemory.v's own INIT_FILE
    // pattern, just applied on this module's synchronous reset instead of
    // an `initial` block, since that's where this module's own zero-init
    // already lives.
    parameter DATA_INIT_FILE = ""
)(
    input clk,
    input rst,
    input memWrite,
    input memRead,
    input [XLEN-1:0] address,
    input [XLEN-1:0] writeData,
    input [2:0] funct3,   // access width/signedness: 000=b(signed) 001=h(signed) 010=w 100=bu 101=hu
    output reg [XLEN-1:0] readData
);

    reg [7:0] data_memory [0:SIZE_BYTES-1];
    integer rst_i;

    // Latched every cycle alongside the raw word read, so the extension
    // logic below always matches the access that produced raw_word_r --
    // using this cycle's (not last cycle's) funct3/memRead would extend the
    // *next* access's width against *this* access's data.
    reg [31:0] raw_word_r;
    reg [2:0] funct3_r;
    reg mem_read_r;

    always @(posedge clk) begin
        if (~rst) begin
            // These two are deliberately mutually exclusive, not sequenced
            // one after the other: $readmemb (called synchronously, as part
            // of this same active region) would otherwise be silently
            // clobbered by the for-loop's *nonblocking* writes to the same
            // array, which don't actually commit until the end of this time
            // step -- i.e. after $readmemb already ran, regardless of their
            // textual order. Caught by direct verification (a throwaway
            // testbench pre-loading known bytes and checking they survived
            // reset), not assumed correct from the code reading right.
            if (DATA_INIT_FILE != "")
                // Explicit start/stop avoids relying on simulator-specific
                // default behavior for which end of a descending-range array
                // $readmemb fills first (Icarus warns about exactly this
                // ambiguity otherwise) -- same reasoning InstructionMemory.v's
                // own $readmemb call already documents.
                $readmemb(DATA_INIT_FILE, data_memory, 0, SIZE_BYTES-1);
            else
                for (rst_i = 0; rst_i < SIZE_BYTES; rst_i = rst_i + 1)
                    data_memory[rst_i] <= 8'b0;
            raw_word_r <= 32'b0;
            funct3_r   <= 3'b0;
            mem_read_r <= 1'b0;
        end else begin
            if (memWrite) begin
                // funct3[1:0]: 00=sb, 01=sh, 10=sw (funct3[2] unused for stores)
                case (funct3[1:0])
                    2'b00: begin // sb
                        data_memory[address] <= writeData[7:0];
                    end
                    2'b01: begin // sh
                        data_memory[address + 1] <= writeData[15:8];
                        data_memory[address]     <= writeData[7:0];
                    end
                    default: begin // sw
                        data_memory[address + 3] <= writeData[31:24];
                        data_memory[address + 2] <= writeData[23:16];
                        data_memory[address + 1] <= writeData[15:8];
                        data_memory[address]     <= writeData[7:0];
                    end
                endcase
            end

            // Always read the full word at `address` -- real BRAM has no
            // narrower-than-configured read port to speak of, so width
            // selection happens after the fact (below), not here. A
            // same-cycle write to the same address is intentionally NOT
            // forwarded into this read (real BRAM in the common single
            // read-during-write mode returns old data, or X, depending on
            // vendor primitive -- software/callers on real hardware must not
            // rely on same-cycle read-after-write either).
            raw_word_r <= {data_memory[address + 3], data_memory[address + 2],
                           data_memory[address + 1], data_memory[address]};
            funct3_r   <= funct3;
            mem_read_r <= memRead;
        end
    end

    always @(*) begin
        if (mem_read_r) begin
            case (funct3_r)
                3'b000: readData = {{24{raw_word_r[7]}},  raw_word_r[7:0]};    // lb
                3'b100: readData = {24'b0,                raw_word_r[7:0]};    // lbu
                3'b001: readData = {{16{raw_word_r[15]}}, raw_word_r[15:0]};   // lh
                3'b101: readData = {16'b0,                raw_word_r[15:0]};   // lhu
                default: readData = raw_word_r;                                // lw
            endcase
        end else begin
            readData = 32'b0;
        end
    end

endmodule

`default_nettype wire
