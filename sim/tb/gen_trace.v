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

// Emits one CSV row per cycle to trace.csv -- every field here is read
// directly off a real DUT signal, nothing is inferred/reconstructed. Used
// by sim/tools/gen_trace.py to build the interactive pipeline viewer.
// Columns:
//   cycle,
//   if_pc,if_inst,
//   id_pc,id_inst,stall,flush,
//   ex_pc,ex_inst,branch_taken,jump,alu_out,forwardA,forwardB,
//   mem_we,mem_re,mem_addr,mem_dest,mem_regwrite,
//   wb_dest,wb_val,wb_regwrite
module gen_trace;
    reg clk = 0;
    reg start = 0;
    integer fd;
    integer cycle;

    PIPELINED #(.INIT_FILE("sim/programs/demo.mem")) dut(clk, start);

    always #5 clk = ~clk;

    initial begin
        fd = $fopen("trace.csv", "w");
        $fwrite(fd, "cycle,if_pc,if_inst,id_pc,id_inst,stall,flush,ex_pc,ex_inst,branch_taken,jump,alu_out,forwardA,forwardB,mem_we,mem_re,mem_addr,mem_dest,mem_regwrite,wb_dest,wb_val,wb_regwrite\n");
        cycle = 0;
        start = 0;
        #10 start = 1;
        #500;
        $fclose(fd);
        $finish;
    end

    always @(posedge clk) begin
        if (start) begin
            cycle = cycle + 1;
            $fwrite(fd, "%0d,%0d,%h,%0d,%h,%0d,%0d,%0d,%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                cycle,
                dut.pc_o, dut.inst,
                dut.pc_o_regfd, dut.inst_regfd, dut.stall, dut.flush,
                dut.pc_o_regde, dut.inst_regde, dut.branch_taken, dut.jump_regde, dut.ALUOut, dut.forwardA, dut.forwardB,
                dut.memWrite_regem, dut.memRead_regem, dut.ALUOut_regem, dut.write_to_Reg_regem, dut.regWrite_regem,
                dut.write_to_Reg_regwb, dut.writeData_regwb, dut.regWrite_regwb);
        end
    end
endmodule
