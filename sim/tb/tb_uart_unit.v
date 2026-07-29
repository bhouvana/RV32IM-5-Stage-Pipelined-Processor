`include "Uart.v"
`include "Timer.v"

// docs/adr/0020-soc-integration.md (Phase D4). Standalone unit test for
// Uart.v, independent of the pipeline -- mirrors tb_fregister_unit.v's
// shape. Plays *both* roles a real external UART peer would: as a
// receiver, it samples the DUT's `tx` output pin over time and decodes the
// serial waveform back into a byte (real framing correctness, not an
// internal shortcut signal); as a transmitter, it drives the DUT's `rx`
// input pin with a hand-built serial bit-stream. CLKS_PER_BIT=4 here
// (small, for fast simulation) -- the framing logic itself doesn't care
// about the actual divisor value, only that it counts correctly, so this
// is just as valid a test of correctness as a realistic divisor would be;
// a real deployment would set CLKS_PER_BIT much higher to match a real
// baud rate against a real clock.
module tb_uart_unit;
    localparam CLKS_PER_BIT = 4;

    reg clk = 0;
    reg rst = 0;
    reg s_cyc = 0, s_stb = 0, s_we = 0;
    reg [31:0] s_addr = 0, s_data_o = 0;
    reg [3:0] s_sel = 4'b1111;
    wire [31:0] s_data_i;
    wire s_ack;
    wire tx;
    reg rx = 1;
    wire rx_irq;

    integer fails = 0;
    integer checks = 0;

    Uart #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut(
        .clk(clk), .rst(rst),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we),
        .s_addr(s_addr), .s_data_o(s_data_o), .s_sel(s_sel),
        .s_data_i(s_data_i), .s_ack(s_ack),
        .tx(tx), .rx(rx), .rx_irq(rx_irq)
    );

    always #5 clk = ~clk;

    localparam REG_TXDATA  = 32'h0;
    localparam REG_RXDATA  = 32'h4;
    localparam REG_STATUS  = 32'h8;
    localparam REG_CONTROL = 32'hC;

    task check;
        input [31:0] actual, expected;
        input [511:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: 0x%08h, expected 0x%08h", label, actual, expected);
            end else begin
                $display("pass  %0s: 0x%08h", label, actual);
            end
        end
    endtask

    task check_bit;
        input actual, expected;
        input [511:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: %b, expected %b", label, actual, expected);
            end else begin
                $display("pass  %0s: %b", label, actual);
            end
        end
    endtask

    task wb_write;
        input [31:0] addr, data;
        begin
            @(posedge clk);
            s_cyc <= 1; s_stb <= 1; s_we <= 1; s_addr <= addr; s_data_o <= data;
            @(posedge clk);
            s_cyc <= 0; s_stb <= 0; s_we <= 0;
        end
    endtask

    task wb_read;
        input [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            s_cyc <= 1; s_stb <= 1; s_we <= 0; s_addr <= addr;
            #1 data = s_data_i;
            @(posedge clk);
            s_cyc <= 0; s_stb <= 0;
        end
    endtask

    reg [31:0] rdata;

    // External-receiver role: sample the DUT's tx pin, decode a byte.
    task sample_tx_byte;
        output [7:0] byte_out;
        integer i;
        begin
            @(negedge tx);  // start bit begins
            #(CLKS_PER_BIT * 10 / 2);  // half a bit period (in ns, clk period=10)
            check_bit(tx, 1'b0, "tx: start bit sampled low at its midpoint");
            for (i = 0; i < 8; i = i + 1) begin
                #(CLKS_PER_BIT * 10);
                byte_out[i] = tx;
            end
            #(CLKS_PER_BIT * 10);
            check_bit(tx, 1'b1, "tx: stop bit sampled high at its midpoint");
        end
    endtask

    // External-transmitter role: drive the DUT's rx pin with a full frame.
    task drive_rx_byte;
        input [7:0] byte_in;
        integer i;
        begin
            rx = 0;  // start bit
            repeat (CLKS_PER_BIT) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                rx = byte_in[i];
                repeat (CLKS_PER_BIT) @(posedge clk);
            end
            rx = 1;  // stop bit
            repeat (CLKS_PER_BIT) @(posedge clk);
        end
    endtask

    reg [7:0] got_byte;

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // TX: write a byte, confirm STATUS.tx_busy, decode the serial
        // output, confirm STATUS.tx_busy clears once the frame completes.
        wb_read(REG_STATUS, rdata);
        check_bit(rdata[0], 1'b0, "tx_busy is 0 before any write");

        // Checked via a direct hierarchical reference (dut.tx_busy), not a
        // bus read -- a wb_read here would burn 2 more clock edges before
        // sample_tx_byte starts listening for the start-bit negedge,
        // leaving too little of the 4-cycle start-bit window to reliably
        // still be within it (found by tracing through an earlier version
        // of this test that intermittently decoded garbage for exactly
        // this reason -- the extra read pushed `@(negedge tx)` past the
        // real edge into a later, unintended one mid-frame).
        wb_write(REG_TXDATA, 32'h000000A5);  // 10100101
        #1 check_bit(dut.tx_busy, 1'b1, "tx_busy is 1 right after a TXDATA write");

        sample_tx_byte(got_byte);
        check(got_byte, 8'hA5, "TX: decoded serial waveform matches written byte 0xA5");

        // tx_busy should clear shortly after the stop bit's own sample
        // point (well within one more bit period).
        repeat (CLKS_PER_BIT) @(posedge clk);
        wb_read(REG_STATUS, rdata);
        check_bit(rdata[0], 1'b0, "tx_busy clears once the frame completes");

        // A second TX byte, back to back, confirms the state machine
        // correctly returns to idle and can send again (not stuck).
        wb_write(REG_TXDATA, 32'h00000042);  // 01000010
        sample_tx_byte(got_byte);
        check(got_byte, 8'h42, "TX: second byte (0x42) also decodes correctly");

        // RX: drive a byte in, confirm RXDATA and STATUS.rx_ready, confirm
        // reading RXDATA clears rx_ready.
        wb_read(REG_STATUS, rdata);
        check_bit(rdata[1], 1'b0, "rx_ready is 0 before any RX frame");

        drive_rx_byte(8'hC3);
        #1;
        wb_read(REG_STATUS, rdata);
        check_bit(rdata[1], 1'b1, "rx_ready is 1 after a full RX frame");

        wb_read(REG_RXDATA, rdata);
        check(rdata, 32'h000000C3, "RXDATA matches the driven byte 0xC3");

        wb_read(REG_STATUS, rdata);
        check_bit(rdata[1], 1'b0, "rx_ready clears after RXDATA is read");

        // RX interrupt: enabling CONTROL.rx_irq_enable makes rx_irq track
        // rx_ready && enable; disabled (default), it must stay 0 even with
        // a byte pending.
        drive_rx_byte(8'h55);
        #1;
        check_bit(rx_irq, 1'b0, "rx_irq stays 0 with rx_irq_enable=0, even though a byte is pending");
        wb_read(REG_RXDATA, rdata);  // drain it so it doesn't leak into the next check

        wb_write(REG_CONTROL, 32'h00000001);
        wb_read(REG_CONTROL, rdata);
        check_bit(rdata[0], 1'b1, "CONTROL.rx_irq_enable reads back as written");

        drive_rx_byte(8'h77);
        #1;
        check_bit(rx_irq, 1'b1, "rx_irq asserts once rx_irq_enable=1 and a byte is pending");
        wb_read(REG_RXDATA, rdata);
        check(rdata, 32'h00000077, "RXDATA matches while rx_irq was pending");
        #1;
        check_bit(rx_irq, 1'b0, "rx_irq clears once RXDATA is read (rx_ready cleared)");

        if (fails == 0)
            $display("PASS  uart_unit (%0d checks)", checks);
        else
            $display("FAIL  uart_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
