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
`include "Forward.v"
`include "Divider.v"
`include "CSR.v"

module tb_shift_mask;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/shift_mask.mem")) dut(.clk(clk), .start(start));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #800;

        check_reg(3, 32'd8,         "sll with shift-amount register=35: masked to 35&0x1F=3 -> 1<<3=8");
        check_reg(5, 32'h1FFFFFFF,  "srl with shift-amount register=35: logical, masked to 3");
        check_reg(6, 32'hFFFFFFFF,  "sra with shift-amount register=35: arithmetic, masked to 3, sign preserved");

        report("shift_mask");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
