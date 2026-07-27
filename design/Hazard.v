module Hazard (

    input [4:0] readReg1_fd,
    input [4:0] readReg2_fd,
    input [4:0] write_to_Reg_regde,
    input memRead_regde,
    output flush,
    output stall
);
assign flush = ( memRead_regde && ((write_to_Reg_regde ==readReg1_fd) || (write_to_Reg_regde == readReg2_fd))) ? 1'b1 : 1'b0;
assign stall = flush;
endmodule

//"C:\Users\samar\Downloads\TEST_INSTRUCTIONS_2.txt"
