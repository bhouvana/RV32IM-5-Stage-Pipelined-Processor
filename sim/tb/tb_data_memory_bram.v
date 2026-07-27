`include "DataMemoryBRAM.v"

// Standalone unit test for DataMemoryBRAM.v (docs/adr/0012-fpga-readiness.md),
// independent of the pipeline -- same shape as tb_divider_unit.v. Not wired
// into PIPELINED (see that file's header comment for why), so this is the
// only place its behavior is exercised.
module tb_data_memory_bram;
    reg clk = 0;
    reg rst = 0;
    reg memWrite = 0;
    reg memRead = 0;
    reg [31:0] address = 0;
    reg [31:0] writeData = 0;
    reg [2:0] funct3 = 0;
    wire [31:0] readData;

    integer fails = 0;
    integer checks = 0;

    DataMemoryBRAM dut(.clk(clk), .rst(rst), .memWrite(memWrite), .memRead(memRead),
                        .address(address), .writeData(writeData), .funct3(funct3),
                        .readData(readData));

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

    // One store, one word-read `delay` cycles later -- separate from `check`
    // so the read's registered latency (1 cycle: address+control go in on
    // one posedge, readData is valid combinationally off the *next* cycle's
    // registered raw_word_r/funct3_r) is exercised explicitly by the caller
    // choosing when to sample, not hidden inside a helper.
    task store;
        input [31:0] addr, data;
        input [2:0] f3;
        begin
            @(posedge clk);
            memWrite <= 1; memRead <= 0; address <= addr; writeData <= data; funct3 <= f3;
            @(posedge clk);
            memWrite <= 0;
        end
    endtask

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Reset clears memory: an immediate word read at address 0 must come
        // back zero (memRead's own registered latency means the *check*
        // itself needs one extra idle cycle before readData is valid).
        @(posedge clk); memRead <= 1; address <= 0; funct3 <= 3'b010;
        @(posedge clk); memRead <= 0;
        #1 check(readData, 32'd0, "reset clears memory: word[0] = 0");

        // sw 0x11223344 @ addr 16, read back as lw.
        store(32'd16, 32'h11223344, 3'b010);
        @(posedge clk); memRead <= 1; address <= 32'd16; funct3 <= 3'b010;
        @(posedge clk); memRead <= 0;
        #1 check(readData, 32'h11223344, "sw/lw round trip");

        // sb 0xFF @ addr 20 -- lb sign-extends, lbu zero-extends.
        store(32'd20, 32'h000000FF, 3'b00);
        @(posedge clk); memRead <= 1; address <= 32'd20; funct3 <= 3'b000;
        @(posedge clk); memRead <= 0;
        #1 check(readData, 32'hFFFFFFFF, "sb 0xFF then lb sign-extends to -1");

        @(posedge clk); memRead <= 1; address <= 32'd20; funct3 <= 3'b100;
        @(posedge clk); memRead <= 0;
        #1 check(readData, 32'h000000FF, "sb 0xFF then lbu zero-extends to 255");

        // sh 0xE000 @ addr 24 -- lh sign-extends (bit15 set), lhu doesn't;
        // upper half must stay untouched by the halfword store (only 2
        // bytes written).
        store(32'd24, 32'h0000E000, 3'b01);
        @(posedge clk); memRead <= 1; address <= 32'd24; funct3 <= 3'b001;
        @(posedge clk); memRead <= 0;
        #1 check(readData, 32'hFFFFE000, "sh 0xE000 then lh sign-extends");

        @(posedge clk); memRead <= 1; address <= 32'd24; funct3 <= 3'b010;
        @(posedge clk); memRead <= 0;
        #1 check(readData, 32'h0000E000, "sh wrote only 2 bytes: lw readback has zero upper half");

        // Explicitly demonstrate the 1-cycle read latency this module adds
        // relative to DataMemory.v's combinational read: driving a new
        // address/memRead=1 does NOT change readData until the DUT has
        // actually seen a posedge with that request presented -- readData
        // reflects the *previously latched* mem_read_r (0, left that way by
        // store()'s own cycles, which drive memRead=0 throughout) right up
        // until the edge that samples this new request.
        store(32'd28, 32'hAAAAAAAA, 3'b010);
        @(posedge clk); memRead <= 1; address <= 32'd28; funct3 <= 3'b010;
        #1 check(readData, 32'd0, "read latency: new request not yet sampled by the DUT, readData still reflects mem_read_r=0");
        @(posedge clk); memRead <= 0;
        #1 check(readData, 32'hAAAAAAAA, "read latency: new value valid exactly one cycle after the DUT saw the request");

        if (fails == 0)
            $display("PASS  data_memory_bram (%0d checks)", checks);
        else
            $display("FAIL  data_memory_bram (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
