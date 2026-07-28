`include "reg1a.v"

// Standalone unit test for reg1a.v, independent of the pipeline -- mirrors
// tb_divider_unit.v's shape (verify a new unit before wiring it into the
// live pipeline, docs/adr/0018-variable-pipeline-depth.md's staging): a
// different harness shape from the directed program-driven tests (drives
// the DUT directly with tasks instead of loading a program). Still picked
// up by sim/run_tests.sh's plain `tb_*.v` glob and counted in its
// tests/checks total, same as tb_divider_unit.v/tb_data_memory_bram.v
// already are.
module tb_reg1a_unit;
    reg clk = 0;
    reg rst = 1;
    reg stall = 0;
    reg [31:0] pc_o = 0;
    reg branch_regde = 0;
    reg zero = 0;
    reg jump = 0;
    wire [31:0] pc_o_reg1a;

    integer fails = 0;
    integer checks = 0;

    reg1a dut(.clk(clk), .rst(rst), .stall(stall), .pc_o(pc_o),
              .branch_regde(branch_regde), .zero(zero), .jump(jump),
              .pc_o_reg1a(pc_o_reg1a));

    always #5 clk = ~clk;

    task check;
        input [31:0] expected;
        input [255:0] label;
        begin
            checks = checks + 1;
            if (pc_o_reg1a !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: pc_o_reg1a=0x%08h, expected 0x%08h", label, pc_o_reg1a, expected);
            end else begin
                $display("pass  %0s: pc_o_reg1a=0x%08h", label, pc_o_reg1a);
            end
        end
    endtask

    initial begin
        // Reset: pc_o_reg1a must be 0 regardless of pc_o.
        pc_o = 32'h100;
        @(posedge clk); rst <= 0;
        @(posedge clk); #1;
        check(0, "reset holds pc_o_reg1a at 0");
        rst <= 1;

        // Normal latch: registers pc_o on the next edge.
        pc_o <= 32'h4;
        @(posedge clk);
        @(posedge clk); #1;
        check(32'h4, "normal latch: pc_o=4");

        pc_o <= 32'h8;
        @(posedge clk);
        @(posedge clk); #1;
        check(32'h8, "normal latch: pc_o=8");

        // Stall: holds its current value even as pc_o changes underneath it.
        stall <= 1;
        pc_o <= 32'hFF;
        @(posedge clk);
        @(posedge clk); #1;
        check(32'h8, "stall holds previous value despite pc_o changing");
        stall <= 0;

        // Latches again once stall clears.
        @(posedge clk);
        @(posedge clk); #1;
        check(32'hFF, "resumes latching once stall clears");

        // Squash via taken branch (branch_regde & zero).
        pc_o <= 32'h20;
        @(posedge clk);
        @(posedge clk); #1;
        check(32'h20, "normal latch before squash: pc_o=0x20");
        branch_regde <= 1; zero <= 1;
        @(posedge clk);
        @(posedge clk); #1;
        check(0, "taken-branch squash resets to 0");
        branch_regde <= 0; zero <= 0;

        // Squash via unconditional redirect (jump -- jal/jalr/trap/mret).
        pc_o <= 32'h40;
        @(posedge clk);
        @(posedge clk); #1;
        check(32'h40, "normal latch before squash: pc_o=0x40");
        jump <= 1;
        @(posedge clk);
        @(posedge clk); #1;
        check(0, "unconditional-redirect squash resets to 0");
        jump <= 0;

        // Squash takes priority over stall (matching reg1.v's priority order).
        pc_o <= 32'h60;
        @(posedge clk);
        @(posedge clk); #1;
        check(32'h60, "normal latch before priority check: pc_o=0x60");
        stall <= 1; jump <= 1;
        @(posedge clk);
        @(posedge clk); #1;
        check(0, "squash takes priority over a simultaneous stall");
        stall <= 0; jump <= 0;

        if (fails == 0)
            $display("PASS  reg1a_unit (%0d checks)", checks);
        else
            $display("FAIL  reg1a_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
