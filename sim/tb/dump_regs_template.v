`include "riscvpipeline.v"
`include "PC.v"
`include "Adder.v"
`include "ALU.v"
`include "ALUCtrl.v"
`include "Control.v"
`include "DataMemory.v"
`include "ImmGen.v"
`include "InstructionMemory.v"
`include "Mux2to1.v"
`include "Mux4to1.v"
`include "Register.v"
`include "ShiftLeftOne.v"
`include "reg1.v"
`include "reg2.v"
`include "reg3.v"
`include "reg4.v"
`include "Hazard.v"
`include "Forward.v"
`include "Divider.v"
`include "CSR.v"

// Template for sim/tools/random_gen.py's cross-check driver -- __INIT_FILE__
// and __MAX_TIME__ are substituted per run. Dumps final architectural
// register state (all 32 registers) as one decimal value per line, for
// comparison against sim/tools/iss.py's own final state on the same
// program. Not part of sim/run_tests.sh's tb_*.v glob (different shape --
// generated per-run, not a fixed named test).
module dump_regs;
    reg clk = 0;
    reg start = 0;
    integer i;
    integer fd;

    PIPELINED #(.INIT_FILE("__INIT_FILE__")) dut(.clk(clk), .start(start));

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #__MAX_TIME__;
        fd = $fopen("__OUT_FILE__", "w");
        for (i = 0; i < 32; i = i + 1)
            $fdisplay(fd, "%0d", dut.m_Register.regs[i]);
        for (i = 0; i < 128; i = i + 1)
            $fdisplay(fd, "%0d", dut.m_DataMemory.data_memory[i]);
        $fclose(fd);
        $finish;
    end
endmodule
