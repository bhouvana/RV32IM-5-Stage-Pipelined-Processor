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

module tb_ebreak_trap;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/ebreak_trap.mem")) dut(clk, start);
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #300;

        check_reg(9, 32'd0,   "x9 never written: both addi's after the trap were redirected away");
        check_reg(10, 32'd77, "x10=77: the handler at mtvec ran");
        check_val(dut.m_CSR.mepc, 32'd8,   "mepc = ebreak's own address");
        check_val(dut.m_CSR.mcause, 32'd3, "mcause = 3 (BREAKPOINT)");
        check_val(dut.m_CSR.mtvec, 32'd20, "mtvec unchanged from setup");

        report("ebreak_trap");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
