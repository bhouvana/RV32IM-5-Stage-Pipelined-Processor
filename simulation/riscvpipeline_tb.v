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
`include "Register.v"
`include "ShiftLeftOne.v"
`include "reg1.v"
`include "reg2.v"
`include "reg3.v"
`include "reg4.v"
`include "Hazard.v"
`include "Forward.v"
`include "Mux4to1.v"
module tb_riscv_pipeline;
//cpu testbench

reg clk;
reg start;

PIPELINED riscv_DUT(clk, start);

initial
	forever #5 clk = ~clk;

initial begin
    $dumpfile("pipeline_tb.vcd");
    $dumpvars(0, riscv_DUT);
	//$dumpvars(0, uut.m_Register.regs);

	clk = 0;
	start = 0;
	#10 start = 1;
	#1 riscv_DUT.m_Register.regs[2] = 32'd128; // Initialize sp = 0x80

	

	#3000 $finish;

end

endmodule
