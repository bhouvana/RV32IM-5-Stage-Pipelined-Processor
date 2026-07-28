`include "FRegister.v"

// Standalone unit test for FRegister.v, independent of the pipeline --
// mirrors tb_reg1a_unit.v's shape (verify a new unit's own behavior before
// wiring it into the live pipeline, docs/adr/0018's staging convention,
// continued here for docs/adr/0019-f-extension.md/Phase C). Drives the DUT
// directly with tasks rather than an assembled program. Picked up by
// sim/run_tests.sh's plain `tb_*.v` glob like every other standalone unit
// test (tb_divider_unit.v, tb_data_memory_bram.v, tb_reg1a_unit.v).
//
// Covers exactly what differs from design/Register.v (the two documented
// differences in FRegister.v's own header): no f0-hardwired-zero, and a
// third read port. The write-first bypass logic itself is the same
// well-verified idiom Register.v already uses (docs/adr/0002); this test
// still re-confirms it here since it's now applied across three read ports
// instead of two, not just copy-pasted and trusted.
module tb_fregister_unit;
    reg clk = 0;
    reg rst = 1;
    reg regWrite = 0;
    reg [4:0] readReg1 = 0;
    reg [4:0] readReg2 = 0;
    reg [4:0] readReg3 = 0;
    reg [4:0] writeReg = 0;
    reg [31:0] writeData = 0;
    wire [31:0] readData1, readData2, readData3;

    integer fails = 0;
    integer checks = 0;

    FRegister dut(
        .clk(clk), .rst(rst), .regWrite(regWrite),
        .readReg1(readReg1), .readReg2(readReg2), .readReg3(readReg3),
        .writeReg(writeReg), .writeData(writeData),
        .readData1(readData1), .readData2(readData2), .readData3(readData3)
    );

    always #5 clk = ~clk;

    task check1;
        input [31:0] expected;
        input [255:0] label;
        begin
            checks = checks + 1;
            if (readData1 !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: readData1=0x%08h, expected 0x%08h", label, readData1, expected);
            end else begin
                $display("pass  %0s: readData1=0x%08h", label, readData1);
            end
        end
    endtask

    task check3;
        input [31:0] exp1, exp2, exp3;
        input [255:0] label;
        begin
            checks = checks + 3;
            if (readData1 !== exp1 || readData2 !== exp2 || readData3 !== exp3) begin
                fails = fails + 1;
                $display("FAIL  %0s: (0x%08h,0x%08h,0x%08h), expected (0x%08h,0x%08h,0x%08h)",
                    label, readData1, readData2, readData3, exp1, exp2, exp3);
            end else begin
                $display("pass  %0s: (0x%08h,0x%08h,0x%08h)", label, readData1, readData2, readData3);
            end
        end
    endtask

    initial begin
        // Reset: every register, including f0, reads 0.
        readReg1 = 0; readReg2 = 1; readReg3 = 31;
        @(posedge clk); rst <= 0;
        @(posedge clk); #1;
        check3(0, 0, 0, "reset zeroes every register (f0/f1/f31)");
        rst <= 1;

        // Plain write then later read (regWrite deasserted by the time we read).
        @(posedge clk);
        writeReg <= 5; writeData <= 32'h3F800000; regWrite <= 1;  // +1.0f
        @(posedge clk);
        regWrite <= 0;
        readReg1 <= 5;
        @(posedge clk); #1;
        check1(32'h3F800000, "plain write to f5 (+1.0f), read back after write settles");

        // No hardwired-zero: f0 must accept and hold a real nonzero write,
        // unlike Register.v's x0.
        @(posedge clk);
        writeReg <= 0; writeData <= 32'hDEADBEEF; regWrite <= 1;
        @(posedge clk);
        regWrite <= 0;
        readReg1 <= 0;
        @(posedge clk); #1;
        check1(32'hDEADBEEF, "f0 is NOT hardwired to zero (unlike integer x0)");

        // Restore f0 to a real float value for the remaining checks so it
        // doesn't leave a landmine value behind.
        @(posedge clk);
        writeReg <= 0; writeData <= 32'h00000000; regWrite <= 1;
        @(posedge clk);
        regWrite <= 0;

        // Three independent read ports reading three different registers
        // at once (f0, f5, and a third register written just for this
        // check) -- confirms readData1/2/3 don't alias each other.
        @(posedge clk);
        writeReg <= 9; writeData <= 32'hC0000000; regWrite <= 1;  // -2.0f
        @(posedge clk);
        regWrite <= 0;
        readReg1 <= 0; readReg2 <= 5; readReg3 <= 9;
        @(posedge clk); #1;
        check3(32'h00000000, 32'h3F800000, 32'hC0000000,
               "three independent read ports (f0, f5, f9) read back correctly");

        // Write-first bypass on all three ports at once: writing f5 while
        // all three read ports simultaneously target f5 must show the new
        // value immediately, not the stale one.
        @(posedge clk);
        writeReg <= 5; writeData <= 32'h40000000; regWrite <= 1;  // +2.0f
        readReg1 <= 5; readReg2 <= 5; readReg3 <= 5;
        #1;
        check3(32'h40000000, 32'h40000000, 32'h40000000,
               "write-first bypass on all three read ports simultaneously");
        @(posedge clk);
        regWrite <= 0;

        if (fails == 0)
            $display("PASS  fregister_unit (%0d checks)", checks);
        else
            $display("FAIL  fregister_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
