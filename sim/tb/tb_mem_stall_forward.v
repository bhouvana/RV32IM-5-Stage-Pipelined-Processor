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

module tb_mem_stall_forward;
    `include "check_tasks.vh"
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/mem_stall_forward.mem")) dut(.clk(clk), .start(start));

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #800;

        check_reg(1, 32'd38, "producer: x1 = 38");
        check_reg(7, 32'd99,  "unrelated load: x7 <- mem[32] == 99");
        check_reg(8, 32'd76, "MEM/WB forward across an unrelated load's stall: x8=x1+x1=76 (docs/adr/0013)");

        report("mem_stall_forward");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
