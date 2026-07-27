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

module tb_branch_not_taken;
    `include "check_tasks.vh"
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/branch_not_taken.mem")) dut(clk, start);

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #800;

        check_reg(3, 32'd42, "beq not taken: fallthrough x3=42 (target's 999 must not execute)");

        report("branch_not_taken");
        $finish;
    end
endmodule
