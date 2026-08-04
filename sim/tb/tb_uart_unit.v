`include "Uart.v"
`include "Timer.v"

// docs/adr/0020-soc-integration.md (Phase D4) / docs/adr/0034-uart-clint-
// register-compat-phase-r.md (Phase R). Standalone unit test for Uart.v,
// independent of the pipeline -- mirrors tb_fregister_unit.v's shape. Plays
// *both* roles a real external UART peer would: as a receiver, it samples
// the DUT's `tx` output pin over time and decodes the serial waveform back
// into a byte (real framing correctness, not an internal shortcut signal);
// as a transmitter, it drives the DUT's `rx` input pin with a hand-built
// serial bit-stream. CLKS_PER_BIT=4 here (small, for fast simulation) -- the
// framing logic itself doesn't care about the actual divisor value.
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
    wire irq;

    integer fails = 0;
    integer checks = 0;

    Uart #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut(
        .clk(clk), .rst(rst),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we),
        .s_addr(s_addr), .s_data_o(s_data_o), .s_sel(s_sel),
        .s_data_i(s_data_i), .s_ack(s_ack),
        .tx(tx), .rx(rx), .irq(irq)
    );

    always #5 clk = ~clk;

    // Phase R: ns16550a-compatible word offsets (design/Uart.v's own header).
    localparam REG_RBR_THR_DLL = 32'h00;
    localparam REG_IER_DLM     = 32'h04;
    localparam REG_IIR_FCR     = 32'h08;
    localparam REG_LCR         = 32'h0C;
    localparam REG_LSR         = 32'h14;

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

        // TX: write THR, confirm LSR.THRE clears, decode the serial
        // output, confirm LSR.THRE/TEMT set again once the frame completes.
        wb_read(REG_LSR, rdata);
        check_bit(rdata[5], 1'b1, "LSR.THRE is 1 (ready) before any write");

        // Checked via a direct hierarchical reference (dut.tx_busy), not a
        // bus read -- a wb_read here would burn 2 more clock edges before
        // sample_tx_byte starts listening for the start-bit negedge,
        // leaving too little of the 4-cycle start-bit window to reliably
        // still be within it (found by tracing through an earlier version
        // of this test that intermittently decoded garbage for exactly
        // this reason -- the extra read pushed `@(negedge tx)` past the
        // real edge into a later, unintended one mid-frame).
        wb_write(REG_RBR_THR_DLL, 32'h000000A5);  // THR <- 10100101 (DLAB=0 by reset default)
        #1 check_bit(dut.tx_busy, 1'b1, "tx_busy is 1 right after a THR write");

        sample_tx_byte(got_byte);
        check(got_byte, 8'hA5, "TX: decoded serial waveform matches written byte 0xA5");

        // LSR.THRE/TEMT should set again shortly after the stop bit's own
        // sample point (well within one more bit period).
        repeat (CLKS_PER_BIT) @(posedge clk);
        wb_read(REG_LSR, rdata);
        check_bit(rdata[5], 1'b1, "LSR.THRE sets again once the frame completes");
        check_bit(rdata[6], 1'b1, "LSR.TEMT sets again once the frame completes");

        // A second TX byte, back to back, confirms the state machine
        // correctly returns to idle and can send again (not stuck).
        wb_write(REG_RBR_THR_DLL, 32'h00000042);  // 01000010
        sample_tx_byte(got_byte);
        check(got_byte, 8'h42, "TX: second byte (0x42) also decodes correctly");

        // RX: drive a byte in, confirm RBR and LSR.DR, confirm reading RBR
        // clears DR.
        wb_read(REG_LSR, rdata);
        check_bit(rdata[0], 1'b0, "LSR.DR is 0 before any RX frame");

        drive_rx_byte(8'hC3);
        #1;
        wb_read(REG_LSR, rdata);
        check_bit(rdata[0], 1'b1, "LSR.DR is 1 after a full RX frame");

        wb_read(REG_RBR_THR_DLL, rdata);
        check(rdata, 32'h000000C3, "RBR matches the driven byte 0xC3");

        wb_read(REG_LSR, rdata);
        check_bit(rdata[0], 1'b0, "LSR.DR clears after RBR is read");

        // IIR: with IER=0 (reset default), nothing is ever reported pending,
        // even with a byte sitting unread.
        drive_rx_byte(8'h55);
        #1;
        check_bit(irq, 1'b0, "irq stays 0 with IER.ERBFI=0, even though a byte is pending");
        wb_read(REG_IIR_FCR, rdata);
        check(rdata[3:0], 4'b0001, "IIR reports 'none pending' while IER.ERBFI=0");
        wb_read(REG_RBR_THR_DLL, rdata);  // drain it so it doesn't leak into the next check

        // Enable IER.ERBFI: irq/IIR now track RX-data-available.
        wb_write(REG_IER_DLM, 32'h00000001);
        wb_read(REG_IER_DLM, rdata);
        check_bit(rdata[0], 1'b1, "IER.ERBFI reads back as written");

        drive_rx_byte(8'h77);
        #1;
        check_bit(irq, 1'b1, "irq asserts once IER.ERBFI=1 and RX data is pending");
        wb_read(REG_IIR_FCR, rdata);
        check(rdata[3:0], 4'b0100, "IIR reports 'RX data available' while pending");
        wb_read(REG_RBR_THR_DLL, rdata);
        check(rdata, 32'h00000077, "RBR matches while irq was pending");
        #1;
        check_bit(irq, 1'b0, "irq clears once RBR is read (LSR.DR cleared)");
        wb_read(REG_IIR_FCR, rdata);
        check(rdata[3:0], 4'b0001, "IIR reports 'none pending' again after RBR read");

        // Enable IER.ETBEI too: irq/IIR track THR-empty (level-triggered,
        // true whenever idle+enabled -- confirmed here since nothing is
        // mid-transmission at this point in the test).
        wb_write(REG_IER_DLM, 32'h00000003);  // ERBFI | ETBEI
        #1;
        check_bit(irq, 1'b1, "irq asserts on IER.ETBEI=1 while idle (THR empty)");
        wb_read(REG_IIR_FCR, rdata);
        check(rdata[3:0], 4'b0010, "IIR reports 'THR empty' when only that cause is pending");

        // RX-over-THR priority: with both causes pending simultaneously,
        // IIR must report the RX cause, matching real 16550A priority.
        drive_rx_byte(8'h11);
        #1;
        wb_read(REG_IIR_FCR, rdata);
        check(rdata[3:0], 4'b0100, "IIR reports RX-data-available over THR-empty when both pending");
        wb_read(REG_RBR_THR_DLL, rdata);  // drain

        // LCR.DLAB: gates offset 0x00/0x04 to DLL/DLM instead of RBR/THR-IER.
        wb_write(REG_LCR, 32'h00000080);  // DLAB <- 1
        wb_write(REG_RBR_THR_DLL, 32'h0000004E);  // DLL <- 0x4E
        wb_write(REG_IER_DLM, 32'h00000005);      // DLM <- 0x05
        wb_read(REG_RBR_THR_DLL, rdata);
        check(rdata, 32'h4E, "DLL reads back as written while DLAB=1");
        wb_read(REG_IER_DLM, rdata);
        check(rdata, 32'h05, "DLM reads back as written while DLAB=1");
        wb_write(REG_LCR, 32'h00000000);  // DLAB <- 0, restore normal addressing
        wb_read(REG_IER_DLM, rdata);
        check(rdata, 32'h03, "IER (ERBFI|ETBEI) unchanged and visible again once DLAB=0");

        if (fails == 0)
            $display("PASS  uart_unit (%0d checks)", checks);
        else
            $display("FAIL  uart_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
