`include "RamWishboneAdapter.v"
`include "Uart.v"
`include "Timer.v"
`include "DataMemoryBRAM.v"

// docs/adr/0020-soc-integration.md (Phase D2). Standalone unit test for
// RamWishboneAdapter.v, independent of the pipeline -- mirrors
// tb_data_memory_bram.v's own read/write/access-width/signedness coverage
// (the same DataMemoryBRAM.v underneath, now reached through the Wishbone
// interface instead of directly), plus new checks specific to the wrapper
// itself: ack timing (combinational for a write, one-cycle-registered for
// a read, matching DataMemoryBRAM.v's own native latency exactly) and that
// s_cyc/s_stb without the other asserted correctly does nothing.
module tb_ramwishboneadapter_unit;
    reg clk = 0;
    reg rst = 0;
    reg s_cyc = 0, s_stb = 0, s_we = 0;
    reg [31:0] s_addr = 0, s_data_o = 0;
    reg [3:0] s_sel = 4'b1111;
    reg [2:0] funct3 = 0;
    wire [31:0] s_data_i;
    wire s_ack;

    integer fails = 0;
    integer checks = 0;

    RamWishboneAdapter dut(
        .clk(clk), .rst(rst),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we),
        .s_addr(s_addr), .s_data_o(s_data_o), .s_sel(s_sel), .funct3(funct3),
        .s_data_i(s_data_i), .s_ack(s_ack)
    );

    always #5 clk = ~clk;

    task check;
        input [31:0] actual, expected;
        input [255:0] label;
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
        input [255:0] label;
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

    // A write acks combinationally, same cycle -- one clock pulse is
    // enough to commit it.
    task wb_write;
        input [31:0] addr, data;
        input [2:0] f3;
        begin
            @(posedge clk);
            s_cyc <= 1; s_stb <= 1; s_we <= 1; s_addr <= addr; s_data_o <= data; funct3 <= f3;
            #1 check_bit(s_ack, 1'b1, "write acks combinationally, same cycle");
            @(posedge clk);
            s_cyc <= 0; s_stb <= 0; s_we <= 0;
        end
    endtask

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Reset clears memory: word[0] reads back 0.
        @(posedge clk); s_cyc <= 1; s_stb <= 1; s_we <= 0; s_addr <= 0; funct3 <= 3'b010;
        #1 check_bit(s_ack, 1'b0, "read does NOT ack combinationally (registered latency)");
        @(posedge clk); s_cyc <= 0; s_stb <= 0;
        #1 check_bit(s_ack, 1'b1, "read acks exactly one cycle after the request");
        check(s_data_i, 32'd0, "reset clears memory: word[0] = 0");

        // sw/lw round trip.
        wb_write(32'd16, 32'h11223344, 3'b010);
        @(posedge clk); s_cyc <= 1; s_stb <= 1; s_we <= 0; s_addr <= 32'd16; funct3 <= 3'b010;
        @(posedge clk); s_cyc <= 0; s_stb <= 0;
        #1 check(s_data_i, 32'h11223344, "sw/lw round trip over Wishbone");

        // sb 0xFF -- lb sign-extends, lbu zero-extends.
        wb_write(32'd20, 32'h000000FF, 3'b000);
        @(posedge clk); s_cyc <= 1; s_stb <= 1; s_we <= 0; s_addr <= 32'd20; funct3 <= 3'b000;
        @(posedge clk); s_cyc <= 0; s_stb <= 0;
        #1 check(s_data_i, 32'hFFFFFFFF, "sb 0xFF then lb sign-extends to -1");

        @(posedge clk); s_cyc <= 1; s_stb <= 1; s_we <= 0; s_addr <= 32'd20; funct3 <= 3'b100;
        @(posedge clk); s_cyc <= 0; s_stb <= 0;
        #1 check(s_data_i, 32'h000000FF, "sb 0xFF then lbu zero-extends to 255");

        // sh 0xE000 -- lh sign-extends, lhu doesn't; upper half untouched.
        wb_write(32'd24, 32'h0000E000, 3'b001);
        @(posedge clk); s_cyc <= 1; s_stb <= 1; s_we <= 0; s_addr <= 32'd24; funct3 <= 3'b001;
        @(posedge clk); s_cyc <= 0; s_stb <= 0;
        #1 check(s_data_i, 32'hFFFFE000, "sh 0xE000 then lh sign-extends");

        @(posedge clk); s_cyc <= 1; s_stb <= 1; s_we <= 0; s_addr <= 32'd24; funct3 <= 3'b010;
        @(posedge clk); s_cyc <= 0; s_stb <= 0;
        #1 check(s_data_i, 32'h0000E000, "sh wrote only 2 bytes: lw readback has zero upper half");

        // cyc without stb (or stb without cyc) must never write or ack --
        // a real bus master never does this, but the adapter shouldn't
        // silently accept a malformed transaction either.
        @(posedge clk); s_cyc <= 1; s_stb <= 0; s_we <= 1; s_addr <= 32'd40; s_data_o <= 32'hDEADBEEF; funct3 <= 3'b010;
        #1 check_bit(s_ack, 1'b0, "cyc without stb: no ack");
        @(posedge clk); s_cyc <= 0; s_we <= 0;
        @(posedge clk); s_cyc <= 1; s_stb <= 1; s_we <= 0; s_addr <= 32'd40; funct3 <= 3'b010;
        @(posedge clk); s_cyc <= 0; s_stb <= 0;
        #1 check(s_data_i, 32'd0, "cyc-without-stb write never actually committed");

        if (fails == 0)
            $display("PASS  ramwishboneadapter_unit (%0d checks)", checks);
        else
            $display("FAIL  ramwishboneadapter_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
