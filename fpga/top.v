`default_nettype none

// Generic FPGA top-level wrapper (docs/ROADMAP.md Phase 7, docs/adr/0012-
// fpga-readiness.md) -- a bring-up smoke test, not a board-specific
// production target. Board pin names (`clk_i`, `btn_rst_ni`, `leds`) are
// generic on purpose; map them to a real board's actual pins in a
// board-specific constraints file (see fpga/constraints_template.xdc) rather
// than editing this file per board.
//
// What this proves on real hardware: the board's oscillator and reset button
// are wired correctly (the slow heartbeat blink, independent of the CPU
// core), and the CPU is actually clocking and executing the program baked
// into INIT_FILE at synthesis time (the `leds` output tracks x10/a0, so a
// test program that does `addi a0, x0, <pattern>` then spins is directly
// observable). It is deliberately not a full SoC (no UART, no memory-mapped
// I/O, no boot ROM) -- see Future improvements in the ADR for what a real
// bring-up target would still need.
module top #(
    parameter INIT_FILE = "sim/programs/demo.mem",
    parameter HEARTBEAT_DIV_BITS = 24   // board-clock-rate dependent; 24 bits
                                          // is a visible-to-the-eye blink rate
                                          // around a typical 50-100MHz board
                                          // oscillator (~3-6 Hz). Retune per
                                          // board in the instantiating build,
                                          // not by editing this default.
)(
    input  wire clk_i,       // board oscillator, unbuffered -- route through
                               // the vendor's clock buffer/PLL primitive at
                               // the board-specific integration level if one
                               // is needed (this file stays vendor-neutral).
    input  wire btn_rst_ni,  // active-low reset button (typical for most dev
                               // boards); synchronized and inverted below to
                               // match PIPELINED's active-high `start` sense.
    output wire [7:0] leds
);

    // ---- reset synchronization ----
    // btn_rst_ni is an asynchronous external signal (a mechanical button, no
    // debounce circuit assumed here -- add one at board integration if the
    // target board doesn't already debounce in hardware). Two-flop
    // synchronizer to avoid metastability feeding into a synchronous design;
    // `start` is PIPELINED's active-high "run" sense (see riscvpipeline.v's
    // header comment -- named `start` for historical reasons, behaves as an
    // active-low synchronous reset).
    reg rst_sync_0, rst_sync_1;
    always @(posedge clk_i) begin
        rst_sync_0 <= btn_rst_ni;
        rst_sync_1 <= rst_sync_0;
    end
    wire start = rst_sync_1;

    // ---- heartbeat ----
    // Independent of the CPU core entirely -- if this doesn't blink, the
    // problem is the board/clock/bitstream, not the RISC-V design. The top
    // bit of a free-running counter is the simplest visible-frequency-
    // division trick that needs no board-specific timing knowledge here.
    reg [HEARTBEAT_DIV_BITS-1:0] heartbeat_counter;
    always @(posedge clk_i) begin
        if (~start)
            heartbeat_counter <= 0;
        else
            heartbeat_counter <= heartbeat_counter + 1'b1;
    end

    // ---- CPU ----
    wire [31:0] debug_x10;
    PIPELINED #(
        .INIT_FILE(INIT_FILE)
    ) m_cpu (
        .clk(clk_i),
        .start(start),
        .debug_x10(debug_x10)
    );

    assign leds = {heartbeat_counter[HEARTBEAT_DIV_BITS-1], debug_x10[6:0]};

endmodule

`default_nettype wire
