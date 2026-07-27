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

module tb_jal;
    `include "check_tasks.vh"
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/jal_test.mem")) dut(clk, start);

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #800;

        check_reg(1, 32'd4,  "jal link value: x1 = PC(0)+4");
        check_reg(2, 32'd128, "poisons squashed: x2 stays at its reset default (never written)");
        check_reg(3, 32'd8,  "EX/MEM forward of jal result: x3=x1+x1=8");

        report("jal");
        $finish;
    end
endmodule
