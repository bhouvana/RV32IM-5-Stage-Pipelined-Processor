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

module tb_forward_memwb;
    `include "check_tasks.vh"
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/forward_memwb.mem")) dut(.clk(clk), .start(start));

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #800;

        check_reg(1, 32'd1, "x1=1 (producer)");
        check_reg(3, 32'd2, "MEM/WB forwarding: x3=x1+x1=2");

        report("forward_memwb");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
