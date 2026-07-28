`include "reg1a.v"

// Standalone unit test for reg1a.v, independent of the pipeline -- mirrors
// tb_divider_unit.v's shape (verify a new unit before wiring it into the
// live pipeline, docs/adr/0018-variable-pipeline-depth.md's staging): a
// different harness shape from the directed program-driven tests (drives
// the DUT directly with tasks instead of loading a program). Still picked
// up by sim/run_tests.sh's plain `tb_*.v` glob and counted in its
// tests/checks total, same as tb_divider_unit.v/tb_data_memory_bram.v
// already are.
//
// reg1a.v is deliberately a plain, unconditional relay (reset/stall only,
// no squash notion of its own -- see its header comment for why); this
// test covers exactly that surface. Redirect handling for this profile is
// riscvpipeline.v's own concern (redirect_squash_extend_r), exercised by
// the pipeline-level directed/random tests instead, not here.
module tb_reg1a_unit;
    reg clk = 0;
    reg rst = 1;
    reg stall = 0;
    reg [31:0] pc_o = 0;
    wire [31:0] pc_o_reg1a;

    integer fails = 0;
    integer checks = 0;

    reg1a dut(.clk(clk), .rst(rst), .stall(stall), .pc_o(pc_o), .pc_o_reg1a(pc_o_reg1a));

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

        if (fails == 0)
            $display("PASS  reg1a_unit (%0d checks)", checks);
        else
            $display("FAIL  reg1a_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
