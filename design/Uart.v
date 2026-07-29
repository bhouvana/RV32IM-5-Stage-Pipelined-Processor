`default_nettype none

`include "wb_defs.vh"

// docs/adr/0020-soc-integration.md (Phase D4). Cycle-accurate UART
// peripheral -- genuinely novel to this codebase, no existing precedent
// (this phase's closest analog to Phase C's FSqrt.v). Real serial framing
// (1 start bit, 8 data bits, 1 stop bit, LSB first -- the standard
// "8N1" shape), shifted one bit per CLKS_PER_BIT cycles, not an instant
// behavioral stand-in. `CLKS_PER_BIT` is a fixed elaboration-time
// parameter (docs/adr/0020's own Context section: "cycle-accurate" means
// real bit-by-bit timing is modeled, not that software gets to program a
// baud-rate divisor register -- that stays explicit future work).
//
// Native Wishbone slave (see wb_defs.vh for the signal convention). Byte
// register map, decoded on s_addr[3:2] (word-aligned, matching every
// other access this core makes):
//   0x0 TXDATA  (write-only in practice): write a byte to send. Ignored
//               (not queued) while tx_busy -- software must poll STATUS
//               first, exactly the "polled, no interrupt" shape D5 wires
//               this up with; TX gets no interrupt in this phase at all.
//   0x4 RXDATA  (read-only in practice): the last fully-received byte.
//               Reading it clears STATUS.rx_ready (a real "consume the
//               byte" side effect, not just a peek).
//   0x8 STATUS  (read-only): bit0=tx_busy, bit1=rx_ready.
//   0xC CONTROL (read/write): bit0=rx_irq_enable (has no consumer until
//               D8's mip.MEIP wiring; harmless to set/read before then).
//
// RX samples at the *middle* of each bit period (half a bit after the
// detected start-bit edge, then a full bit period per subsequent bit) --
// standard UART receiver practice, not a shortcut: sampling at the
// leading edge of a bit window risks catching transition jitter instead
// of the settled value.
//
// Deliberately no overrun/framing-error flags: if software doesn't read
// RXDATA before the next byte finishes, the new byte silently overwrites
// it (matching this phase's documented minimal scope -- see
// docs/adr/0020's Explicitly out of scope).
module Uart #(
    parameter CLKS_PER_BIT = 4
)(
    input clk,
    input rst,

    input                          s_cyc,
    input                          s_stb,
    input                          s_we,
    input      [31:0]              s_addr,
    input      [31:0]              s_data_o,
    input      [`WB_SEL_WIDTH-1:0] s_sel,
    output reg [31:0]              s_data_i,
    output                         s_ack,

    output reg tx,
    input      rx,

    output rx_irq  // rx_ready && rx_irq_enable -- D8's mip.MEIP source
);

localparam CNT_WIDTH = $clog2(CLKS_PER_BIT + 1);

wire bus_write = s_cyc && s_stb && s_we;
wire bus_read  = s_cyc && s_stb && !s_we;
assign s_ack = s_cyc && s_stb;  // this slave always completes in the same cycle it's addressed

wire [1:0] reg_sel = s_addr[3:2];
localparam REG_TXDATA  = 2'b00;
localparam REG_RXDATA  = 2'b01;
localparam REG_STATUS  = 2'b10;
localparam REG_CONTROL = 2'b11;

// ==========================================================================
// TX: idle-high line, start(0)-8data(LSB first)-stop(1), one bit per
// CLKS_PER_BIT cycles.
// ==========================================================================
localparam TX_IDLE = 2'd0, TX_START = 2'd1, TX_DATA = 2'd2, TX_STOP = 2'd3;
reg [1:0] tx_state;
reg [CNT_WIDTH-1:0] tx_clk_count;
reg [2:0] tx_bit_index;
reg [7:0] tx_shift_reg;
wire tx_busy = (tx_state != TX_IDLE);

always @(posedge clk) begin
    if (~rst) begin
        tx_state <= TX_IDLE;
        tx <= 1'b1;
        tx_clk_count <= 0;
        tx_bit_index <= 0;
    end else begin
        case (tx_state)
            TX_IDLE: begin
                tx <= 1'b1;
                if (bus_write && (reg_sel == REG_TXDATA)) begin
                    tx_shift_reg <= s_data_o[7:0];
                    tx_state <= TX_START;
                    tx_clk_count <= 0;
                end
            end
            TX_START: begin
                tx <= 1'b0;
                if (tx_clk_count == CLKS_PER_BIT - 1) begin
                    tx_clk_count <= 0;
                    tx_bit_index <= 0;
                    tx_state <= TX_DATA;
                end else begin
                    tx_clk_count <= tx_clk_count + 1'b1;
                end
            end
            TX_DATA: begin
                tx <= tx_shift_reg[tx_bit_index];
                if (tx_clk_count == CLKS_PER_BIT - 1) begin
                    tx_clk_count <= 0;
                    if (tx_bit_index == 3'd7) begin
                        tx_state <= TX_STOP;
                    end else begin
                        tx_bit_index <= tx_bit_index + 1'b1;
                    end
                end else begin
                    tx_clk_count <= tx_clk_count + 1'b1;
                end
            end
            TX_STOP: begin
                tx <= 1'b1;
                if (tx_clk_count == CLKS_PER_BIT - 1) begin
                    tx_clk_count <= 0;
                    tx_state <= TX_IDLE;
                end else begin
                    tx_clk_count <= tx_clk_count + 1'b1;
                end
            end
            default: tx_state <= TX_IDLE;
        endcase
    end
end

// ==========================================================================
// RX: detect a falling edge on an idle-high line, sample each bit at its
// midpoint.
// ==========================================================================
localparam RX_IDLE = 2'd0, RX_START = 2'd1, RX_DATA = 2'd2, RX_STOP = 2'd3;
reg [1:0] rx_state;
reg [CNT_WIDTH-1:0] rx_clk_count;
reg [2:0] rx_bit_index;
reg [7:0] rx_shift_reg;
reg [7:0] rx_data_reg;
reg rx_ready;
reg rx_irq_enable;
reg rx_prev;  // for edge detection

always @(posedge clk) begin
    if (~rst) begin
        rx_state <= RX_IDLE;
        rx_clk_count <= 0;
        rx_bit_index <= 0;
        rx_data_reg <= 8'b0;
        rx_ready <= 1'b0;
        rx_irq_enable <= 1'b0;
        rx_prev <= 1'b1;
    end else begin
        rx_prev <= rx;

        // A read of RXDATA consumes the byte (clears rx_ready) regardless
        // of what the RX state machine itself is doing this same cycle --
        // deliberately checked independently of the case statement below
        // so a same-cycle "byte N+1 just finished" and "software reads
        // byte N" don't need special-casing against each other (the new
        // byte's own `rx_ready <= 1'b1` in RX_STOP, if it fires the same
        // cycle, is textually later and wins, which is correct: the newly
        // completed byte IS the current unread one at that point).
        if (bus_read && (reg_sel == REG_RXDATA))
            rx_ready <= 1'b0;

        if (bus_write && (reg_sel == REG_CONTROL))
            rx_irq_enable <= s_data_o[0];

        case (rx_state)
            RX_IDLE: begin
                rx_clk_count <= 0;
                if (rx_prev && !rx) begin
                    // Falling edge: start bit begins. Wait half a bit
                    // period before confirming/sampling, so every
                    // subsequent sample lands mid-bit.
                    rx_state <= RX_START;
                    rx_clk_count <= 0;
                end
            end
            RX_START: begin
                if (rx_clk_count == (CLKS_PER_BIT / 2) - 1) begin
                    if (!rx) begin
                        // Confirmed real start bit (not a glitch) --
                        // begin sampling data bits, one full period apart.
                        rx_clk_count <= 0;
                        rx_bit_index <= 0;
                        rx_state <= RX_DATA;
                    end else begin
                        rx_state <= RX_IDLE;  // spurious edge, abort
                    end
                end else begin
                    rx_clk_count <= rx_clk_count + 1'b1;
                end
            end
            RX_DATA: begin
                if (rx_clk_count == CLKS_PER_BIT - 1) begin
                    rx_clk_count <= 0;
                    rx_shift_reg[rx_bit_index] <= rx;
                    if (rx_bit_index == 3'd7) begin
                        rx_state <= RX_STOP;
                    end else begin
                        rx_bit_index <= rx_bit_index + 1'b1;
                    end
                end else begin
                    rx_clk_count <= rx_clk_count + 1'b1;
                end
            end
            RX_STOP: begin
                if (rx_clk_count == CLKS_PER_BIT - 1) begin
                    rx_data_reg <= rx_shift_reg;
                    rx_ready <= 1'b1;
                    rx_state <= RX_IDLE;
                    rx_clk_count <= 0;
                end else begin
                    rx_clk_count <= rx_clk_count + 1'b1;
                end
            end
            default: rx_state <= RX_IDLE;
        endcase
    end
end

assign rx_irq = rx_ready && rx_irq_enable;

// ==========================================================================
// Read mux
// ==========================================================================
always @(*) begin
    case (reg_sel)
        REG_RXDATA:  s_data_i = {24'b0, rx_data_reg};
        REG_STATUS:  s_data_i = {30'b0, rx_ready, tx_busy};
        REG_CONTROL: s_data_i = {31'b0, rx_irq_enable};
        default:     s_data_i = 32'b0;  // REG_TXDATA and anything else read as 0
    endcase
end

endmodule

`default_nettype wire
