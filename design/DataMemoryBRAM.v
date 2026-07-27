`default_nettype none

// Synchronous-read data memory (docs/ROADMAP.md Phase 7, docs/adr/0012-fpga-
// readiness.md). NOT wired into PIPELINED -- integrating it would change
// when a load's result becomes available (one cycle later than today's
// DataMemory.v, whose read is combinational), which ripples into Forward.v,
// Hazard.v, and reg4's timing exactly the way docs/adr/0009's divider did
// for div/rem. That retiming is real, scoped work of its own, deliberately
// deferred (see the ADR) rather than attempted as a drive-by change to an
// otherwise fully-verified pipeline. This module exists as a proven,
// standalone building block for that future integration.
//
// The read idiom below -- indexing the memory array directly into a
// register on `posedge clk`, with any further combinational logic (here,
// funct3-based sign/zero-extension) applied to that *registered* value, not
// used to re-index the array a second time -- is the standard pattern
// synthesis tools recognize as single-port block RAM, on Xilinx/Intel/
// Lattice alike.
module DataMemoryBRAM #(
    parameter SIZE_BYTES = 128
)(
    input clk,
    input rst,
    input memWrite,
    input memRead,
    input [31:0] address,
    input [31:0] writeData,
    input [2:0] funct3,   // access width/signedness: 000=b(signed) 001=h(signed) 010=w 100=bu 101=hu
    output reg [31:0] readData
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
