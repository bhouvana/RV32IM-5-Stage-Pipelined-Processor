`include "riscvpipeline.v"
`include "PC.v"
`include "Adder.v"
`include "ALU.v"
`include "ALUCtrl.v"
`include "Control.v"
`include "DataMemoryBRAM.v"
`include "ImmGen.v"
`include "InstructionMemory.v"
`include "Mux2to1.v"
`include "Mux4to1.v"
`include "MuxN.v"
`include "Register.v"
`include "ShiftLeftOne.v"
`include "reg1.v"
`include "reg2.v"
`include "reg3.v"
`include "reg4.v"
`include "Hazard.v"
`include "HazardNoForward.v"
`include "Forward.v"
`include "Divider.v"
`include "CSR.v"

// Template for sim/tools/bench_runner.py (docs/ROADMAP.md Phase 10).
// __INIT_FILE__/__MAX_TIME__/__OUT_FILE__/__MEM_SIZE__/__HAZARD_STRATEGY__
// substituted per run, same idiom dump_regs_template.v (docs/ROADMAP.md V-4)
// already established. __HAZARD_STRATEGY__ (docs/adr/0016-swappable-hazard-
// strategy.md) is what makes this runner double as the "compare hazard
// strategies" tool docs/ROADMAP.md Phase 6 named as a research-platform goal.
//
// Detects "program finished" generically, without needing to know any
// program's specific halt-label address: every benchmark (like every other
// test program in this repo, docs/adr/0011) ends in a deliberate
// `jal x0, self` spin loop, which resolves in EX as an unconditional
// redirect whose target equals its own instruction's PC. The *first* cycle
// that pattern appears is recorded as completion -- a few cycles before the
// pipeline fully drains of in-flight work, but that offset is constant
// across every benchmark, so relative comparisons between them are still
// fair (see sim/tools/bench_runner.py's docstring for the exact caveat).
module bench_run;
    reg clk = 0;
    reg start = 0;
    integer fd;
    integer cycle_count;
    reg done;

    PIPELINED #(.INIT_FILE("__INIT_FILE__"), .MEM_SIZE_BYTES(__MEM_SIZE__), .HAZARD_STRATEGY(__HAZARD_STRATEGY__)) dut(.clk(clk), .start(start));

    always #5 clk = ~clk;

    initial begin
        start = 0;
        cycle_count = 0;
        done = 0;
        #10 start = 1;
    end

    always @(posedge clk) begin
        if (start && !done) begin
            cycle_count = cycle_count + 1;
            if (dut.unconditional_redirect && (dut.redirect_target == dut.pc_o_regde)) begin
                done = 1;
                fd = $fopen("__OUT_FILE__", "w");
                $fdisplay(fd, "%0d", cycle_count);
                $fclose(fd);
                $finish;
            end
        end
    end

    initial begin
        #__MAX_TIME__;
        if (!done) begin
            $display("TIMEOUT: __INIT_FILE__ never reached its halt loop within __MAX_TIME__ time units");
            $finish;
        end
    end
endmodule
