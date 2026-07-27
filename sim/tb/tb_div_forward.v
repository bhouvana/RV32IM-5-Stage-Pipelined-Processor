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

module tb_div_forward;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/div_forward.mem")) dut(.clk(clk), .start(start));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #900;  // ~1 division (~33 cycles) plus setup/drain -- generous margin

        check_reg(3, 32'd3, "div(17,5) = 3");
        check_reg(4, 32'd6, "EX/MEM forward of multi-cycle div result: x4=x3+x3=6");

        report("div_forward");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
