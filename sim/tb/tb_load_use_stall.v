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
`include "FRegister.v"
`include "FALU.v"
`include "FDivider.v"
`include "FSqrt.v"
`include "FMADDUnit.v"
`include "Register.v"
`include "ShiftLeftOne.v"
`include "reg1.v"
`include "reg2.v"
`include "reg3.v"
`include "reg4.v"
`include "Hazard.v"
`include "Forward.v"
`include "FForward.v"
`include "Divider.v"
`include "CSR.v"
`include "WbDecoder.v"
`include "RamWishboneAdapter.v"
`include "Uart.v"
`include "Timer.v"

module tb_load_use_stall;
    `include "check_tasks.vh"
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/load_use_stall.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #800;

        check_reg(7, 32'd77,  "lw x7 <- mem[32] == 77");
        check_reg(8, 32'd154, "load-use stall: x8=x7+x7=154 (would be 0 if stall were broken)");

        report("load_use_stall");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
