`include "WbDecoder.v"

// docs/adr/0020-soc-integration.md (Phase D1). Standalone unit test for
// WbDecoder.v, independent of the pipeline -- mirrors tb_fregister_unit.v's
// shape (verify a new unit's own behavior with dummy stubs before wiring
// it into anything real, docs/adr/0018's staging convention, continued
// here for Phase D). Three dummy slave stubs, deliberately with different
// ack timing (combinational, 1-cycle-registered, combinational again) --
// the decoder itself is purely combinational, so this also confirms it
// correctly passes through whatever latency the selected slave actually
// has, rather than assuming a fixed timing.
//
// Address map for this test only (not the real riscv_defs.vh MMIO_BASE
// map, which no real peripheral uses yet): slave0=[0,16), slave1=[16,32),
// a deliberate gap [32,1000), slave2=[1000,1008).
module tb_wbdecoder_unit;
    localparam XLEN = 32;
    localparam NUM_SLAVES = 3;

    reg clk = 0;
    reg m_cyc = 0, m_stb = 0, m_we = 0;
    reg [XLEN-1:0] m_addr = 0, m_data_o = 0;
    reg [3:0] m_sel = 4'b1111;
    wire [XLEN-1:0] m_data_i;
    wire m_ack;

    wire [NUM_SLAVES-1:0] s_cyc, s_stb;
    wire s_we;
    wire [XLEN-1:0] s_addr, s_data_o;
    wire [3:0] s_sel;
    wire [NUM_SLAVES*XLEN-1:0] s_data_i;
    wire [NUM_SLAVES-1:0] s_ack;

    WbDecoder #(
        .XLEN(XLEN), .NUM_SLAVES(NUM_SLAVES),
        .BASE({32'd1000, 32'd16, 32'd0}),
        .SIZE({32'd8,    32'd16, 32'd16})
    ) dut (
        .m_cyc(m_cyc), .m_stb(m_stb), .m_we(m_we), .m_addr(m_addr),
        .m_data_o(m_data_o), .m_sel(m_sel),
        .m_data_i(m_data_i), .m_ack(m_ack),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we), .s_addr(s_addr),
        .s_data_o(s_data_o), .s_sel(s_sel),
        .s_data_i(s_data_i), .s_ack(s_ack)
    );

    always #5 clk = ~clk;

    // Dummy slave 0: combinational ack, fixed signature.
    assign s_ack[0] = s_cyc[0] && s_stb[0];
    assign s_data_i[0*XLEN +: XLEN] = 32'hAAAAAAAA;

    // Dummy slave 1: 1-cycle-registered ack (mirrors DataMemoryBRAM.v's
    // own registered-read latency) -- proves the decoder doesn't assume
    // every slave acks combinationally.
    reg slave1_ack_r;
    always @(posedge clk) begin
        slave1_ack_r <= s_cyc[1] && s_stb[1] && !slave1_ack_r;
    end
    assign s_ack[1] = slave1_ack_r;
    assign s_data_i[1*XLEN +: XLEN] = 32'hBBBBBBBB;

    // Dummy slave 2: combinational ack, third fixed signature, at a
    // non-adjacent address range (confirms routing isn't just "first two
    // slaves" luck).
    assign s_ack[2] = s_cyc[2] && s_stb[2];
    assign s_data_i[2*XLEN +: XLEN] = 32'hCCCCCCCC;

    integer fails = 0;
    integer checks = 0;

    task check;
        input cond;
        input [511:0] label;
        begin
            checks = checks + 1;
            if (!cond) begin
                fails = fails + 1;
                $display("FAIL  %0s", label);
            end else begin
                $display("pass  %0s", label);
            end
        end
    endtask

    task start_read;
        input [XLEN-1:0] addr;
        begin
            m_cyc = 1; m_stb = 1; m_we = 0; m_addr = addr;
        end
    endtask

    task end_txn;
        begin
            m_cyc = 0; m_stb = 0;
            @(posedge clk); #1;
        end
    endtask

    initial begin
        @(posedge clk); #1;

        // slave0: address 0 (base), combinational ack same cycle.
        start_read(0);
        #1;
        check(s_cyc[0] && s_stb[0] && !s_cyc[1] && !s_cyc[2],
              "addr 0 (slave0 base) routes to slave0 only, no cross-talk");
        check(m_ack && (m_data_i === 32'hAAAAAAAA),
              "addr 0: combinational ack, correct signature (slave0)");
        end_txn();

        // slave0: address 15 (top of range, still slave0).
        start_read(15);
        #1;
        check(s_cyc[0] && !s_cyc[1] && !s_cyc[2],
              "addr 15 (slave0 top) still routes to slave0 only");
        check(m_ack && (m_data_i === 32'hAAAAAAAA),
              "addr 15: correct signature (slave0)");
        end_txn();

        // slave1: address 16 (base) -- 1-cycle registered ack, so no ack
        // the same cycle stb first asserts.
        start_read(16);
        #1;
        check(s_cyc[1] && s_stb[1] && !s_cyc[0] && !s_cyc[2],
              "addr 16 (slave1 base) routes to slave1 only");
        check(!m_ack, "addr 16: slave1 does NOT ack combinationally (registered latency)");
        @(posedge clk); #1;
        check(m_ack && (m_data_i === 32'hBBBBBBBB),
              "addr 16: slave1 acks one cycle later, correct signature");
        end_txn();

        // slave2: address 1000 (base, non-adjacent range).
        start_read(1000);
        #1;
        check(s_cyc[2] && s_stb[2] && !s_cyc[0] && !s_cyc[1],
              "addr 1000 (slave2 base) routes to slave2 only");
        check(m_ack && (m_data_i === 32'hCCCCCCCC),
              "addr 1000: combinational ack, correct signature (slave2)");
        end_txn();

        // slave2: address 1007 (top of range).
        start_read(1007);
        #1;
        check(s_cyc[2] && (m_data_i === 32'hCCCCCCCC),
              "addr 1007 (slave2 top) still routes to slave2");
        end_txn();

        // Gap address (500): no slave's range contains it -- hung bus, not
        // a silent wrong-data read. Held for several cycles to confirm it
        // never spuriously acks.
        start_read(500);
        #1;
        check(!s_cyc[0] && !s_cyc[1] && !s_cyc[2],
              "addr 500 (gap): no slave selected at all");
        check(!m_ack, "addr 500: m_ack stays low (cycle 1)");
        @(posedge clk); #1;
        check(!m_ack, "addr 500: m_ack still low (cycle 2, registered slave1 didn't spuriously fire)");
        @(posedge clk); #1;
        check(!m_ack, "addr 500: m_ack still low (cycle 3)");
        end_txn();

        if (fails == 0)
            $display("PASS  wbdecoder_unit (%0d checks)", checks);
        else
            $display("FAIL  wbdecoder_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
